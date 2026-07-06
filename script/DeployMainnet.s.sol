// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/CSIG.sol";
import "../src/TeamVesting.sol";
import "../src/TreasuryVesting.sol";

/**
 * @title DeployMainnet
 * @notice Full TGE deployment for the fixed-supply mainnet $CSIG token.
 *
 * Deploys, in order:
 *   1. TimelockController — 7-day mainnet delay (§9). Proposer + canceller =
 *      governance multisig; executor = anyone (address(0)); no separate admin
 *      (the timelock self-administers).
 *   2. TreasuryVesting — 5-year linear, beneficiary = timelock (§2, 40%).
 *   3. TeamVesting     — 4-year vest / 1-year cliff (§2, 20%).
 *   4. CSIG            — mints 1B once and distributes to the five buckets:
 *        treasury  -> TreasuryVesting
 *        team      -> TeamVesting
 *        ecosystem -> timelock  (governance disburses milestone-based, §2, 15%)
 *        public    -> publicSale recipient (presale distributor; unsold burned)
 *        liquidity -> liquidity wallet
 *
 * Post-deploy it asserts every balance, the timelock delay/roles, and the vesting
 * schedules, so a misconfigured deploy reverts instead of shipping.
 *
 * Usage (dry-run first WITHOUT --broadcast):
 *   forge script script/DeployMainnet.s.sol --rpc-url $RPC --broadcast --verify -vvvv
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY
 * Optional env (default to the deployer for testnet rehearsals):
 *   GOV_MULTISIG          — timelock proposer/canceller (mainnet: real multisig)
 *   TEAM_BENEFICIARY      — team vesting beneficiary
 *   PUBLIC_SALE_RECIPIENT — presale distributor
 *   LIQUIDITY_RECIPIENT   — wallet that seeds + locks the DEX pool
 *   TGE_START             — vesting start timestamp (default: block.timestamp)
 */
contract DeployMainnet is Script {
    uint256 constant TIMELOCK_DELAY = 7 days;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address gov        = vm.envOr("GOV_MULTISIG",          deployer);
        address team       = vm.envOr("TEAM_BENEFICIARY",      deployer);
        address publicSale = vm.envOr("PUBLIC_SALE_RECIPIENT", deployer);
        address liquidity  = vm.envOr("LIQUIDITY_RECIPIENT",   deployer);
        uint64  tgeStart   = uint64(vm.envOr("TGE_START",      block.timestamp));

        // The two EOA recipients must be distinct — otherwise one address receives
        // both allocations and the per-bucket balance checks below can't hold.
        // (Treasury/team/ecosystem recipients are freshly deployed contracts, so
        // they're always distinct from each other and from these.)
        require(publicSale != liquidity, "publicSale and liquidity must differ");

        vm.startBroadcast(deployerKey);

        // 1. Governance timelock — proposer/canceller = gov, executor = anyone, no admin.
        address[] memory proposers = new address[](1);
        proposers[0] = gov;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // permissionless execution once the delay elapses
        TimelockController timelock =
            new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        // 2. Treasury vesting (5yr linear) -> timelock.
        TreasuryVesting treasuryVesting = new TreasuryVesting(address(timelock), tgeStart);

        // 3. Team vesting (4yr / 1yr cliff).
        TeamVesting teamVesting = new TeamVesting(team, tgeStart);

        // 4. Token — mints + distributes. Ecosystem allocation -> timelock (governance).
        CSIG csig = new CSIG(
            address(treasuryVesting),
            address(teamVesting),
            address(timelock),
            publicSale,
            liquidity
        );

        vm.stopBroadcast();

        // ---- Post-deploy invariants: revert loudly on any misconfiguration ----
        require(csig.totalSupply() == csig.TOTAL_SUPPLY(), "supply != 1B");
        require(csig.balanceOf(address(treasuryVesting)) == csig.TREASURY_ALLOCATION(),  "treasury bal");
        require(csig.balanceOf(address(teamVesting)) == csig.TEAM_ALLOCATION(),          "team bal");
        require(csig.balanceOf(address(timelock)) == csig.ECOSYSTEM_ALLOCATION(),        "ecosystem bal");
        require(csig.balanceOf(publicSale) == csig.PUBLIC_SALE_ALLOCATION(),             "public bal");
        require(csig.balanceOf(liquidity) == csig.LIQUIDITY_ALLOCATION(),                "liquidity bal");

        require(timelock.getMinDelay() == TIMELOCK_DELAY, "timelock delay");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), gov), "proposer role");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), gov), "canceller role");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor role");

        require(treasuryVesting.duration() == treasuryVesting.VEST_DURATION(), "treasury dur");
        require(treasuryVesting.start() == tgeStart, "treasury start");
        require(teamVesting.duration() == teamVesting.VEST_DURATION(), "team dur");
        require(teamVesting.cliff() == uint256(tgeStart) + teamVesting.CLIFF_DURATION(), "team cliff");

        console2.log("=== Countersig Mainnet TGE Deployment ===");
        console2.log("Chain:           ", block.chainid);
        console2.log("Deployer:        ", deployer);
        console2.log("Gov multisig:    ", gov);
        console2.log("TGE start:       ", tgeStart);
        console2.log("---");
        console2.log("CSIG token:      ", address(csig));
        console2.log("Timelock:        ", address(timelock));
        console2.log("TreasuryVesting: ", address(treasuryVesting));
        console2.log("TeamVesting:     ", address(teamVesting));
        console2.log("Public sale:     ", publicSale);
        console2.log("Liquidity:       ", liquidity);
    }
}
