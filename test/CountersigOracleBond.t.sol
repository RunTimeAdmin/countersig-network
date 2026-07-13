// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/CountersigOracleBond.sol";
import "../src/CSIGToken.sol";

contract CountersigOracleBondTest is Test {
    CountersigOracleBond bond;
    CSIGToken csig;

    address admin       = makeAddr("admin");
    address slasher     = makeAddr("slasher");
    address beneficiary = makeAddr("beneficiary");
    address op1         = makeAddr("op1");
    address op2         = makeAddr("op2");
    address stranger    = makeAddr("stranger");

    uint256 constant BOND = 1000e18;
    uint256 constant UNBOND = 7 days;

    function setUp() public {
        csig = new CSIGToken(address(this));

        CountersigOracleBond impl = new CountersigOracleBond();
        bond = CountersigOracleBond(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CountersigOracleBond.initialize,
                (admin, slasher, address(csig), BOND, UNBOND, beneficiary)
            )
        )));

        csig.mint(op1, 10_000e18);
        csig.mint(op2, 10_000e18);
        vm.prank(op1); csig.approve(address(bond), type(uint256).max);
        vm.prank(op2); csig.approve(address(bond), type(uint256).max);
    }

    function _bondAndAdmit(address op, uint256 amount) internal {
        vm.prank(op);
        bond.depositBond(amount);
        vm.prank(admin);
        bond.admit(op);
    }

    // -------------------------------------------------------------------------
    // Init
    // -------------------------------------------------------------------------

    function test_init() public view {
        assertEq(address(bond.csig()), address(csig));
        assertEq(bond.bondAmount(), BOND);
        assertEq(bond.unbondingPeriod(), UNBOND);
        assertEq(bond.slashBeneficiary(), beneficiary);
        assertTrue(bond.hasRole(bond.SLASHER_ROLE(), slasher));
    }

    // -------------------------------------------------------------------------
    // Deposit / admit
    // -------------------------------------------------------------------------

    function test_depositBond_bondsApplicant() public {
        vm.prank(op1);
        bond.depositBond(1500e18);
        assertEq(bond.bondOf(op1), 1500e18);
        (, CountersigOracleBond.Status status,) = bond.operators(op1);
        assertEq(uint8(status), uint8(CountersigOracleBond.Status.Bonded));
        assertEq(csig.balanceOf(address(bond)), 1500e18);
    }

    function test_depositBond_zero_reverts() public {
        vm.expectRevert(CountersigOracleBond.ZeroAmount.selector);
        vm.prank(op1);
        bond.depositBond(0);
    }

    function test_admit_activatesOperator() public {
        _bondAndAdmit(op1, BOND);
        assertTrue(bond.isActiveOperator(op1));
        assertEq(bond.activeCount(), 1);
    }

    function test_admit_insufficientBond_reverts() public {
        vm.prank(op1);
        bond.depositBond(BOND - 1);
        vm.expectRevert(abi.encodeWithSelector(CountersigOracleBond.InsufficientBond.selector, op1, BOND - 1, BOND));
        vm.prank(admin);
        bond.admit(op1);
    }

    function test_admit_notBonded_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            CountersigOracleBond.WrongStatus.selector, op1, CountersigOracleBond.Status.None
        ));
        vm.prank(admin);
        bond.admit(op1);
    }

    function test_admit_notAdmin_reverts() public {
        vm.prank(op1);
        bond.depositBond(BOND);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
        ));
        vm.prank(stranger);
        bond.admit(op1);
    }

    // -------------------------------------------------------------------------
    // Slashing
    // -------------------------------------------------------------------------

    function test_slash_reducesBond_toBeneficiary() public {
        _bondAndAdmit(op1, 2000e18);
        vm.prank(slasher);
        bond.slash(op1, 500e18);
        assertEq(bond.bondOf(op1), 1500e18);
        assertEq(csig.balanceOf(beneficiary), 500e18);
        assertTrue(bond.isActiveOperator(op1)); // still >= bondAmount
        assertEq(bond.activeCount(), 1);
    }

    function test_slash_demotesBelowMinimum() public {
        _bondAndAdmit(op1, 1500e18);
        vm.prank(slasher);
        bond.slash(op1, 600e18); // 900 < 1000
        assertEq(bond.bondOf(op1), 900e18);
        assertFalse(bond.isActiveOperator(op1));
        assertEq(bond.activeCount(), 0);
    }

    function test_slash_exceedsBond_reverts() public {
        _bondAndAdmit(op1, BOND);
        vm.expectRevert(abi.encodeWithSelector(CountersigOracleBond.SlashExceedsBond.selector, op1, BOND + 1, BOND));
        vm.prank(slasher);
        bond.slash(op1, BOND + 1);
    }

    function test_slash_notSlasher_reverts() public {
        _bondAndAdmit(op1, BOND);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bond.SLASHER_ROLE()
        ));
        vm.prank(stranger);
        bond.slash(op1, 1e18);
    }

    function test_slash_duringUnbonding_stillWorks() public {
        _bondAndAdmit(op1, 2000e18);
        vm.prank(op1);
        bond.initiateUnbond(); // Exiting

        vm.prank(slasher);
        bond.slash(op1, 500e18); // still slashable in cooldown
        assertEq(bond.bondOf(op1), 1500e18);
        assertEq(csig.balanceOf(beneficiary), 500e18);
    }

    // -------------------------------------------------------------------------
    // Unbonding
    // -------------------------------------------------------------------------

    function test_initiateUnbond_exitsActiveSet() public {
        _bondAndAdmit(op1, BOND);
        vm.prank(op1);
        bond.initiateUnbond();
        assertFalse(bond.isActiveOperator(op1));
        assertEq(bond.activeCount(), 0);
    }

    function test_withdrawBond_afterCooldown() public {
        _bondAndAdmit(op1, 1500e18);
        vm.prank(op1);
        bond.initiateUnbond();

        vm.warp(block.timestamp + UNBOND);
        uint256 before = csig.balanceOf(op1);
        vm.prank(op1);
        bond.withdrawBond();
        assertEq(csig.balanceOf(op1), before + 1500e18);
        assertEq(bond.bondOf(op1), 0);
        (, CountersigOracleBond.Status status,) = bond.operators(op1);
        assertEq(uint8(status), uint8(CountersigOracleBond.Status.None));
    }

    function test_withdrawBond_beforeCooldown_reverts() public {
        _bondAndAdmit(op1, BOND);
        vm.prank(op1);
        bond.initiateUnbond();
        uint256 claimableAt = block.timestamp + UNBOND;
        vm.expectRevert(abi.encodeWithSelector(CountersigOracleBond.UnbondingActive.selector, op1, claimableAt));
        vm.prank(op1);
        bond.withdrawBond();
    }

    function test_withdrawBond_whileActive_reverts() public {
        _bondAndAdmit(op1, BOND);
        vm.expectRevert(abi.encodeWithSelector(
            CountersigOracleBond.WrongStatus.selector, op1, CountersigOracleBond.Status.Active
        ));
        vm.prank(op1);
        bond.withdrawBond();
    }

    function test_removeOperator_forcesExit() public {
        _bondAndAdmit(op1, BOND);
        vm.prank(admin);
        bond.removeOperator(op1);
        assertFalse(bond.isActiveOperator(op1));
        assertEq(bond.activeCount(), 0);
        (, CountersigOracleBond.Status status,) = bond.operators(op1);
        assertEq(uint8(status), uint8(CountersigOracleBond.Status.Exiting));
    }

    // -------------------------------------------------------------------------
    // activeCount across multiple operators
    // -------------------------------------------------------------------------

    function test_activeCount_tracksSet() public {
        _bondAndAdmit(op1, BOND);
        _bondAndAdmit(op2, BOND);
        assertEq(bond.activeCount(), 2);
        vm.prank(op1);
        bond.initiateUnbond();
        assertEq(bond.activeCount(), 1);
    }

    // -------------------------------------------------------------------------
    // Admin params
    // -------------------------------------------------------------------------

    function test_setters_adminOnly() public {
        vm.startPrank(admin);
        bond.setBondAmount(2000e18);
        bond.setUnbondingPeriod(14 days);
        bond.setSlashBeneficiary(stranger);
        vm.stopPrank();
        assertEq(bond.bondAmount(), 2000e18);
        assertEq(bond.unbondingPeriod(), 14 days);
        assertEq(bond.slashBeneficiary(), stranger);

        vm.expectRevert(CountersigOracleBond.ZeroAddress.selector);
        vm.prank(admin);
        bond.setSlashBeneficiary(address(0));

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
        ));
        vm.prank(stranger);
        bond.setBondAmount(1);
    }

    // -------------------------------------------------------------------------
    // Storage layout — pins operators mapping to slot 5
    // -------------------------------------------------------------------------

    function test_storageLayout_operatorsPinnedToSlot5() public {
        vm.prank(op1);
        bond.depositBond(1234e18);
        // First field of Operator is `bond`.
        bytes32 slot = keccak256(abi.encode(op1, uint256(5)));
        assertEq(uint256(vm.load(address(bond), slot)), 1234e18);
    }
}
