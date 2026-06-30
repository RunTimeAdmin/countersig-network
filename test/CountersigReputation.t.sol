// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/CountersigReputation.sol";

contract CountersigReputationTest is Test {
    CountersigReputation rep;

    address admin    = makeAddr("admin");
    address oracle   = makeAddr("oracle");
    address staking  = makeAddr("staking");
    address stranger = makeAddr("stranger");

    bytes32 constant DID = keccak256("did:countersig:11155111:0xagent");

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
        bytes memory init = abi.encodeCall(CountersigReputation.initialize, (admin, oracle, staking));
        rep = CountersigReputation(address(new ERC1967Proxy(address(impl), init)));
    }

    // -------------------------------------------------------------------------
    // updateReputation
    // -------------------------------------------------------------------------

    function test_updateReputation_success() public {
        vm.prank(oracle);
        rep.updateReputation(DID, maxScore);

        CountersigReputation.ReputationData memory stored = rep.getReputation(DID);
        assertEq(stored.feeScore, 30);
        assertEq(stored.successScore, 25);
        assertEq(stored.ageScore, 20);
        assertEq(stored.externalScore, 15);
        assertEq(stored.communityScore, 5);
        assertEq(stored.propagationScore, 5);
    }

    function test_updateReputation_reverts_notOracle() public {
        vm.expectRevert();
        vm.prank(stranger);
        rep.updateReputation(DID, maxScore);
    }

    function test_updateReputation_reverts_feeScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.feeScore = 31;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "feeScore", 31, 30)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    function test_updateReputation_reverts_successScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.successScore = 26;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "successScore", 26, 25)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    function test_updateReputation_reverts_ageScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.ageScore = 21;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "ageScore", 21, 20)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    function test_updateReputation_reverts_externalScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.externalScore = 16;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "externalScore", 16, 15)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    function test_updateReputation_reverts_communityScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.communityScore = 6;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "communityScore", 6, 5)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    function test_updateReputation_reverts_propagationScoreOverMax() public {
        CountersigReputation.ReputationData memory bad = maxScore;
        bad.propagationScore = 6;
        vm.expectRevert(
            abi.encodeWithSelector(CountersigReputation.ScoreOutOfRange.selector, "propagationScore", 6, 5)
        );
        vm.prank(oracle);
        rep.updateReputation(DID, bad);
    }

    // -------------------------------------------------------------------------
    // getTotalScore
    // -------------------------------------------------------------------------

    function test_getTotalScore_maxIs100() public {
        vm.prank(oracle);
        rep.updateReputation(DID, maxScore);
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

        vm.prank(oracle);
        rep.updateReputation(DID, data);

        assertLe(rep.getTotalScore(DID), 100);
    }

    // -------------------------------------------------------------------------
    // zeroReputation
    // -------------------------------------------------------------------------

    function test_zeroReputation_clearsAllScores() public {
        vm.prank(oracle);
        rep.updateReputation(DID, maxScore);
        assertEq(rep.getTotalScore(DID), 100);

        vm.prank(staking);
        rep.zeroReputation(DID);

        assertEq(rep.getTotalScore(DID), 0);
    }

    function test_zeroReputation_reverts_notStaking() public {
        vm.expectRevert();
        vm.prank(stranger);
        rep.zeroReputation(DID);
    }

    // -------------------------------------------------------------------------
    // meetsThreshold
    // -------------------------------------------------------------------------

    function test_meetsThreshold_trueAbove() public {
        vm.prank(oracle);
        rep.updateReputation(DID, maxScore);
        assertTrue(rep.meetsThreshold(DID, 60));
        assertTrue(rep.meetsThreshold(DID, 100));
    }

    function test_meetsThreshold_falseBelow() public view {
        assertFalse(rep.meetsThreshold(DID, 1));
    }
}
