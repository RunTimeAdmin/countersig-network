// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/finance/VestingWallet.sol";

/**
 * @title TreasuryVesting
 * @notice Holds the 40% protocol treasury allocation (tokenomics v0.3 §2):
 *         5-year linear release, no cliff. The beneficiary is the governance
 *         TimelockController — vested tokens release to the timelock, and
 *         governance decides how they are deployed (subject to the timelock's
 *         mainnet 7-day delay, §9).
 *
 *         `release(token)` is permissionless; funds always go to the timelock.
 *         The schedule cannot be changed or accelerated after deployment.
 */
contract TreasuryVesting is VestingWallet {
    uint64 public constant VEST_DURATION = 5 * 365 days;

    /**
     * @param timelock       Governance TimelockController that receives releases.
     * @param startTimestamp TGE timestamp the schedule starts from.
     */
    constructor(address timelock, uint64 startTimestamp)
        VestingWallet(timelock, startTimestamp, VEST_DURATION)
    {}
}
