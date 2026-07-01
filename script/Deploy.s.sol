// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/CountersigIdentity.sol";
import "../src/CountersigReputation.sol";
import "../src/CountersigStaking.sol";
import "../src/CSIGToken.sol";

/**
 * @title Deploy
 * @notice Deploys all Countersig Network contracts behind UUPS proxies, wires roles,
 *         and writes the deployed addresses to deployments/{chainId}.json.
 *
 * Usage — Sepolia testnet:
 *   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY   — deployer key (used for broadcast)
 *
 * Optional env vars:
 *   ORACLE_ADDRESS         — address that may call updateReputation() on the oracle network
 *                            defaults to deployer
 *   COMMITTEE_ADDRESS      — initial SLASHING_COMMITTEE_ROLE holder (testnet 3-of-5 multisig)
 *                            defaults to deployer
 *   MINIMUM_STAKE          — minimum $CSIG stake in wei (default: 1,000 CSIG)
 *   CHALLENGE_PERIOD       — slash challenge window in seconds (default: 7 days)
 *   SCORE_CHALLENGE_WINDOW — reputation-score challenge window in seconds (default: 6 hours)
 *   UNBONDING_PERIOD       — seconds a queued withdrawal is still slashable before claim (default: 21 days)
 */
contract Deploy is Script {
    uint256 constant DEFAULT_MINIMUM_STAKE = 1_000e18;
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 7 days;
    uint256 constant DEFAULT_SCORE_CHALLENGE_WINDOW = 6 hours;
    uint256 constant DEFAULT_UNBONDING_PERIOD = 21 days;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address oracle        = vm.envOr("ORACLE_ADDRESS",        deployer);
        address committee     = vm.envOr("COMMITTEE_ADDRESS",     deployer);
        uint256 minStake      = vm.envOr("MINIMUM_STAKE",         DEFAULT_MINIMUM_STAKE);
        uint256 period        = vm.envOr("CHALLENGE_PERIOD",      DEFAULT_CHALLENGE_PERIOD);
        uint256 scoreWindow   = vm.envOr("SCORE_CHALLENGE_WINDOW", DEFAULT_SCORE_CHALLENGE_WINDOW);
        uint256 unbondPeriod  = vm.envOr("UNBONDING_PERIOD",      DEFAULT_UNBONDING_PERIOD);

        vm.startBroadcast(deployerKey);

        // 1. $CSIG testnet token
        CSIGToken csig = new CSIGToken(deployer);

        // 2. Identity — stakingCore wired after staking is deployed
        CountersigIdentity identityImpl = new CountersigIdentity();
        CountersigIdentity identity = CountersigIdentity(address(new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(CountersigIdentity.initialize, (deployer, address(0)))
        )));

        // 3. Reputation — oracle, stakingCore, and committee wired after all are known
        CountersigReputation repImpl = new CountersigReputation();
        CountersigReputation reputation = CountersigReputation(address(new ERC1967Proxy(
            address(repImpl),
            abi.encodeCall(CountersigReputation.initialize, (deployer, address(0), address(0), address(0), scoreWindow))
        )));

        // 4. Staking — now we have identity + rep + token addresses
        CountersigStaking stakingImpl = new CountersigStaking();
        CountersigStaking staking = CountersigStaking(address(new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeCall(CountersigStaking.initialize, (
                deployer,
                address(identity),
                address(reputation),
                address(csig),
                minStake,
                period,
                unbondPeriod
            ))
        )));

        // 5. Wire cross-contract roles
        identity.grantRole(identity.STAKING_CORE_ROLE(), address(staking));
        reputation.grantRole(reputation.STAKING_CORE_ROLE(), address(staking));
        reputation.grantRole(reputation.ORACLE_ROLE(), oracle);
        reputation.grantRole(reputation.SLASHING_COMMITTEE_ROLE(), committee);
        staking.grantRole(staking.SLASHING_COMMITTEE_ROLE(), committee);

        vm.stopBroadcast();

        // Log the deployed addresses to stdout
        console2.log("=== Countersig Network Deployment ===");
        console2.log("Chain:           ", block.chainid);
        console2.log("Deployer:        ", deployer);
        console2.log("---");
        console2.log("CSIG Token:      ", address(csig));
        console2.log("Identity proxy:  ", address(identity));
        console2.log("Reputation proxy:", address(reputation));
        console2.log("Staking proxy:   ", address(staking));
        console2.log("---");
        console2.log("Identity impl:   ", address(identityImpl));
        console2.log("Reputation impl: ", address(repImpl));
        console2.log("Staking impl:    ", address(stakingImpl));
        console2.log("---");
        console2.log("Oracle:          ", oracle);
        console2.log("Committee:       ", committee);
        console2.log("Min stake (wei): ", minStake);
        console2.log("Challenge period:", period);
        console2.log("Score chal. win.:", scoreWindow);
        console2.log("Unbonding period:", unbondPeriod);

        // Write addresses to deployments/{chainId}.json for SDK config
        _writeAddresses(deployer, address(csig), address(identity), address(reputation), address(staking));
    }

    function _writeAddresses(
        address deployer,
        address csig,
        address identity,
        address reputation,
        address staking
    ) internal {
        string memory key = "out";
        vm.serializeUint(key,    "chainId",    block.chainid);
        vm.serializeAddress(key, "deployer",   deployer);
        vm.serializeAddress(key, "csigToken",  csig);
        vm.serializeAddress(key, "identity",   identity);
        vm.serializeAddress(key, "reputation", reputation);
        string memory json = vm.serializeAddress(key, "staking", staking);

        vm.createDir("deployments", true);
        vm.writeFile(
            string.concat("deployments/", vm.toString(block.chainid), ".json"),
            json
        );
    }
}
