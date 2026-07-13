// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/CountersigEpochFees.sol";
import "../src/CountersigIdentity.sol";
import "../src/CSIGToken.sol";

contract CountersigEpochFeesTest is Test {
    CountersigEpochFees fees;
    CountersigIdentity identity;
    CSIGToken csig;

    address admin      = makeAddr("admin");
    address oracle     = makeAddr("oracle");
    address operator   = makeAddr("operator");
    address agent      = makeAddr("agent");
    address funder     = makeAddr("funder");
    address rewardPool = makeAddr("rewardPool");
    address stranger   = makeAddr("stranger");

    bytes32 constant PUB_KEY = bytes32(uint256(0xdeadbeef));
    uint256 constant EPOCH_FEE = 10e18;

    bytes32 didHash;

    function setUp() public {
        // $CSIG (testnet mintable token is fine for fixtures).
        csig = new CSIGToken(address(this));

        // Identity registry behind a proxy; register one agent.
        CountersigIdentity idImpl = new CountersigIdentity();
        identity = CountersigIdentity(address(new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(CountersigIdentity.initialize, (admin, address(0)))
        )));
        vm.prank(operator);
        didHash = identity.registerAgent(agent, PUB_KEY);

        // Fee registry behind a proxy.
        CountersigEpochFees feesImpl = new CountersigEpochFees();
        fees = CountersigEpochFees(address(new ERC1967Proxy(
            address(feesImpl),
            abi.encodeCall(
                CountersigEpochFees.initialize,
                (admin, oracle, address(csig), address(identity), rewardPool, EPOCH_FEE)
            )
        )));

        // Fund operator + funder and approve the registry.
        csig.mint(operator, 1_000e18);
        csig.mint(funder, 1_000e18);
        vm.prank(operator);
        csig.approve(address(fees), type(uint256).max);
        vm.prank(funder);
        csig.approve(address(fees), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Init
    // -------------------------------------------------------------------------

    function test_init() public view {
        assertEq(address(fees.csig()), address(csig));
        assertEq(address(fees.identityRegistry()), address(identity));
        assertEq(fees.rewardPool(), rewardPool);
        assertEq(fees.epochFee(), EPOCH_FEE);
        assertEq(uint8(fees.stage()), uint8(CountersigEpochFees.Stage.Bootstrap));
        assertTrue(fees.hasRole(fees.ORACLE_ROLE(), oracle));
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    function test_depositFor_anyoneCanFund() public {
        vm.prank(funder);
        fees.depositFor(didHash, 100e18);
        assertEq(fees.balance(didHash), 100e18);
        assertEq(csig.balanceOf(address(fees)), 100e18);
    }

    function test_depositFor_accumulates() public {
        vm.prank(operator);
        fees.depositFor(didHash, 40e18);
        vm.prank(funder);
        fees.depositFor(didHash, 60e18);
        assertEq(fees.balance(didHash), 100e18);
    }

    function test_depositFor_zero_reverts() public {
        vm.expectRevert(CountersigEpochFees.ZeroAmount.selector);
        vm.prank(funder);
        fees.depositFor(didHash, 0);
    }

    function test_withdraw_operatorOnly() public {
        vm.prank(funder);
        fees.depositFor(didHash, 100e18);

        vm.prank(operator);
        fees.withdraw(didHash, 30e18);
        assertEq(fees.balance(didHash), 70e18);
        assertEq(csig.balanceOf(operator), 1_000e18 + 30e18);
    }

    function test_withdraw_notOperator_reverts() public {
        vm.prank(funder);
        fees.depositFor(didHash, 100e18);

        vm.expectRevert(abi.encodeWithSelector(CountersigEpochFees.NotOperator.selector, didHash, stranger));
        vm.prank(stranger);
        fees.withdraw(didHash, 1e18);
    }

    function test_withdraw_moreThanBalance_reverts() public {
        vm.prank(operator);
        fees.depositFor(didHash, 10e18);
        vm.expectRevert(abi.encodeWithSelector(CountersigEpochFees.InsufficientBalance.selector, didHash, 11e18, 10e18));
        vm.prank(operator);
        fees.withdraw(didHash, 11e18);
    }

    // -------------------------------------------------------------------------
    // Charging
    // -------------------------------------------------------------------------

    function test_isCovered() public {
        assertFalse(fees.isCovered(didHash));
        vm.prank(operator);
        fees.depositFor(didHash, EPOCH_FEE);
        assertTrue(fees.isCovered(didHash));
    }

    function test_chargeEpoch_covered() public {
        vm.prank(operator);
        fees.depositFor(didHash, 25e18);

        vm.prank(oracle);
        bool charged = fees.chargeEpoch(didHash);
        assertTrue(charged);
        assertEq(fees.balance(didHash), 15e18);
        assertEq(fees.collected(), EPOCH_FEE);
    }

    function test_chargeEpoch_uncovered_returnsFalse_noStateChange() public {
        vm.prank(operator);
        fees.depositFor(didHash, 5e18); // < EPOCH_FEE

        vm.prank(oracle);
        bool charged = fees.chargeEpoch(didHash);
        assertFalse(charged);
        assertEq(fees.balance(didHash), 5e18);
        assertEq(fees.collected(), 0);
    }

    function test_chargeEpoch_feeZero_disablesGating() public {
        vm.prank(admin);
        fees.setEpochFee(0);
        assertTrue(fees.isCovered(didHash)); // covered even with 0 balance

        vm.prank(oracle);
        assertTrue(fees.chargeEpoch(didHash));
        assertEq(fees.collected(), 0); // nothing charged
    }

    function test_chargeEpoch_notOracle_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, fees.ORACLE_ROLE()
        ));
        vm.prank(stranger);
        fees.chargeEpoch(didHash);
    }

    // -------------------------------------------------------------------------
    // Distribution — three-stage routing (§6)
    // -------------------------------------------------------------------------

    function _collect(uint256 epochs) internal {
        vm.prank(funder);
        fees.depositFor(didHash, EPOCH_FEE * epochs);
        for (uint256 i = 0; i < epochs; i++) {
            vm.prank(oracle);
            fees.chargeEpoch(didHash);
        }
    }

    function test_distribute_bootstrap_allToPool() public {
        _collect(10); // 100e18 collected
        fees.distributeFees();
        assertEq(csig.balanceOf(rewardPool), 100e18);
        assertEq(csig.balanceOf(address(0xdead)), 0);
        assertEq(fees.collected(), 0);
    }

    function test_distribute_transition_80_20() public {
        vm.prank(admin);
        fees.setStage(CountersigEpochFees.Stage.Transition);
        _collect(10); // 100e18
        fees.distributeFees();
        assertEq(csig.balanceOf(rewardPool), 80e18);
        assertEq(csig.balanceOf(address(0xdead)), 20e18);
    }

    function test_distribute_mature_50_50() public {
        vm.prank(admin);
        fees.setStage(CountersigEpochFees.Stage.Mature);
        _collect(10); // 100e18
        fees.distributeFees();
        assertEq(csig.balanceOf(rewardPool), 50e18);
        assertEq(csig.balanceOf(address(0xdead)), 50e18);
    }

    function test_distribute_nothing_reverts() public {
        vm.expectRevert(CountersigEpochFees.NothingToDistribute.selector);
        fees.distributeFees();
    }

    // -------------------------------------------------------------------------
    // Admin gating
    // -------------------------------------------------------------------------

    function test_setEpochFee_adminOnly() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
        ));
        vm.prank(stranger);
        fees.setEpochFee(1e18);

        vm.prank(admin);
        fees.setEpochFee(1e18);
        assertEq(fees.epochFee(), 1e18);
    }

    function test_setStage_and_setRewardPool_adminOnly() public {
        vm.prank(admin);
        fees.setStage(CountersigEpochFees.Stage.Mature);
        assertEq(uint8(fees.stage()), uint8(CountersigEpochFees.Stage.Mature));

        vm.prank(admin);
        fees.setRewardPool(stranger);
        assertEq(fees.rewardPool(), stranger);

        vm.expectRevert(CountersigEpochFees.ZeroAddress.selector);
        vm.prank(admin);
        fees.setRewardPool(address(0));
    }

    // -------------------------------------------------------------------------
    // Storage layout — pins balance mapping to slot 6 for upgrade safety
    // -------------------------------------------------------------------------

    function test_storageLayout_balancePinnedToSlot6() public {
        vm.prank(funder);
        fees.depositFor(didHash, 42e18);
        bytes32 slot = keccak256(abi.encode(didHash, uint256(6)));
        assertEq(uint256(vm.load(address(fees), slot)), 42e18);
    }
}
