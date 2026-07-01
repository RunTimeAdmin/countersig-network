// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../src/CountersigReputation.sol";
import "../src/CountersigStaking.sol";

/**
 * @title Upgrade
 * @notice Upgrades the live Sepolia CountersigReputation and CountersigStaking
 *         proxies to the optimistic-scoring / unbonding implementations.
 *
 * Uses upgradeToAndCall so each new implementation and its V2 config land in a
 * single transaction. A bare upgrade would leave challengeWindow and
 * unbondingPeriod at 0, which silently means instantly-finalizable score
 * proposals (rejection impossible) and instantly-claimable withdrawals.
 *
 * CountersigIdentity is not upgraded (unchanged since deployment). CSIGToken's
 * faucet cooldown is deliberately NOT deployed on testnet: the token has no
 * proxy, so shipping it means a new token address that orphans every existing
 * balance and the staking contract's token reference. It ships with the fresh
 * mainnet deployment instead.
 *
 * Usage — Sepolia:
 *   forge script script/Upgrade.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — must hold UPGRADER_ROLE and DEFAULT_ADMIN_ROLE on both proxies
 *
 * Optional env vars:
 *   COMMITTEE_ADDRESS      — SLASHING_COMMITTEE_ROLE grantee on Reputation (default: deployer)
 *   SCORE_CHALLENGE_WINDOW — seconds a proposed score is challengeable (default: 30 minutes,
 *                            deliberately shorter than the 1h testnet epoch so every epoch
 *                            cleanly finalizes the previous epoch's proposals)
 *   UNBONDING_PERIOD       — seconds a queued withdrawal is still slashable (default: 21 days)
 */
contract Upgrade is Script {
    // Sepolia proxies — must match deployments/11155111.json.
    address constant REPUTATION_PROXY = 0x0613C561C5003D7948Ea09dE2C1895965A5c3F27;
    address constant STAKING_PROXY    = 0x60347640d46B55E7dafFA8F385bc55eE2D77ee85;

    uint256 constant DEFAULT_SCORE_CHALLENGE_WINDOW = 30 minutes;
    uint256 constant DEFAULT_UNBONDING_PERIOD = 21 days;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address committee   = vm.envOr("COMMITTEE_ADDRESS",      deployer);
        uint256 scoreWindow = vm.envOr("SCORE_CHALLENGE_WINDOW", DEFAULT_SCORE_CHALLENGE_WINDOW);
        uint256 unbond      = vm.envOr("UNBONDING_PERIOD",       DEFAULT_UNBONDING_PERIOD);

        CountersigReputation reputation = CountersigReputation(REPUTATION_PROXY);
        CountersigStaking staking = CountersigStaking(STAKING_PROXY);

        vm.startBroadcast(deployerKey);

        CountersigReputation repImpl = new CountersigReputation();
        CountersigStaking stakingImpl = new CountersigStaking();

        reputation.upgradeToAndCall(
            address(repImpl),
            abi.encodeCall(CountersigReputation.initializeV2, (committee, scoreWindow))
        );
        staking.upgradeToAndCall(
            address(stakingImpl),
            abi.encodeCall(CountersigStaking.initializeV2, (unbond))
        );

        vm.stopBroadcast();

        // Post-upgrade sanity: fail loudly if the V2 config didn't land.
        require(reputation.challengeWindow() == scoreWindow, "challengeWindow not set");
        require(staking.unbondingPeriod() == unbond, "unbondingPeriod not set");
        require(reputation.hasRole(reputation.SLASHING_COMMITTEE_ROLE(), committee), "committee role not granted");

        console2.log("=== Countersig Upgrade (Sepolia) ===");
        console2.log("Deployer:            ", deployer);
        console2.log("Reputation impl (new):", address(repImpl));
        console2.log("Staking impl (new):   ", address(stakingImpl));
        console2.log("Committee:           ", committee);
        console2.log("Score chal. window:  ", scoreWindow);
        console2.log("Unbonding period:    ", unbond);
    }
}
