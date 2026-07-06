// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/CSIG.sol";

contract CSIGTest is Test {
    CSIG token;

    address treasury   = makeAddr("treasury");
    address team       = makeAddr("team");
    address ecosystem  = makeAddr("ecosystem");
    address publicSale = makeAddr("publicSale");
    address liquidity  = makeAddr("liquidity");

    function setUp() public {
        token = new CSIG(treasury, team, ecosystem, publicSale, liquidity);
    }

    // -------------------------------------------------------------------------
    // Metadata & supply
    // -------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Countersig");
        assertEq(token.symbol(), "CSIG");
        assertEq(token.decimals(), 18);
    }

    function test_totalSupply_isOneBillion() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    // -------------------------------------------------------------------------
    // Distribution
    // -------------------------------------------------------------------------

    function test_allocationsDistributed() public view {
        assertEq(token.balanceOf(treasury),   400_000_000e18);
        assertEq(token.balanceOf(team),       200_000_000e18);
        assertEq(token.balanceOf(ecosystem),  150_000_000e18);
        assertEq(token.balanceOf(publicSale), 150_000_000e18);
        assertEq(token.balanceOf(liquidity),  100_000_000e18);
    }

    function test_balancesSumToTotalSupply() public view {
        uint256 sum = token.balanceOf(treasury) + token.balanceOf(team)
            + token.balanceOf(ecosystem) + token.balanceOf(publicSale)
            + token.balanceOf(liquidity);
        assertEq(sum, token.totalSupply());
    }

    function test_allocationConstantsSumToTotalSupply() public view {
        assertEq(
            token.TREASURY_ALLOCATION() + token.TEAM_ALLOCATION() + token.ECOSYSTEM_ALLOCATION()
                + token.PUBLIC_SALE_ALLOCATION() + token.LIQUIDITY_ALLOCATION(),
            token.TOTAL_SUPPLY()
        );
    }

    // -------------------------------------------------------------------------
    // Constructor guards
    // -------------------------------------------------------------------------

    function test_constructor_reverts_zeroTreasury() public {
        vm.expectRevert(CSIG.ZeroAddress.selector);
        new CSIG(address(0), team, ecosystem, publicSale, liquidity);
    }

    function test_constructor_reverts_zeroLiquidity() public {
        vm.expectRevert(CSIG.ZeroAddress.selector);
        new CSIG(treasury, team, ecosystem, publicSale, address(0));
    }

    // -------------------------------------------------------------------------
    // Transfers & burn-by-transfer
    // -------------------------------------------------------------------------

    function test_transfer_works() public {
        vm.prank(treasury);
        assertTrue(token.transfer(team, 1e18));
        assertEq(token.balanceOf(team), 200_000_000e18 + 1e18);
        assertEq(token.balanceOf(treasury), 400_000_000e18 - 1e18);
    }

    function test_burnByTransferToDead() public {
        vm.prank(publicSale);
        assertTrue(token.transfer(address(0xdead), 50_000_000e18)); // e.g. unsold public tokens

        assertEq(token.balanceOf(address(0xdead)), 50_000_000e18);
        assertEq(token.balanceOf(publicSale), 100_000_000e18);
        // Supply is unchanged; the tokens are simply unrecoverable at 0xdead.
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
