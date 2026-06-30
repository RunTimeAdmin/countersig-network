# $CSIG Token Economics
## Countersig Network — Design Specification v0.3

> **Status:** Pre-TGE design document. Supply and distribution are locked. Fee parameters, minimum stake, and burn activation threshold are tunable based on Sepolia testnet data. This document is the authoritative reference for any due diligence conversation.

---

## 1. Token Overview

$CSIG is the **work token** of the Countersig Network. Operators must stake $CSIG to participate in the protocol, and they lose their stake if they behave maliciously. The token is not a governance token, not a dividend claim, and not an investment vehicle. Its value derives exclusively from the utility of operating and consuming the Countersig identity and reputation network.

**The single sentence that defines $CSIG:** *You need $CSIG to register an AI agent identity on the Countersig Network. Without it, you cannot participate.*

---

## 2. Fixed Supply and Distribution

**Total Supply: 1,000,000,000 $CSIG (1 billion). Fixed. No inflation. Ever.**

| Allocation | % | Amount | Mechanism |
|:---|:---|:---|:---|
| Protocol Treasury | 40% | 400M | On-chain `TimelockController` + governance. 5-year linear release. No single-party control. |
| Team & Contributors | 20% | 200M | On-chain vesting contract. 4-year vest, 1-year cliff. Smart contract enforced, not verbal. |
| Ecosystem & Partners | 15% | 150M | Milestone-based release. Oracle operators, CounterAudit integration, AI framework partners. Disbursed by governance vote against defined deliverables. |
| Public Sale / TGE | 15% | 150M | Sold as access to protocol utility. Purchasers receive the right to stake and use the network. Not marketed as an investment. Any unsold tokens from the public sale will be permanently burned, not returned to the treasury. |
| Liquidity Provision | 10% | 100M | See Section 3. |

All vesting contracts are deployed on-chain at TGE. Team and treasury allocations are not accessible until the vesting schedule permits, regardless of team decisions. There are no side agreements, no unlocked founder tokens, and no multisig overrides on vesting.

---

## 3. Liquidity Provision — Mechanism Specified

The 10% liquidity allocation (100M $CSIG) is handled as follows:

At TGE, the protocol pairs 100M $CSIG with an equivalent USD value of stablecoins (USDC) from the public sale proceeds and deposits both into a Uniswap v3 concentrated liquidity pool. The resulting LP tokens are **locked in a Unicrypt time-lock contract for a minimum of 2 years from the TGE date.** The lock transaction hash and Unicrypt lock ID are published in the deployment announcement and linked from `countersig.network` before trading begins.

"Locked" in this document means: LP tokens are held by a Unicrypt smart contract that enforces a time-based release. The team has no ability to withdraw liquidity before the lock expires. This is verifiable on-chain by any party.

After the 2-year lock expires, the protocol has three options, decided by governance vote before expiry:
1. Re-lock for another 2 years
2. Transfer LP tokens to the treasury timelock for managed liquidity
3. Burn the LP tokens for permanent, irremovable liquidity

Option 3 is the strongest trust signal and the default recommendation if the protocol is generating sufficient fee revenue to sustain liquidity organically.

---

## 4. Token Utility at TGE — The Howey Anchor

For $CSIG to avoid classification as a digital security under the SEC/CFTC March 2026 joint taxonomy, purchasers must be acquiring a tool for a specific, defined use — not an expectation of profit from the efforts of others.

**What $CSIG enables at TGE, and only $CSIG:**
1. **Identity Staking:** An operator must hold and stake a minimum $CSIG amount to call `registerAgent()` on `CountersigIdentity`. Without a stake, the transaction reverts. There is no alternative payment method.
2. **Oracle Epoch Prioritization:** To have an agent's reputation updated by the oracle network during the daily epoch, operators or querying applications must pay a micro-fee in $CSIG. Agents without fee coverage fall out of the active scoring epoch. The on-chain `meetsThreshold()` view function remains free; the fee gates *inclusion in the oracle's scoring run*, not the read itself. **This mechanism is to be built and deployed before mainnet.** The payment gate will be implemented in the oracle service and, optionally, enforced via a dedicated on-chain fee registry contract.

Identity staking (point 1) is live and functional on Sepolia today. Oracle epoch prioritization (point 2) is the designed mainnet utility; it is not yet active on testnet.

**What $CSIG does not do at TGE:** It does not entitle the holder to protocol revenue, dividends, governance votes, or any share of the team's future efforts. Token-based voting rights, if introduced, will be a separate governance module added post-mainnet.

---

## 5. Fee Mechanics and USD Decoupling

All fees are denominated in **USD terms** and settled in $CSIG at the oracle-reported spot price. This prevents the deflationary death spiral where rising $CSIG prices make the network prohibitively expensive.

**Implementation:** The minimum stake in `CountersigStaking` is adjustable via `setMinimumStake(uint256)`, callable only by `DEFAULT_ADMIN_ROLE` (the governance timelock at mainnet). The oracle epoch fee ($CSIG amount required for epoch inclusion) will be maintained by the oracle operator set, either in the oracle service configuration or via a dedicated on-chain fee registry contract to be deployed before mainnet. Both values are updated to maintain target USD costs as $CSIG price changes.

**Target USD costs (tunable, not hardcoded):**
- Reputation query: ~$0.001 USD equivalent in $CSIG
- Agent registration stake: ~$10 USD equivalent in $CSIG (minimum)

These targets will be calibrated based on Sepolia testnet data before mainnet launch.

---

## 6. Fee Routing — Three-Stage Model

Fee routing evolves through three governance-controlled stages. The current stage is a protocol parameter, not a hardcoded value.

### Stage 1: Bootstrap (Default at Mainnet Launch)
**Routing:** 100% of query fees → validator/oracle reward pool.

No burn. The treasury subsidizes oracle operator costs that are not covered by fee revenue. This stage exists because early query volume will be insufficient to sustain validators on fees alone.

### Stage 2: Transition
**Activation trigger:** Governance vote, eligible only after the following condition is met for **3 consecutive calendar months**: *total protocol query fee revenue ≥ 100% of documented oracle operator infrastructure costs.*

This is a concrete, verifiable threshold. "Oracle operator costs" are defined as the sum of gas costs for epoch submissions plus a standardized infrastructure allowance per active oracle node, published quarterly by the oracle operator set. The governance proposal to activate Stage 2 will include a mandatory verification step confirming this condition is met before execution.

**Routing:** 80% validators / 20% burned.

### Stage 3: Mature
**Activation trigger:** Governance vote, eligible only after Stage 2 has been active for **6 months** and validator revenue remains above the sustainability threshold.

**Routing:** 50% validators / 50% burned.

---

## 7. Slashing Burn — Categorically Separate

The current `CountersigStaking` contract burns 50% of slashed stakes to `address(0xdead)` from day one, independent of the fee burn governance stages above.

This is **categorically different** from the fee burn and must be documented and communicated as such:

- **Fee burn** = an economic mechanism activated by governance to manage token velocity. Subject to the three-stage model above.
- **Slashing burn** = a security enforcement mechanism. When an agent is proven malicious, a portion of their stake is permanently destroyed as a penalty. This is not a value accrual mechanism — it is the economic cost of attacking the network. It is analogous to the destruction of a fraudulent bond, not the buyback of equity.

**Legal framing:** The slashing burn is documented exclusively as a *network security property*. It makes Sybil attacks and malicious agent behavior economically irrational by ensuring that the cost of an attack exceeds the potential gain. It is not marketed as deflationary, not referenced in the context of token price, and not presented as a benefit to holders.

**Contract note:** At mainnet, consider redirecting the slashing burn to the treasury timelock rather than `0xdead` during Stage 1. This preserves optionality — the treasury can decide whether to burn or redeploy slashed tokens for ecosystem grants. Once Stage 3 is active and the burn mechanic is governance-confirmed, slashing burns to `0xdead` is the appropriate permanent behavior.

---

## 8. Oracle Operator Economics

Oracle operators are the entities that run the reputation scoring epoch service, submit `updateReputation()` transactions on-chain, and maintain the price feed for the $CSIG/USD fee adjustment. They are a critical security component of the network.

**Why run an oracle at mainnet?**

| Revenue Source | Description |
|:---|:---|
| Query fee share | 100% of query fees during Stage 1. Decreasing share in Stages 2 and 3, but absolute revenue grows with network usage. |
| Treasury subsidy | Year 1: the Ecosystem & Partners allocation (15% of supply) includes a dedicated oracle operator grant program. Oracle operators who commit to a minimum uptime SLA and epoch submission frequency receive CSIG grants from this allocation, disbursed quarterly against verified on-chain performance. |
| Epoch submission gas | Gas costs for `updateReputation()` calls are reimbursed from the treasury during Stage 1. |

**Minimum viable oracle set at mainnet:** 3 independent operators. The goal is 7+ operators within 12 months of mainnet. A formal application and onboarding process for independent node operators will be published 60 days before mainnet launch. Any party that meets the technical requirements and posts a $CSIG performance bond will be eligible to apply to join the oracle set via governance vote.

**Oracle operator performance bond:** Each oracle operator must stake a defined amount of $CSIG as a performance bond, separate from agent registration stakes and managed via a dedicated oracle operator staking contract to be deployed before mainnet oracle onboarding. If an oracle operator submits provably incorrect reputation data or goes offline for more than 24 consecutive hours during an epoch, their bond is partially slashed via this contract. The existing `CountersigStaking` contract handles agent-identity slashing only; oracle operator accountability requires its own accounting and slashing path.

---

## 9. Governance Timelock — Mainnet Parameters

The `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, and all protocol parameter controls transfer to a `TimelockController` contract before mainnet deployment. The deployer retains no special privileges post-TGE.

| Parameter | Value |
|:---|:---|
| Timelock delay (testnet) | 48 hours |
| Timelock delay (mainnet) | **7 days** — locked at deployment, not tunable |
| Proposer | Governance multisig (initially 3-of-5, expanding to community governance post-TGE) |
| Executor | Any address (permissionless execution after delay) |
| Canceller | Governance multisig |

The 7-day mainnet delay is a **hard security guarantee**, not a governance parameter. It is set at contract initialization and cannot be reduced without a full contract migration. This gives the community sufficient time to observe any malicious upgrade proposal and respond before it executes.

---

## 10. What Is Locked Now vs. Tunable Later

| Parameter | Status | Notes |
|:---|:---|:---|
| Total supply (1B) | **Locked** | Fixed at contract deployment, no mint function |
| Distribution percentages | **Locked** | Published in this document before TGE |
| Vesting schedules | **Locked** | On-chain contracts at TGE |
| LP lock mechanism (Unicrypt, 2yr) | **Locked** | Executed at TGE |
| Timelock delay (7 days mainnet) | **Locked** | Set at contract init, not tunable |
| Minimum stake (USD target ~$10) | **Tunable** | Calibrated from Sepolia data |
| Query fee (USD target ~$0.001) | **Tunable** | Calibrated from Sepolia data |
| Burn activation threshold | **Tunable** | Governance vote, eligibility enforced on-chain |
| Oracle operator bond amount | **Tunable** | Set before mainnet oracle onboarding |
| Fee routing split (Stage 2/3) | **Tunable** | Governance vote, eligibility enforced on-chain |

---

*Document version: 0.3 — Pre-TGE design. Subject to revision based on Sepolia testnet data and legal review before mainnet.*
