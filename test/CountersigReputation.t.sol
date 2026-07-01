// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "../src/CountersigReputation.sol";

contract CountersigReputationTest is Test {
    CountersigReputation rep;

    address admin     = makeAddr("admin");
    address oracle    = makeAddr("oracle");
    address staking   = makeAddr("staking");
    address committee = makeAddr("committee");
    address stranger  = makeAddr("stranger");

    bytes32 constant DID = keccak256("did:countersig:11155111:0xagent");
    uint256 constant CHALLENGE_WINDOW = 1 hours;

    CountersigReputation.ReputationData maxScore = CountersigReputation.ReputationData({
        feeScore: 30,
        successScore: 25,
        ageScore: 20,
        externalScore: 15,
        communityScore: 5,
        propagationScore: 5,
        lastUpdated: 0
    });

    function setUp() public {
        CountersigReputation impl = new CountersigReputation();
        bytes memory init = abi.encodeCall(
            CountersigReputation.initialize,
            (admin, oracle, staking, committee, CHALLENGE_WINDOW)
        );
        rep = CountersigReputation(address(new ERC1967Proxy(address(impl), init)));
    }

    // Propose then warp past the challenge window and finalize — the common path
    // used by tests that just need a score live on-chain.
    function _proposeAndFinalize(bytes32 didHash, CountersigReputation.ReputationData memory data) internal {
        vm.prank(oracle);
        rep.proposeReputation(didHash, data);
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        rep.finalizeReputation(didHash);
    }

    // -------------------------------------------------------------------------
    // proposeReputation
    // -------------------------------------------------------------------------

    function test_proposeReputation_success() public {
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);

        CountersigReputation.PendingScore memory pending = rep.getPendingScore(DID);
        assertTrue(pending.exists);
        assertEq(pending.data.feeScore, 30);
        assertEq(pending.proposedAt, block.timestamp);

        // Not live yet — still zero until finalized.
        assertEq(rep.getTotalScore(DID), 0);
    }

    function test_proposeReputation_reverts_notOracle() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                rep.ORACLE_ROLE()
            )
        );
        vm.prank(stranger);
        rep.proposeReputation(DID, maxScore);
    }

    function test_proposeReputation_replacesExistingPending() public {
        vm.startPrank(oracle);
        rep.proposeReputation(DID, maxScore);

        CountersigReputation.ReputationData memory lower = maxScore;
        lower.feeScore = 10;
        vm.warp(block.timestamp + 10);
        rep.proposeReputation(DID, lower);
        vm.stopPrank();

        CountersigReputation.PendingScore memory pending = rep.getPendingScore(DID);
        assertEq(pending.data.feeScore, 10);
        assertEq(pending.proposedAt, block.timestamp);
    }

    function test_proposeReputation_reverts_feeScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.feeScore = 31;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "feeScore", 31, 30)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    function test_proposeReputation_reverts_successScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.successScore = 26;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "successScore", 26, 25)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    function test_proposeReputation_reverts_ageScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.ageScore = 21;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "ageScore", 21, 20)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    function test_proposeReputation_reverts_externalScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.externalScore = 16;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "externalScore", 16, 15)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    function test_proposeReputation_reverts_communityScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.communityScore = 6;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "communityScore", 6, 5)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    function test_proposeReputation_reverts_propagationScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.propagationScore = 6;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "propagationScore", 6, 5)
        );
        vm.prank(oracle);
        rep.proposeReputation(DID, bad);
    }

    // -------------------------------------------------------------------------
    // finalizeReputation
    // -------------------------------------------------------------------------

    function test_finalizeReputation_success() public {
        _proposeAndFinalize(DID, maxScore);

        CountersigReputation.ReputationData memory stored = rep.getReputation(DID);
        assertEq(stored.feeScore, 30);
        assertEq(stored.successScore, 25);
        assertEq(stored.ageScore, 20);
        assertEq(stored.externalScore, 15);
        assertEq(stored.communityScore, 5);
        assertEq(stored.propagationScore, 5);

        CountersigReputation.PendingScore memory pending = rep.getPendingScore(DID);
        assertFalse(pending.exists);
    }

    function test_finalizeReputation_reverts_beforeWindowElapsed() public {
        uint256 proposedAt = block.timestamp;
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);

        vm.expectRevert(
            abi.encodeWithSelector(
                CountersigReputation.ChallengeWindowActive.selector,
                DID,
                proposedAt + CHALLENGE_WINDOW
            )
        );
        rep.finalizeReputation(DID);
    }

    function test_finalizeReputation_reverts_noPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.NoScorePending.selector, DID)
        );
        rep.finalizeReputation(DID);
    }

    function test_finalizeReputation_callableByAnyone() public {
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        vm.prank(stranger);
        rep.finalizeReputation(DID);

        assertEq(rep.getTotalScore(DID), 100);
    }

    // -------------------------------------------------------------------------
    // rejectReputation
    // -------------------------------------------------------------------------

    function test_rejectReputation_success() public {
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);

        vm.prank(committee);
        rep.rejectReputation(DID);

        CountersigReputation.PendingScore memory pending = rep.getPendingScore(DID);
        assertFalse(pending.exists);
        // Existing finalized score (none yet) is untouched — still zero, not the rejected proposal.
        assertEq(rep.getTotalScore(DID), 0);
    }

    function test_rejectReputation_doesNotAffectExistingFinalizedScore() public {
        _proposeAndFinalize(DID, maxScore);

        CountersigReputation.ReputationData memory lower = maxScore;
        lower.feeScore = 5;
        vm.prank(oracle);
        rep.proposeReputation(DID, lower);

        vm.prank(committee);
        rep.rejectReputation(DID);

        assertEq(rep.getTotalScore(DID), 100);
    }

    function test_rejectReputation_reverts_notCommittee() public {
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                rep.SLASHING_COMMITTEE_ROLE()
            )
        );
        vm.prank(stranger);
        rep.rejectReputation(DID);
    }

    function test_rejectReputation_reverts_noPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.NoScorePending.selector, DID)
        );
        vm.prank(committee);
        rep.rejectReputation(DID);
    }

    function test_rejectReputation_reverts_afterWindowExpired() public {
        uint256 proposedAt = block.timestamp;
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CountersigReputation.ChallengeWindowExpired.selector,
                DID,
                proposedAt + CHALLENGE_WINDOW
            )
        );
        vm.prank(committee);
        rep.rejectReputation(DID);
    }

    // -------------------------------------------------------------------------
    // getTotalScore
    // -------------------------------------------------------------------------

    function test_getTotalScore_maxIs100() public {
        _proposeAndFinalize(DID, maxScore);
        assertEq(rep.getTotalScore(DID), 100);
    }

    function test_getTotalScore_zeroBeforeFirstUpdate() public view {
        assertEq(rep.getTotalScore(DID), 0);
    }

    function testFuzz_getTotalScore_neverExceeds100(
        uint8 fee,
        uint8 success,
        uint8 age,
        uint8 ext,
        uint8 community,
        uint8 propagation
    ) public {
        fee         = uint8(bound(fee, 0, 30));
        success     = uint8(bound(success, 0, 25));
        age         = uint8(bound(age, 0, 20));
        ext         = uint8(bound(ext, 0, 15));
        community   = uint8(bound(community, 0, 5));
        propagation = uint8(bound(propagation, 0, 5));

        CountersigReputation.ReputationData memory data = CountersigReputation.ReputationData({
            feeScore: fee,
            successScore: success,
            ageScore: age,
            externalScore: ext,
            communityScore: community,
            propagationScore: propagation,
            lastUpdated: 0
        });

        _proposeAndFinalize(DID, data);

        assertLe(rep.getTotalScore(DID), 100);
    }

    // -------------------------------------------------------------------------
    // zeroReputation
    // -------------------------------------------------------------------------

    function test_zeroReputation_clearsAllScores() public {
        _proposeAndFinalize(DID, maxScore);
        assertEq(rep.getTotalScore(DID), 100);

        vm.prank(staking);
        rep.zeroReputation(DID);

        assertEq(rep.getTotalScore(DID), 0);
    }

    function test_zeroReputation_clearsPendingProposal() public {
        vm.prank(oracle);
        rep.proposeReputation(DID, maxScore);

        vm.prank(staking);
        rep.zeroReputation(DID);

        CountersigReputation.PendingScore memory pending = rep.getPendingScore(DID);
        assertFalse(pending.exists);
    }

    function test_zeroReputation_reverts_notStaking() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                rep.STAKING_CORE_ROLE()
            )
        );
        vm.prank(stranger);
        rep.zeroReputation(DID);
    }

    // -------------------------------------------------------------------------
    // meetsThreshold
    // -------------------------------------------------------------------------

    function test_meetsThreshold_trueAbove() public {
        _proposeAndFinalize(DID, maxScore);
        assertTrue(rep.meetsThreshold(DID, 60));
        assertTrue(rep.meetsThreshold(DID, 100));
    }

    function test_meetsThreshold_falseBelow() public view {
        assertFalse(rep.meetsThreshold(DID, 1));
    }

    // -------------------------------------------------------------------------
    // setChallengeWindow
    // -------------------------------------------------------------------------

    function test_setChallengeWindow_success() public {
        vm.prank(admin);
        rep.setChallengeWindow(2 hours);
        assertEq(rep.challengeWindow(), 2 hours);
    }

    function test_setChallengeWindow_reverts_notAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        rep.setChallengeWindow(2 hours);
    }
}
