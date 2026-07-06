// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../src/CountersigIdentity.sol";
import "../src/CountersigReputation.sol";
import "../src/CountersigStaking.sol";

/**
 * @title Upgrade
 * @notice Upgrades the live Sepolia CountersigIdentity, CountersigReputation, and
 *         CountersigStaking proxies to their current implementations.
 *
 * Reputation and Staking use upgradeToAndCall so each new implementation and its
 * V2 config land in a single transaction. A bare upgrade would leave
 * challengeWindow and unbondingPeriod at 0, which silently means
 * instantly-finalizable score proposals (rejection impossible) and
 * instantly-claimable withdrawals.
 *
 * CountersigIdentity is upgraded to enforce the slash-suspension lock: its new
 * `slashSuspended` mapping is appended (slot 2), so no initializer is needed —
 * the map defaults empty and existing identities keep their slots (see the
 * storage-layout tests in test/CountersigIdentity.t.sol). It is upgraded with
 * empty calldata.
 *
 * CSIGToken's faucet cooldown is deliberately NOT deployed on testnet: the token
 * has no proxy, so shipping it means a new token address that orphans every
 * existing balance and the staking contract's token reference. It ships with the
 * fresh mainnet deployment instead.
 *
 * Usage — Sepolia:
 *   forge script script/Upgrade.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — must hold UPGRADER_ROLE on all three proxies, and
 *                            DEFAULT_ADMIN_ROLE on Reputation and Staking (for their initializeV2)
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
    address constant IDENTITY_PROXY   = 0xD738A4cBe525d214f86059A8328786f072D6fbe1;
    address constant REPUTATION_PROXY = 0x0613C561C5003D7948Ea09dE2C1895965A5c3F27;
    address constant STAKING_PROXY    = 0x60347640d46B55E7dafFA8F385bc55eE2D77ee85;

    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 constant DEFAULT_SCORE_CHALLENGE_WINDOW = 30 minutes;
    uint256 constant DEFAULT_UNBONDING_PERIOD = 21 days;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address committee   = vm.envOr("COMMITTEE_ADDRESS",      deployer);
        uint256 scoreWindow = vm.envOr("SCORE_CHALLENGE_WINDOW", DEFAULT_SCORE_CHALLENGE_WINDOW);
        uint256 unbond      = vm.envOr("UNBONDING_PERIOD",       DEFAULT_UNBONDING_PERIOD);

        CountersigIdentity identity = CountersigIdentity(IDENTITY_PROXY);
        CountersigReputation reputation = CountersigReputation(REPUTATION_PROXY);
        CountersigStaking staking = CountersigStaking(STAKING_PROXY);

        vm.startBroadcast(deployerKey);

        CountersigIdentity identityImpl = new CountersigIdentity();
        CountersigReputation repImpl = new CountersigReputation();
        CountersigStaking stakingImpl = new CountersigStaking();

        // Identity: no new config to seed (slashSuspended defaults empty), so
        // upgrade with empty calldata.
        identity.upgradeToAndCall(address(identityImpl), "");
        reputation.upgradeToAndCall(
            address(repImpl),
            abi.encodeCall(CountersigReputation.initializeV2, (committee, scoreWindow))
        );
        staking.upgradeToAndCall(
            address(stakingImpl),
            abi.encodeCall(CountersigStaking.initializeV2, (unbond))
        );

        vm.stopBroadcast();

        // Post-upgrade sanity: fail loudly if an implementation or V2 config didn't land.
        require(
            address(uint160(uint256(vm.load(IDENTITY_PROXY, IMPL_SLOT)))) == address(identityImpl),
            "identity impl not upgraded"
        );
        require(reputation.challengeWindow() == scoreWindow, "challengeWindow not set");
        require(staking.unbondingPeriod() == unbond, "unbondingPeriod not set");
        require(reputation.hasRole(reputation.SLASHING_COMMITTEE_ROLE(), committee), "committee role not granted");

        console2.log("=== Countersig Upgrade (Sepolia) ===");
        console2.log("Deployer:            ", deployer);
        console2.log("Identity impl (new): ", address(identityImpl));
        console2.log("Reputation impl (new):", address(repImpl));
        console2.log("Staking impl (new):   ", address(stakingImpl));
        console2.log("Committee:           ", committee);
        console2.log("Score chal. window:  ", scoreWindow);
        console2.log("Unbonding period:    ", unbond);
    }
}
