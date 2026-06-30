// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/CountersigIdentity.sol";
import "../src/CountersigReputation.sol";
import "../src/CountersigStaking.sol";

/// Minimal ERC20 for testing only.
contract MockCSIG is ERC20 {
    constructor() ERC20("Countersig", "CSIG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CountersigStakingTest is Test {
    MockCSIG csig;
    CountersigIdentity identity;
    CountersigReputation rep;
    CountersigStaking staking;

    address admin     = makeAddr("admin");
    address committee = makeAddr("committee");
    address operator  = makeAddr("operator");
    address agentAddr = makeAddr("agent");
    address victim    = makeAddr("victim");
    address stranger  = makeAddr("stranger");

    bytes32 constant PUB_KEY = bytes32(uint256(0xdeadbeef));

    uint256 constant MIN_STAKE  = 1000e18;
    uint256 constant CHALLENGE  = 7 days;

    bytes32 didHash;

    function setUp() public {
        csig = new MockCSIG();

        // Deploy implementations.
        CountersigIdentity identityImpl = new CountersigIdentity();
        CountersigReputation repImpl    = new CountersigReputation();
        CountersigStaking stakingImpl   = new CountersigStaking();

        // Deploy identity proxy (no staking address yet -- grant role after staking is deployed).
        identity = CountersigIdentity(address(new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(CountersigIdentity.initialize, (admin, address(0)))
        )));

        // Deploy rep proxy (no staking address yet).
        rep = CountersigReputation(address(new ERC1967Proxy(
            address(repImpl),
            abi.encodeCall(CountersigReputation.initialize, (admin, address(0), address(0)))
        )));

        // Deploy staking proxy with identity + rep.
        staking = CountersigStaking(address(new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeCall(CountersigStaking.initialize, (
                admin,
                address(identity),
                address(rep),
                address(csig),
                MIN_STAKE,
                CHALLENGE
            ))
        )));

        // Wire up cross-contract roles.
        vm.startPrank(admin);
        identity.grantRole(identity.STAKING_CORE_ROLE(), address(staking));
        rep.grantRole(rep.STAKING_CORE_ROLE(), address(staking));
        staking.grantRole(staking.SLASHING_COMMITTEE_ROLE(), committee);
        vm.stopPrank();

        // Register an agent.
        vm.prank(operator);
        didHash = identity.registerAgent(agentAddr, PUB_KEY);

        // Fund operator and approve staking.
        csig.mint(operator, 10_000e18);
        vm.prank(operator);
        csig.approve(address(staking), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // depositStake
    // -------------------------------------------------------------------------

    function test_depositStake_success() public {
        vm.prank(operator);
        staking.depositStake(didHash, MIN_STAKE);

        assertEq(staking.getStake(didHash), MIN_STAKE);
        assertTrue(staking.hasMinimumStake(didHash));
    }

    function test_depositStake_accumulates() public {
        vm.startPrank(operator);
        staking.depositStake(didHash, MIN_STAKE / 2);
        staking.depositStake(didHash, MIN_STAKE / 2);
        vm.stopPrank();

        assertEq(staking.getStake(didHash), MIN_STAKE);
    }

    function test_depositStake_reverts_notOperator() public {
        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.NotOperator.selector, didHash, stranger)
        );
        vm.prank(stranger);
        staking.depositStake(didHash, MIN_STAKE);
    }

    function test_depositStake_reverts_agentNotActive() public {
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.AgentNotActive.selector, didHash)
        );
        vm.prank(operator);
        staking.depositStake(didHash, MIN_STAKE);
    }

    // -------------------------------------------------------------------------
    // withdrawStake
    // -------------------------------------------------------------------------

    function _deposit() internal {
        vm.prank(operator);
        staking.depositStake(didHash, MIN_STAKE * 2);
    }

    function test_withdrawStake_partialAllowed() public {
        _deposit();

        vm.prank(operator);
        staking.withdrawStake(didHash, MIN_STAKE);

        assertEq(staking.getStake(didHash), MIN_STAKE);
    }

    function test_withdrawStake_reverts_belowMinWhileActive() public {
        _deposit();

        uint256 tooMuch = MIN_STAKE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CountersigStaking.InsufficientStake.selector,
                didHash,
                MIN_STAKE * 2 - tooMuch,
                MIN_STAKE
            )
        );
        vm.prank(operator);
        staking.withdrawStake(didHash, tooMuch);
    }

    function test_withdrawStake_fullAllowedWhenSuspended() public {
        _deposit();

        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        uint256 before = csig.balanceOf(operator);

        vm.prank(operator);
        staking.withdrawStake(didHash, MIN_STAKE * 2);

        assertEq(csig.balanceOf(operator), before + MIN_STAKE * 2);
        assertEq(staking.getStake(didHash), 0);
    }

    function test_withdrawStake_reverts_pendingSlash() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.SlashAlreadyPending.selector, didHash)
        );
        vm.prank(operator);
        staking.withdrawStake(didHash, MIN_STAKE);
    }

    // -------------------------------------------------------------------------
    // initiateSlash
    // -------------------------------------------------------------------------

    function test_initiateSlash_success() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "evidence");

        CountersigStaking.SlashProposal memory p = staking.getSlashProposal(didHash);
        assertEq(p.reporter, committee);
        assertEq(p.victim, victim);
        assertEq(uint8(p.state), uint8(CountersigStaking.SlashState.Pending));

        // Agent should be suspended during challenge window.
        assertFalse(identity.isActive(didHash));
    }

    function test_initiateSlash_reverts_notCommittee() public {
        _deposit();

        vm.expectRevert();
        vm.prank(stranger);
        staking.initiateSlash(didHash, victim, "");
    }

    function test_initiateSlash_reverts_noStake() public {
        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.NoStake.selector, didHash)
        );
        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");
    }

    function test_initiateSlash_reverts_alreadyPending() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.SlashAlreadyPending.selector, didHash)
        );
        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");
    }

    // -------------------------------------------------------------------------
    // disputeSlash
    // -------------------------------------------------------------------------

    function test_disputeSlash_success() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        vm.prank(operator);
        staking.disputeSlash(didHash);

        CountersigStaking.SlashProposal memory p = staking.getSlashProposal(didHash);
        assertEq(uint8(p.state), uint8(CountersigStaking.SlashState.Cancelled));

        // Agent reinstated.
        assertTrue(identity.isActive(didHash));
    }

    function test_disputeSlash_reverts_afterChallengePeriod() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        vm.warp(block.timestamp + CHALLENGE + 1);

        // Period has ended; revert expected (wrong branch of the if).
        vm.expectRevert();
        vm.prank(operator);
        staking.disputeSlash(didHash);
    }

    function test_disputeSlash_reverts_notOperator() public {
        _deposit();

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.NotOperator.selector, didHash, stranger)
        );
        vm.prank(stranger);
        staking.disputeSlash(didHash);
    }

    // -------------------------------------------------------------------------
    // executeSlash
    // -------------------------------------------------------------------------

    function _setupPendingSlash() internal {
        _deposit(); // 2 * MIN_STAKE

        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "evidence");

        vm.warp(block.timestamp + CHALLENGE + 1);
    }

    function test_executeSlash_distributesCorrectly() public {
        _setupPendingSlash();

        uint256 slashable       = MIN_STAKE * 2;
        uint256 expectedBurned  = slashable / 2;
        uint256 expectedVictim  = slashable / 4;
        uint256 expectedReporter = slashable - expectedBurned - expectedVictim;

        vm.prank(stranger); // execution is permissionless
        staking.executeSlash(didHash);

        assertEq(csig.balanceOf(address(0xdead)), expectedBurned);
        assertEq(csig.balanceOf(victim), expectedVictim);
        assertEq(csig.balanceOf(committee), expectedReporter);
        assertEq(staking.getStake(didHash), 0);
    }

    function test_executeSlash_marksAgentSlashed() public {
        _setupPendingSlash();

        staking.executeSlash(didHash);

        assertEq(
            uint8(identity.getIdentity(didHash).status),
            uint8(CountersigIdentity.AgentStatus.Slashed)
        );
    }

    function test_executeSlash_zerosReputation() public {
        // Give the agent a score via oracle.
        bytes32 oracleRole = rep.ORACLE_ROLE();
        vm.prank(admin);
        rep.grantRole(oracleRole, admin);

        CountersigReputation.ReputationData memory data = CountersigReputation.ReputationData({
            feeScore: 30, successScore: 25, ageScore: 20,
            externalScore: 15, communityScore: 5, propagationScore: 5,
            lastUpdated: 0
        });
        vm.prank(admin);
        rep.updateReputation(didHash, data);
        assertEq(rep.getTotalScore(didHash), 100);

        _setupPendingSlash();
        staking.executeSlash(didHash);

        assertEq(rep.getTotalScore(didHash), 0);
    }

    function test_executeSlash_reverts_duringChallengePeriod() public {
        _deposit();

        uint256 initiatedAt = block.timestamp;
        vm.prank(committee);
        staking.initiateSlash(didHash, victim, "");

        uint256 deadline = initiatedAt + CHALLENGE;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.ChallengePeriodActive.selector, didHash, deadline)
        );
        staking.executeSlash(didHash);
    }

    function test_executeSlash_reverts_noPendingProposal() public {
        vm.expectRevert(
            abi.encodeWithSelector(CountersigStaking.NoActivePendingSlash.selector, didHash)
        );
        staking.executeSlash(didHash);
    }

    // -------------------------------------------------------------------------
    // Fuzz: stake roundtrip
    // -------------------------------------------------------------------------

    function testFuzz_stakeAndWithdraw(uint256 amount) public {
        amount = bound(amount, MIN_STAKE, 10_000e18);

        csig.mint(operator, amount);
        vm.prank(operator);
        csig.approve(address(staking), amount);

        vm.prank(operator);
        staking.depositStake(didHash, amount);

        // Suspend to allow full withdrawal below minimum.
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        uint256 before = csig.balanceOf(operator);

        vm.prank(operator);
        staking.withdrawStake(didHash, amount);

        assertEq(csig.balanceOf(operator), before + amount);
        assertEq(staking.getStake(didHash), 0);
    }
}
