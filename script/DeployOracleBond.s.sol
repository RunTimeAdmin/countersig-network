// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/CountersigOracleBond.sol";

/**
 * @title DeployOracleBond
 * @notice Deploys CountersigOracleBond behind a UUPS proxy (tokenomics §8 oracle
 *         operator performance bonds). Governance later admits operators and grants
 *         them ORACLE_ROLE on CountersigReputation / CountersigEpochFees off
 *         isActiveOperator().
 *
 * Usage:
 *   forge script script/DeployOracleBond.s.sol --rpc-url $RPC --broadcast --verify -vvvv
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY
 *   CSIG_ADDRESS          — $CSIG token
 * Optional env (default to the deployer):
 *   SLASHER_ADDRESS       — granted SLASHER_ROLE (governance/committee)
 *   SLASH_BENEFICIARY     — destination for slashed bonds (defaults to deployer)
 *   ORACLE_BOND_AMOUNT    — minimum bond in wei (default 1,000 CSIG)
 *   ORACLE_UNBONDING      — unbonding cooldown seconds (default 7 days)
 */
contract DeployOracleBond is Script {
    uint256 constant DEFAULT_BOND = 1_000e18;
    uint256 constant DEFAULT_UNBONDING = 7 days;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address csig        = vm.envAddress("CSIG_ADDRESS");
        address slasher     = vm.envOr("SLASHER_ADDRESS", deployer);
        address beneficiary = vm.envOr("SLASH_BENEFICIARY", deployer);
        uint256 bondAmount  = vm.envOr("ORACLE_BOND_AMOUNT", DEFAULT_BOND);
        uint256 unbonding   = vm.envOr("ORACLE_UNBONDING", DEFAULT_UNBONDING);

        vm.startBroadcast(deployerKey);

        CountersigOracleBond impl = new CountersigOracleBond();
        CountersigOracleBond bond = CountersigOracleBond(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CountersigOracleBond.initialize,
                (deployer, slasher, csig, bondAmount, unbonding, beneficiary)
            )
        )));

        vm.stopBroadcast();

        require(address(bond.csig()) == csig, "csig not set");
        require(bond.bondAmount() == bondAmount, "bondAmount not set");
        require(bond.hasRole(bond.SLASHER_ROLE(), slasher), "slasher role not granted");

        console2.log("=== Countersig OracleBond Deployment ===");
        console2.log("Chain:             ", block.chainid);
        console2.log("OracleBond proxy:  ", address(bond));
        console2.log("OracleBond impl:   ", address(impl));
        console2.log("Slasher:           ", slasher);
        console2.log("Slash beneficiary: ", beneficiary);
        console2.log("Bond amount (wei): ", bondAmount);
        console2.log("Unbonding (s):     ", unbonding);
        console2.log("CSIG:              ", csig);
    }
}
