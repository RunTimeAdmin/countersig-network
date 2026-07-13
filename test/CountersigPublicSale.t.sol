// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/CountersigPublicSale.sol";
import "../src/CSIGToken.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract CountersigPublicSaleTest is Test {
    CountersigPublicSale sale;
    CSIGToken csig;
    MockUSDC usdc;

    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    // $0.01 per CSIG, USDC (6 decimals): 0.01 * 1e6 = 10_000 payment-wei per 1e18 CSIG.
    uint256 constant PRICE = 10_000;
    uint256 constant HARD_CAP = 1_000_000e18;
    uint256 constant SOFT_CAP = 100_000e18;
    uint256 constant MAX_WALLET = 500_000e18;

    uint64 start;
    uint64 end;

    function setUp() public {
        csig = new CSIGToken(address(this));
        usdc = new MockUSDC();

        start = uint64(block.timestamp + 1 hours);
        end = uint64(block.timestamp + 1 days);

        sale = new CountersigPublicSale(
            address(csig), address(usdc), PRICE, start, end, HARD_CAP, SOFT_CAP, MAX_WALLET, treasury
        );

        // Fund the sale with the full hard-cap allocation.
        csig.mint(address(sale), HARD_CAP);

        // Fund buyers with USDC and approve the sale.
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice); usdc.approve(address(sale), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(sale), type(uint256).max);
    }

    function _buy(address who, uint256 amount) internal {
        vm.warp(start);
        vm.prank(who);
        sale.buy(amount);
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    function test_construction_reverts_zeroAddress() public {
        vm.expectRevert(CountersigPublicSale.ZeroAddress.selector);
        new CountersigPublicSale(address(0), address(usdc), PRICE, start, end, HARD_CAP, SOFT_CAP, MAX_WALLET, treasury);
    }

    function test_construction_reverts_softGtHard() public {
        vm.expectRevert(CountersigPublicSale.BadParams.selector);
        new CountersigPublicSale(address(csig), address(usdc), PRICE, start, end, HARD_CAP, HARD_CAP + 1, MAX_WALLET, treasury);
    }

    function test_construction_reverts_endInPast() public {
        vm.expectRevert(CountersigPublicSale.BadParams.selector);
        new CountersigPublicSale(address(csig), address(usdc), PRICE, start, uint64(block.timestamp), HARD_CAP, SOFT_CAP, MAX_WALLET, treasury);
    }

    // -------------------------------------------------------------------------
    // Pricing
    // -------------------------------------------------------------------------

    function test_cost() public view {
        assertEq(sale.cost(1e18), 10_000);          // 1 CSIG -> $0.01
        assertEq(sale.cost(1000e18), 10_000_000);   // 1000 CSIG -> $10
    }

    function test_isFunded() public view {
        assertTrue(sale.isFunded());
    }

    // -------------------------------------------------------------------------
    // Buying
    // -------------------------------------------------------------------------

    function test_buy_success() public {
        _buy(alice, 1000e18);
        assertEq(sale.purchased(alice), 1000e18);
        assertEq(sale.paid(alice), 10_000_000);
        assertEq(sale.tokensSold(), 1000e18);
        assertEq(usdc.balanceOf(address(sale)), 10_000_000);
    }

    function test_buy_beforeStart_reverts() public {
        vm.expectRevert(CountersigPublicSale.NotActive.selector);
        vm.prank(alice);
        sale.buy(1000e18);
    }

    function test_buy_afterEnd_reverts() public {
        vm.warp(end + 1);
        vm.expectRevert(CountersigPublicSale.NotActive.selector);
        vm.prank(alice);
        sale.buy(1000e18);
    }

    function test_buy_notFunded_reverts() public {
        CountersigPublicSale unfunded = new CountersigPublicSale(
            address(csig), address(usdc), PRICE, start, end, HARD_CAP, SOFT_CAP, MAX_WALLET, treasury
        );
        vm.warp(start);
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.SaleNotFunded.selector);
        unfunded.buy(1000e18);
    }

    function test_buy_walletCapExceeded_reverts() public {
        vm.warp(start);
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.WalletCapExceeded.selector);
        sale.buy(MAX_WALLET + 1);
    }

    function test_buy_hardCapExceeded_reverts() public {
        // Deploy a sale whose hard cap is below the wallet cap so one buy can exceed it.
        CountersigPublicSale small = new CountersigPublicSale(
            address(csig), address(usdc), PRICE, start, end, 1000e18, 100e18, 10_000e18, treasury
        );
        csig.mint(address(small), 1000e18);
        vm.warp(start);
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.HardCapExceeded.selector);
        small.buy(1001e18);
    }

    // -------------------------------------------------------------------------
    // Success path
    // -------------------------------------------------------------------------

    function test_success_finalize_claim_burn() public {
        _buy(alice, 200_000e18); // >= soft cap
        vm.warp(end + 1);

        sale.finalize();
        assertTrue(sale.succeeded());

        // Proceeds to treasury.
        assertEq(usdc.balanceOf(treasury), sale.cost(200_000e18));
        // Unsold burned: hardCap funded - sold.
        assertEq(csig.balanceOf(address(0xdead)), HARD_CAP - 200_000e18);
        // Sold amount retained for claims.
        assertEq(csig.balanceOf(address(sale)), 200_000e18);

        // Claim.
        vm.prank(alice);
        sale.claim();
        assertEq(csig.balanceOf(alice), 200_000e18);
        assertEq(csig.balanceOf(address(sale)), 0);

        // Double claim / wrong path reverts.
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.AlreadyClaimed.selector);
        sale.claim();

        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.NotFailed.selector);
        sale.refund();
    }

    function test_finalize_early_onHardCap() public {
        CountersigPublicSale small = new CountersigPublicSale(
            address(csig), address(usdc), PRICE, start, end, 1000e18, 100e18, 10_000e18, treasury
        );
        csig.mint(address(small), 1000e18);
        vm.warp(start);
        vm.prank(alice);
        usdc.approve(address(small), type(uint256).max);
        vm.prank(alice);
        small.buy(1000e18); // fills hard cap

        // Before end but hard cap reached -> finalize allowed.
        small.finalize();
        assertTrue(small.succeeded());
    }

    // -------------------------------------------------------------------------
    // Failure path
    // -------------------------------------------------------------------------

    function test_failure_refund_and_recover() public {
        _buy(alice, 50_000e18); // < soft cap
        uint256 aliceCost = sale.cost(50_000e18);
        vm.warp(end + 1);

        sale.finalize();
        assertFalse(sale.succeeded());

        // Whole allocation returned to treasury, nothing burned.
        assertEq(csig.balanceOf(treasury), HARD_CAP);
        assertEq(csig.balanceOf(address(0xdead)), 0);

        // Refund.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        sale.refund();
        assertEq(usdc.balanceOf(alice), before + aliceCost);

        // Double refund / wrong path reverts.
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.AlreadyRefunded.selector);
        sale.refund();

        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.NotSucceeded.selector);
        sale.claim();
    }

    // -------------------------------------------------------------------------
    // Finalize / claim guards
    // -------------------------------------------------------------------------

    function test_finalize_beforeEnd_reverts() public {
        _buy(alice, 200_000e18);
        vm.expectRevert(CountersigPublicSale.NotEnded.selector);
        sale.finalize();
    }

    function test_finalize_twice_reverts() public {
        _buy(alice, 200_000e18);
        vm.warp(end + 1);
        sale.finalize();
        vm.expectRevert(CountersigPublicSale.AlreadyFinalized.selector);
        sale.finalize();
    }

    function test_claim_beforeFinalize_reverts() public {
        _buy(alice, 200_000e18);
        vm.prank(alice);
        vm.expectRevert(CountersigPublicSale.NotFinalized.selector);
        sale.claim();
    }
}
