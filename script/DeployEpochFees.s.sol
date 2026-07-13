// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/CountersigEpochFees.sol";

/**
 * @title DeployEpochFees
 * @notice Deploys CountersigEpochFees behind a UUPS proxy and grants ORACLE_ROLE
 *         to the oracle wallet. epochFee defaults to 0, so gating stays DISABLED
 *         until governance calls setEpochFee — deploying it does not disrupt the
 *         running oracle. Point the oracle at it via FEE_REGISTRY_ADDRESS to
 *         activate coverage checks once a non-zero fee is set.
 *
 * Usage:
 *   forge script script/DeployEpochFees.s.sol --rpc-url $RPC --broadcast --verify -vvvv
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY
 *   CSIG_ADDRESS      — $CSIG token
 *   IDENTITY_ADDRESS  — CountersigIdentity proxy
 * Optional env (default to the deployer):
 *   ORACLE_ADDRESS    — granted ORACLE_ROLE (the oracle wallet)
 *   REWARD_POOL       — validator/oracle reward destination
 *   EPOCH_FEE         — initial per-epoch fee in wei (default 0 = gating disabled)
 */
contract DeployEpochFees is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address csig       = vm.envAddress("CSIG_ADDRESS");
        address identity   = vm.envAddress("IDENTITY_ADDRESS");
        address oracle     = vm.envOr("ORACLE_ADDRESS", deployer);
        address rewardPool = vm.envOr("REWARD_POOL", deployer);
        uint256 epochFee   = vm.envOr("EPOCH_FEE", uint256(0));

        vm.startBroadcast(deployerKey);

        CountersigEpochFees impl = new CountersigEpochFees();
        CountersigEpochFees fees = CountersigEpochFees(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CountersigEpochFees.initialize,
                (deployer, oracle, csig, identity, rewardPool, epochFee)
            )
        )));

        vm.stopBroadcast();

        require(address(fees.csig()) == csig, "csig not set");
        require(address(fees.identityRegistry()) == identity, "identity not set");
        require(fees.epochFee() == epochFee, "epochFee not set");
        require(fees.hasRole(fees.ORACLE_ROLE(), oracle), "oracle role not granted");

        console2.log("=== Countersig EpochFees Deployment ===");
        console2.log("Chain:           ", block.chainid);
        console2.log("EpochFees proxy: ", address(fees));
        console2.log("EpochFees impl:  ", address(impl));
        console2.log("Oracle:          ", oracle);
        console2.log("Reward pool:     ", rewardPool);
        console2.log("Epoch fee (wei): ", epochFee);
        console2.log("CSIG:            ", csig);
        console2.log("Identity:        ", identity);
    }
}
