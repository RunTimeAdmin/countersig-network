// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/CSIG.sol";
import "../src/TeamVesting.sol";
import "../src/TreasuryVesting.sol";

/// Composes the full TGE (timelock + vesting + token) exactly like
/// DeployMainnet.s.sol and verifies distribution, timelock config, and the
/// vesting schedules against real CSIG holdings.
contract MainnetTGETest is Test {
    TimelockController timelock;
    TreasuryVesting treasuryVesting;
    TeamVesting teamVesting;
    CSIG csig;

    address gov        = makeAddr("gov");
    address team       = makeAddr("team");
    address publicSale = makeAddr("publicSale");
    address liquidity  = makeAddr("liquidity");

    uint64 start;

    uint256 constant DELAY = 7 days;

    function setUp() public {
        start = uint64(block.timestamp);

        address[] memory proposers = new address[](1);
        proposers[0] = gov;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        treasuryVesting = new TreasuryVesting(address(timelock), start);
        teamVesting = new TeamVesting(team, start);

        csig = new CSIG(
            address(treasuryVesting),
            address(teamVesting),
            address(timelock),
            publicSale,
            liquidity
        );
    }

    // -------------------------------------------------------------------------
    // Distribution & composition
    // -------------------------------------------------------------------------

    function test_distribution() public view {
        assertEq(csig.totalSupply(), 1_000_000_000e18);
        assertEq(csig.balanceOf(address(treasuryVesting)), 400_000_000e18);
        assertEq(csig.balanceOf(address(teamVesting)),     200_000_000e18);
        assertEq(csig.balanceOf(address(timelock)),        150_000_000e18); // ecosystem
        assertEq(csig.balanceOf(publicSale),               150_000_000e18);
        assertEq(csig.balanceOf(liquidity),                100_000_000e18);
    }

    function test_timelockConfig() public view {
        assertEq(timelock.getMinDelay(), DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    function test_vestingScheduleParams() public view {
        assertEq(treasuryVesting.duration(), 5 * 365 days);
        assertEq(treasuryVesting.start(), start);
        assertEq(treasuryVesting.owner(), address(timelock)); // beneficiary

        assertEq(teamVesting.duration(), 4 * 365 days);
        assertEq(teamVesting.cliff(), uint256(start) + 365 days);
        assertEq(teamVesting.owner(), team);
    }

    // -------------------------------------------------------------------------
    // Team vesting — 4yr / 1yr cliff
    // -------------------------------------------------------------------------

    function test_team_nothingBeforeCliff() public {
        vm.warp(start + 365 days - 1);
        assertEq(teamVesting.releasable(address(csig)), 0);
    }

    function test_team_25pctAtCliff() public {
        vm.warp(start + 365 days);
        // 200M * 365/1460 = 50M
        assertEq(teamVesting.releasable(address(csig)), 50_000_000e18);
    }

    function test_team_50pctAtHalf() public {
        vm.warp(start + 2 * 365 days);
        assertEq(teamVesting.releasable(address(csig)), 100_000_000e18);
    }

    function test_team_fullAtEnd() public {
        vm.warp(start + 4 * 365 days);
        assertEq(teamVesting.releasable(address(csig)), 200_000_000e18);
    }

    function test_team_releaseTransfersToBeneficiary() public {
        vm.warp(start + 4 * 365 days);
        teamVesting.release(address(csig)); // permissionless
        assertEq(csig.balanceOf(team), 200_000_000e18);
        assertEq(csig.balanceOf(address(teamVesting)), 0);
    }

    // -------------------------------------------------------------------------
    // Treasury vesting — 5yr linear -> timelock
    // -------------------------------------------------------------------------

    function test_treasury_nothingAtStart() public view {
        assertEq(treasuryVesting.releasable(address(csig)), 0);
    }

    function test_treasury_20pctAtYear1() public {
        vm.warp(start + 365 days);
        // 400M * 365/1825 = 80M
        assertEq(treasuryVesting.releasable(address(csig)), 80_000_000e18);
    }

    function test_treasury_fullAtEnd() public {
        vm.warp(start + 5 * 365 days);
        assertEq(treasuryVesting.releasable(address(csig)), 400_000_000e18);
    }

    function test_treasury_releaseGoesToTimelock() public {
        vm.warp(start + 5 * 365 days);
        treasuryVesting.release(address(csig));
        // Timelock already held 150M ecosystem; now +400M treasury.
        assertEq(csig.balanceOf(address(timelock)), 550_000_000e18);
    }
}
