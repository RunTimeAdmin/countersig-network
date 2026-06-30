# Reputation Model

Countersig reputation is a deterministic 6-factor score between 0 and 100. It is computed off-chain by the oracle network and written to the `CountersigReputation` contract every epoch. The contract stores and serves the score; it does not compute it. This separation means the scoring logic can evolve without storage migrations.

---

## The Six Factors

| Factor | Max Points | Source | Formula |
|---|---|---|---|
| Fee Activity | 30 | On-chain transaction volume in USD | `min(30, floor(totalFeesUSD / 100))` |
| Success Rate | 25 | Cryptographic task attestations | `floor(successRate * 25)` |
| Registration Age | 20 | Time since first registration | `min(20, floor(log₂(days+1) × 4))` |
| External Trust | 15 | SAID Protocol / Gitcoin Passport | `floor(externalScore / 100 × 15)` |
| Community | 5 | Unresolved flags | `max(0, 5 − flags × 2)` |
| Trust Propagation | 5 | Trust graph network effects | oracle-computed |

### Fee Activity (30 pts)

Measures real economic activity. An agent that processes $3,000 in fees reaches the maximum. This is the hardest factor to fake — it requires sustained, on-chain economic participation.

```
$0     → 0 pts
$1000  → 10 pts
$2000  → 20 pts
$3000+ → 30 pts
```

### Success Rate (25 pts)

Based on cryptographic attestations submitted by counterparties. A counterparty that successfully received work from the agent submits a signed attestation. The oracle aggregates all attestations per agent over the epoch.

```
0%   → 0 pts
50%  → 12 pts
80%  → 20 pts
100% → 25 pts
```

This factor will eventually be sourced directly from CounterAudit verified packets — closing the loop between audit trail and reputation.

### Registration Age (20 pts)

Logarithmic growth curve. A brand-new agent scores 0. The curve reaches maximum around day 31 and then levels off. The logarithm prevents a linear arms race where very old (but idle) agents dominate.

```
Day 0   → 0 pts
Day 1   → 4 pts
Day 3   → 8 pts
Day 7   → 12 pts
Day 15  → 16 pts
Day 31  → 20 pts  (maximum)
```

Formula: `min(20, floor(log₂(days+1) × 4))`

### External Trust (15 pts)

Bridges existing identity systems. Currently planned integrations:
- **SAID Protocol** — Semantic Agent Identifier standard
- **Gitcoin Passport** — weighted credential aggregator

An agent that has a verified external identity (GitHub, ENS, biometric attestation via Gitcoin) can carry up to 15 pts from that credential.

### Community Verification (5 pts)

Deducted based on unresolved community flags. The full 5 pts is the default for unflagged agents.

```
0 flags → 5 pts
1 flag  → 3 pts
2 flags → 1 pt
3 flags → 0 pts
```

Flags are submitted through a governance mechanism (separate from slashing). Slashing is economic; flags are reputational.

### Trust Propagation (5 pts)

Network-effect scoring. Agents that are trusted by other high-reputation agents propagate a fraction of that trust. If Agent A (score 80) repeatedly delegates to Agent B and attests success, Agent B gains propagation points.

This factor is currently oracle-computed from the attestation graph and is the most experimental of the six. It will be formalized in Phase 2.

---

## New Agent Ramp-Up

A brand-new agent registers and immediately has:
- Fee Activity: 0 (no transactions yet)
- Success Rate: 0 (no attestations yet)
- Age: 0 (just registered)
- External Trust: depends on credentials
- Community: 5 (no flags)
- Propagation: 0

**Starting score: ~5 points** (community baseline only).

This is by design. A new agent cannot be trusted at the same level as one with 6 months of economic activity. The logarithmic age curve and fee activity floor mean you cannot buy reputation instantly — you have to earn it over time.

The practical ceiling for a new agent within the first week is around 15–20 points. Reaching 50+ requires sustained activity over weeks. The 90+ range requires months of strong economic activity and many successful attestations.

---

## Slashing Resets Everything

When an agent is slashed:

1. `CountersigStaking.executeSlash()` calls `CountersigReputation.zeroReputation(didHash)`
2. All six factor scores are set to zero
3. The agent's status is set to `Slashed` (terminal — no further transitions)
4. The stake is distributed: 50% burned, 25% to victim, 25% to reporter

The slashed DID cannot be reactivated. The operator must register a new agent address with a new DID and start from zero. This economic finality is what makes the reputation meaningful — reputation can be destroyed, so it is worth protecting.

---

## On-Chain Consumption

Any smart contract can gate on reputation:

```solidity
// Inside your contract
ICountersigReputation reputation = ICountersigReputation(REPUTATION_ADDRESS);

function onlyTrustedAgent(bytes32 didHash) internal view {
    require(
        reputation.meetsThreshold(didHash, 50),
        "Agent does not meet minimum reputation threshold"
    );
}
```

Or query directly:

```solidity
uint8 score = reputation.getTotalScore(didHash);
```

---

## Oracle Epochs

The reference oracle runs on a configurable interval (`EPOCH_HOURS`, default 1 hour on testnet). In Phase 2, epochs will be governed by a decentralized oracle network with consensus over the score computation. The on-chain storage format will not change — only the writer changes.

Current oracle: `oracle/` directory in this repository. Single-operator, Sepolia only. Queries `AgentRegistered` events in 9-block chunks (Alchemy free-tier constraint) and uses an in-memory attestation map.

Phase 2 oracle: replaces the in-memory attestation map with cryptographically attested data from CounterAudit (for Success Rate) and integrates SAID / Gitcoin for External Trust.

---

## Related

- [Ecosystem Overview](ecosystem.md)
- [Quickstart: Register your first agent](quickstart.md)
- [CounterAudit Integration Guide](counteraudit-integration.md)
