// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CountersigPublicSale.sol";

/**
 * @title DeployPublicSale
 * @notice Deploys the immutable CountersigPublicSale. All terms are fixed at
 *         construction. After deploy, fund the sale with `SALE_HARD_CAP` $CSIG
 *         (at TGE this is done by setting the sale as the token's `publicSale`
 *         recipient, so the constructor allocation lands here directly).
 *
 * Usage:
 *   forge script script/DeployPublicSale.s.sol --rpc-url $RPC --broadcast --verify -vvvv
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY
 *   CSIG_ADDRESS       — $CSIG token
 *   PAYMENT_TOKEN      — stablecoin buyers pay with (e.g. USDC)
 *   TREASURY_ADDRESS   — receives proceeds on success
 *   SALE_PRICE         — payment-token units per 1e18 CSIG (e.g. USDC 6dp @ $0.01 = 10000)
 *   SALE_START         — unix start timestamp
 *   SALE_END           — unix end timestamp
 *   SALE_HARD_CAP      — max CSIG to sell (wei)
 *   SALE_SOFT_CAP      — min CSIG sold for success (wei)
 *   SALE_MAX_WALLET    — max CSIG per address (wei)
 */
contract DeployPublicSale is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address csig      = vm.envAddress("CSIG_ADDRESS");
        address payment   = vm.envAddress("PAYMENT_TOKEN");
        address treasury  = vm.envAddress("TREASURY_ADDRESS");
        uint256 price     = vm.envUint("SALE_PRICE");
        uint64  startTime = uint64(vm.envUint("SALE_START"));
        uint64  endTime   = uint64(vm.envUint("SALE_END"));
        uint256 hardCap   = vm.envUint("SALE_HARD_CAP");
        uint256 softCap   = vm.envUint("SALE_SOFT_CAP");
        uint256 maxWallet = vm.envUint("SALE_MAX_WALLET");

        vm.startBroadcast(deployerKey);
        CountersigPublicSale sale = new CountersigPublicSale(
            csig, payment, price, startTime, endTime, hardCap, softCap, maxWallet, treasury
        );
        vm.stopBroadcast();

        require(address(sale.csig()) == csig, "csig not set");
        require(sale.hardCap() == hardCap, "hardCap not set");
        require(sale.treasury() == treasury, "treasury not set");

        console2.log("=== Countersig Public Sale Deployment ===");
        console2.log("Chain:      ", block.chainid);
        console2.log("Sale:       ", address(sale));
        console2.log("CSIG:       ", csig);
        console2.log("Payment:    ", payment);
        console2.log("Treasury:   ", treasury);
        console2.log("Price:      ", price);
        console2.log("Hard cap:   ", hardCap);
        console2.log("Soft cap:   ", softCap);
        console2.log("Max/wallet: ", maxWallet);
        console2.log("Fund the sale with SALE_HARD_CAP CSIG before it opens.");
    }
}
