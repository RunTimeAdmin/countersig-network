// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CountersigIdentity.sol";

/**
 * @title UpgradeIdentity
 * @notice Upgrades ONLY the live Sepolia CountersigIdentity proxy to the
 *         slash-suspension implementation.
 *
 * The combined Upgrade.s.sol cannot be reused for this: Reputation and Staking
 * are already on their V2 implementations (verified on-chain — challengeWindow
 * = 1800 and unbondingPeriod = 21 days), so re-invoking their reinitializer(2)
 * initializeV2 would revert with InvalidInitialization(). This script touches
 * Identity only.
 *
 * Identity needs no initializer: slashSuspended is appended at storage slot 2
 * and defaults empty, so existing identities keep their slots (see the
 * storage-layout tests in test/CountersigIdentity.t.sol). Upgrade with empty
 * calldata and assert the ERC-1967 implementation slot after broadcast.
 *
 * Usage — Sepolia:
 *   forge script script/UpgradeIdentity.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY — must hold UPGRADER_ROLE on the Identity proxy
 */
contract UpgradeIdentity is Script {
    address constant IDENTITY_PROXY = 0xD738A4cBe525d214f86059A8328786f072D6fbe1;

    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        CountersigIdentity identity = CountersigIdentity(IDENTITY_PROXY);

        vm.startBroadcast(deployerKey);
        CountersigIdentity identityImpl = new CountersigIdentity();
        identity.upgradeToAndCall(address(identityImpl), "");
        vm.stopBroadcast();

        // Post-upgrade sanity: fail loudly if the implementation didn't land.
        require(
            address(uint160(uint256(vm.load(IDENTITY_PROXY, IMPL_SLOT)))) == address(identityImpl),
            "identity impl not upgraded"
        );

        console2.log("=== Countersig Identity Upgrade (Sepolia) ===");
        console2.log("Identity proxy:      ", IDENTITY_PROXY);
        console2.log("Identity impl (new): ", address(identityImpl));
    }
}
