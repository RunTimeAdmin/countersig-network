// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CSIG
 * @notice Mainnet $CSIG — the fixed-supply work token of the Countersig Network.
 *
 *         1,000,000,000 CSIG is minted once, in this constructor, and distributed
 *         to the five allocation buckets from tokenomics v0.3 §2. There is:
 *           - no mint function (supply can never grow — §10 "no mint function"),
 *           - no owner / admin (no privileged party post-deploy — §2),
 *           - no upgrade path (plain, non-proxy contract; §9 privileges live in the
 *             protocol contracts, not the token).
 *
 *         This is distinct from the testnet CSIGToken (which is owner-mintable and
 *         has a faucet). That contract must never be deployed to mainnet.
 *
 *         The allocation amounts are hardcoded constants, not constructor inputs:
 *         the split is fixed by the tokenomics doc, so only the recipient addresses
 *         are set at deploy. At TGE those recipients are the treasury timelock, the
 *         team/ecosystem vesting contracts, the public-sale distributor, and the
 *         liquidity wallet — none of which the token needs to know about.
 *
 *         Burns (slashing, unsold public-sale tokens, fee burns) are performed by
 *         other contracts transferring to address(0xdead), matching CountersigStaking.
 *         The token therefore exposes no burn() surface of its own.
 */
contract CSIG is ERC20 {
    /// Immutable total supply: 1 billion CSIG (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Allocation constants (tokenomics v0.3 §2). Sum == TOTAL_SUPPLY, checked below.
    uint256 public constant TREASURY_ALLOCATION    = 400_000_000e18; // 40% — treasury timelock
    uint256 public constant TEAM_ALLOCATION        = 200_000_000e18; // 20% — team vesting
    uint256 public constant ECOSYSTEM_ALLOCATION   = 150_000_000e18; // 15% — ecosystem/partners
    uint256 public constant PUBLIC_SALE_ALLOCATION = 150_000_000e18; // 15% — public sale / TGE
    uint256 public constant LIQUIDITY_ALLOCATION   = 100_000_000e18; // 10% — DEX liquidity

    error ZeroAddress();

    /**
     * @param treasury    Receives 40%. Should be the treasury TimelockController.
     * @param team        Receives 20%. Should be the team vesting contract (4yr/1yr cliff).
     * @param ecosystem   Receives 15%. Should be the ecosystem/partners distributor.
     * @param publicSale  Receives 15%. Public-sale distributor; unsold is burned to 0xdead.
     * @param liquidity   Receives 10%. Liquidity wallet that seeds and locks the DEX pool.
     */
    constructor(
        address treasury,
        address team,
        address ecosystem,
        address publicSale,
        address liquidity
    ) ERC20("Countersig", "CSIG") {
        if (
            treasury == address(0) || team == address(0) || ecosystem == address(0)
                || publicSale == address(0) || liquidity == address(0)
        ) {
            revert ZeroAddress();
        }

        _mint(treasury, TREASURY_ALLOCATION);
        _mint(team, TEAM_ALLOCATION);
        _mint(ecosystem, ECOSYSTEM_ALLOCATION);
        _mint(publicSale, PUBLIC_SALE_ALLOCATION);
        _mint(liquidity, LIQUIDITY_ALLOCATION);

        // The five allocations must sum to exactly TOTAL_SUPPLY. This is a
        // deploy-time invariant, not runtime logic — if the constants above are
        // ever edited so they no longer sum to 1B, deployment reverts here.
        assert(totalSupply() == TOTAL_SUPPLY);
    }
}
