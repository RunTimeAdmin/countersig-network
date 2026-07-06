// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "../src/CountersigIdentity.sol";

contract CountersigIdentityTest is Test {
    CountersigIdentity identity;

    address admin    = makeAddr("admin");
    address staking  = makeAddr("staking");
    address operator = makeAddr("operator");
    address agent    = makeAddr("agent");
    address stranger = makeAddr("stranger");

    bytes32 constant PUB_KEY   = bytes32(uint256(0xdeadbeef));
    bytes32 constant PUB_KEY_2 = bytes32(uint256(0xcafebabe));

    function setUp() public {
        CountersigIdentity impl = new CountersigIdentity();
        bytes memory init = abi.encodeCall(CountersigIdentity.initialize, (admin, staking));
        identity = CountersigIdentity(address(new ERC1967Proxy(address(impl), init)));
    }

    // -------------------------------------------------------------------------
    // computeDidHash
    // -------------------------------------------------------------------------

    function test_computeDidHash_isDeterministic() public view {
        assertEq(identity.computeDidHash(agent), identity.computeDidHash(agent));
    }

    function test_computeDidHash_differsAcrossAddresses() public view {
        assertNotEq(identity.computeDidHash(agent), identity.computeDidHash(stranger));
    }

    function testFuzz_computeDidHash_unique(address a, address b) public view {
        vm.assume(a != b);
        assertNotEq(identity.computeDidHash(a), identity.computeDidHash(b));
    }

    // -------------------------------------------------------------------------
    // registerAgent
    // -------------------------------------------------------------------------

    function test_registerAgent_success() public {
        vm.prank(operator);
        bytes32 didHash = identity.registerAgent(agent, PUB_KEY);

        assertEq(didHash, identity.computeDidHash(agent));

        CountersigIdentity.AgentIdentity memory id = identity.getIdentity(didHash);
        assertEq(id.operator, operator);
        assertEq(id.agentAddress, agent);
        assertEq(id.ed25519PubKey, PUB_KEY);
        assertEq(uint8(id.status), uint8(CountersigIdentity.AgentStatus.Active));
        assertGt(id.registeredAt, 0);
    }

    function test_registerAgent_emitsEvent() public {
        bytes32 expectedHash = identity.computeDidHash(agent);
        vm.expectEmit(true, true, true, true);
        emit CountersigIdentity.AgentRegistered(expectedHash, operator, agent, PUB_KEY);

        vm.prank(operator);
        identity.registerAgent(agent, PUB_KEY);
    }

    function test_registerAgent_reverts_zeroPubKey() public {
        vm.expectRevert(CountersigIdentity.ZeroPubKey.selector);
        vm.prank(operator);
        identity.registerAgent(agent, bytes32(0));
    }

    function test_registerAgent_reverts_zeroAgentAddress() public {
        vm.expectRevert(CountersigIdentity.ZeroAgentAddress.selector);
        vm.prank(operator);
        identity.registerAgent(address(0), PUB_KEY);
    }

    function test_registerAgent_reverts_duplicate() public {
        vm.prank(operator);
        identity.registerAgent(agent, PUB_KEY);

        bytes32 didHash = identity.computeDidHash(agent);
        vm.expectRevert(abi.encodeWithSelector(CountersigIdentity.AlreadyRegistered.selector, didHash));
        vm.prank(operator);
        identity.registerAgent(agent, PUB_KEY_2);
    }

    function test_registerAgent_tracksOperatorAgents() public {
        address agent2 = makeAddr("agent2");
        vm.startPrank(operator);
        bytes32 h1 = identity.registerAgent(agent, PUB_KEY);
        bytes32 h2 = identity.registerAgent(agent2, PUB_KEY_2);
        vm.stopPrank();

        bytes32[] memory agents = identity.getOperatorAgents(operator);
        assertEq(agents.length, 2);
        assertEq(agents[0], h1);
        assertEq(agents[1], h2);
    }

    // -------------------------------------------------------------------------
    // rotatePublicKey
    // -------------------------------------------------------------------------

    function _register() internal returns (bytes32 didHash) {
        vm.prank(operator);
        didHash = identity.registerAgent(agent, PUB_KEY);
    }

    function test_rotatePublicKey_success() public {
        bytes32 didHash = _register();

        vm.prank(operator);
        identity.rotatePublicKey(didHash, PUB_KEY_2);

        assertEq(identity.getIdentity(didHash).ed25519PubKey, PUB_KEY_2);
    }

    function test_rotatePublicKey_reverts_notOperator() public {
        bytes32 didHash = _register();

        vm.expectRevert(
            abi.encodeWithSelector(CountersigIdentity.NotOperator.selector, didHash, stranger)
        );
        vm.prank(stranger);
        identity.rotatePublicKey(didHash, PUB_KEY_2);
    }

    function test_rotatePublicKey_reverts_onSlashed() public {
        bytes32 didHash = _register();

        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);

        vm.expectRevert(
            abi.encodeWithSelector(CountersigIdentity.SlashedAgentImmutable.selector, didHash)
        );
        vm.prank(operator);
        identity.rotatePublicKey(didHash, PUB_KEY_2);
    }

    function test_rotatePublicKey_allowedWhileSuspended() public {
        bytes32 didHash = _register();

        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        vm.prank(operator);
        identity.rotatePublicKey(didHash, PUB_KEY_2);

        assertEq(identity.getIdentity(didHash).ed25519PubKey, PUB_KEY_2);
    }

    // -------------------------------------------------------------------------
    // updateStatus
    // -------------------------------------------------------------------------

    function test_updateStatus_operatorCanSuspend() public {
        bytes32 didHash = _register();

        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        assertEq(uint8(identity.getIdentity(didHash).status), uint8(CountersigIdentity.AgentStatus.Suspended));
        assertFalse(identity.isActive(didHash));
    }

    function test_updateStatus_operatorCanReinstate() public {
        bytes32 didHash = _register();

        vm.startPrank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
        vm.stopPrank();

        assertTrue(identity.isActive(didHash));
    }

    function test_updateStatus_stakingCanSlash() public {
        bytes32 didHash = _register();

        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);

        assertEq(uint8(identity.getIdentity(didHash).status), uint8(CountersigIdentity.AgentStatus.Slashed));
        assertFalse(identity.isActive(didHash));
    }

    function test_updateStatus_strangerCannotSlash() public {
        bytes32 didHash = _register();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                identity.STAKING_CORE_ROLE()
            )
        );
        vm.prank(stranger);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);
    }

    function test_updateStatus_operatorCannotSlash() public {
        bytes32 didHash = _register();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                identity.STAKING_CORE_ROLE()
            )
        );
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);
    }

    function test_updateStatus_slashedIsTerminal() public {
        bytes32 didHash = _register();

        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);

        vm.expectRevert(
            abi.encodeWithSelector(CountersigIdentity.SlashedAgentImmutable.selector, didHash)
        );
        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
    }

    function test_updateStatus_operatorCannotLiftStakingSuspension() public {
        bytes32 didHash = _register();

        // Staking core suspends the agent (as initiateSlash does).
        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);
        assertTrue(identity.slashSuspended(didHash));

        // Operator must not be able to reactivate mid-slash.
        vm.expectRevert(
            abi.encodeWithSelector(CountersigIdentity.SlashSuspensionLocked.selector, didHash)
        );
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
    }

    function test_updateStatus_stakingReinstateClearsLock() public {
        bytes32 didHash = _register();

        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        // Staking reinstates (as disputeSlash does) — lock clears.
        vm.prank(staking);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
        assertFalse(identity.slashSuspended(didHash));
        assertTrue(identity.isActive(didHash));

        // Operator regains normal control afterward.
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
        assertTrue(identity.isActive(didHash));
    }

    function test_updateStatus_operatorSelfSuspendStaysReversible() public {
        bytes32 didHash = _register();

        // A self-suspend by the operator is not a slash lock.
        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);
        assertFalse(identity.slashSuspended(didHash));

        vm.prank(operator);
        identity.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);
        assertTrue(identity.isActive(didHash));
    }

    function test_updateStatus_reverts_notRegistered() public {
        bytes32 fakeHash = keccak256("nonexistent");
        vm.expectRevert(
            abi.encodeWithSelector(CountersigIdentity.NotRegistered.selector, fakeHash)
        );
        vm.prank(operator);
        identity.updateStatus(fakeHash, CountersigIdentity.AgentStatus.Suspended);
    }

    // -------------------------------------------------------------------------
    // isActive
    // -------------------------------------------------------------------------

    function test_isActive_falseBeforeRegistration() public view {
        assertFalse(identity.isActive(identity.computeDidHash(agent)));
    }

    function test_isActive_trueAfterRegistration() public {
        bytes32 didHash = _register();
        assertTrue(identity.isActive(didHash));
    }
}
