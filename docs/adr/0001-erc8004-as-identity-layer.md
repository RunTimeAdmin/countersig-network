# ADR 0001 — ERC-8004 as the canonical identity layer

**Status:** Accepted · 2026-07-16

## Context

Countersig shipped its own on-chain registries: `CountersigIdentity`
(a `did:countersig` DID registry) and `CountersigReputation` (a computed
6-factor score), plus `CountersigStaking` (bonds + slashing).

Since then, **ERC-8004 "Trustless Agents"** has become a backed Ethereum
standard (contributors from MetaMask, the Ethereum Foundation, Google, and
Coinbase), deployed as canonical singletons on 30+ chains. It defines an
Identity Registry (ERC-721) and a Reputation Registry (raw signed feedback),
and it deliberately leaves reputation *computation*, staking, and slashing out
of scope.

Maintaining a parallel `did:countersig` identity registry alongside the
standard is redundant. But the overlap is only partial, and naming it exactly
is what makes the resolution clean.

## Decision

1. **ERC-8004 Identity Registry is the canonical agent registry going forward.**
   The `did:countersig` identity method is **deprecated**. Agents are identified
   by their ERC-8004 agent id (CAIP-10 style: `eip155:{chainId}:{registry}` +
   agentId).

2. **`CountersigReputation` is retained** and reframed as the **computed-score
   anchor** — it stores the oracle's normalized, capped score, which ERC-8004's
   Reputation Registry (raw feedback only) does not provide. This is the layer
   *above* 8004, not a duplicate of it.

3. **`CountersigStaking` is retained** as the staked-accountability
   (bonding + slashing) layer. ERC-8004 has no equivalent; this is the
   differentiator.

4. **`CountersigIdentity` is deprecated as a registry.** Its only non-redundant
   content — the on-chain Ed25519 public key (for A2A challenge-response auth)
   and the slash status — becomes a thin **extension keyed to an ERC-8004 agent
   id**, not a standalone identity namespace.

## Consequences

- Positioning shifts from "our own identity protocol" to **"the computed-
  reputation and staked-slashing layer on ERC-8004."** Public materials
  (README, site) are updated to match.
- The deployed `CountersigIdentity` on Robinhood testnet `46630` remains for
  continuity of already-registered testnet agents but is **legacy** — no new
  features, and it is not the go-forward registration path.
- The read and write bridges to 8004 already exist: the oracle reads 8004
  feedback for `externalScore`, and CounterAudit publishes outcomes to the 8004
  Reputation Registry.
- **The full code cutover** (oracle keying on the 8004 agent id, SDK, and app
  onboarding registering directly on 8004) is **staged, not done here.** It
  executes as one clean effort *after* the external-validation gate
  (2026-10-14), so the parallel registry is retired once — not migrated twice —
  and no heavy migration is spent ahead of proven demand. Until then, the
  `/link` bridge (Countersig agent ↔ 8004 agent id, ownership-verified) carries
  the interop.

## What this does not change

`CountersigReputation` and `CountersigStaking` stay. The redundancy was only
ever the identity registry; the computation and accountability layers are the
reason Countersig exists on top of the standard.
