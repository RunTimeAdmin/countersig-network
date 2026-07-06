// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/**
 * @title TeamVesting
 * @notice Holds the 20% team & contributors allocation (tokenomics v0.3 §2):
 *         4-year linear vest with a 1-year cliff. Nothing is releasable before
 *         the cliff; at the cliff 25% becomes releasable, then it vests linearly
 *         to 100% at 4 years.
 *
 *         `release(token)` is permissionless — anyone can trigger it, and vested
 *         tokens always go to `beneficiary` (set once at construction). There is
 *         no way to change the beneficiary, accelerate the schedule, or claw the
 *         tokens back: contract-enforced, matching §2 "smart contract enforced,
 *         not verbal … no unlocked founder tokens."
 */
contract TeamVesting is VestingWalletCliff {
    uint64 public constant VEST_DURATION = 4 * 365 days;
    uint64 public constant CLIFF_DURATION = 365 days;

    /**
     * @param beneficiary    Team address that receives vested tokens.
     * @param startTimestamp TGE timestamp the schedule starts from.
     */
    constructor(address beneficiary, uint64 startTimestamp)
        VestingWallet(beneficiary, startTimestamp, VEST_DURATION)
        VestingWalletCliff(CLIFF_DURATION)
    {}
}
