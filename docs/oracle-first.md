# Direction: Oracle-First, Token Deferred (2026-07-15)

Countersig Network ships as an **oracle and registry service**, not a token
launch. There is no $CSIG token sale, TGE, or listing planned. Anyone selling
a "$CSIG" token is running a scam.

## What this means

- **Mainnet deploys the registries, not the token.** Identity, Reputation,
  Staking, and EpochFees go to Robinhood Chain mainnet (4663) with bonds and
  fees denominated in an established asset (WETH or USDC). Both contracts take
  the token by address at initialization, so this is deploy configuration, not
  a code change. Denominate `minimumStake_` and `epochFee_` in the chosen
  token's decimals (USDC = 6, WETH = 18).
- **Revenue is service revenue.** Scoring epochs, attestations, and API access
  are paid in stablecoins or ETH. No fee-burn, no work-token loop.
- **The testnet keeps using the faucet CSIGToken** for mechanics testing. It
  has no value and never will.
- **The TGE contract set stays on the shelf.** CSIG (fixed-supply), vesting,
  timelock wiring, public sale, and oracle operator bonds are built, tested,
  and unused. They exist for one specific future: decentralizing the oracle
  operator set once scoring volume justifies multiple independent operators.
  A token is a decentralization instrument here, not a launch requirement.

## Why

- A service business has no securities-offering questions to answer, no
  listing-liquidity math, and no float to defend.
- The brand already attracted token scammers before it attracted users; the
  strongest anti-scam posture is "there is no token, period."
- The defensible asset is the scoring pipeline and its integrations
  (CounterAudit today; rug-signal feeds next), not the registry bytecode.

## Order of work

1. First paying/flagship consumer on testnet (CounterAudit end-to-end).
2. Mainnet registry deploy (4663) with WETH/USDC bonds and fees.
3. Second external consumer.
4. Revisit the token only when operator decentralization is the bottleneck.
