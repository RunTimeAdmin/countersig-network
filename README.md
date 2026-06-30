# Countersig Network — Protocol Contracts

Decentralized identity and trust infrastructure for autonomous AI agents.

## Overview

Three EVM smart contracts form the protocol core:

| Contract | Purpose |
|---|---|
| `CountersigIdentity` | Anchors agent DIDs on-chain. Stores Ed25519 public keys. Controls AgentStatus state machine. |
| `CountersigReputation` | Stores oracle-computed 6-factor reputation scores (0-100). |
| `CountersigStaking` | Manages $CSIG bonds. Enforces the multisig-committee slashing model. |

Each contract uses UUPS upgradeable proxies (OpenZeppelin v5) controlled by a governance timelock.

## DID Method

`did:countersig:<chainId>:<agentAddress>`

The `didHash` is computed on-chain at registration:
```
keccak256(abi.encodePacked("did:countersig:", block.chainid, ":", agentAddress))
```

## Reputation Factors

| Factor | Max | Signal |
|---|---|---|
| Fee Activity | 30 | On-chain economic activity |
| Success Rate | 25 | Cryptographic task attestations |
| Age | 20 | `min(20, floor(log2(days+1) * 4))` |
| External Trust | 15 | SAID Protocol / Gitcoin Passport |
| Community | 5 | Flag-free standing |
| Propagation | 5 | Network trust graph |

## Slashing Model (Testnet)

- 3-of-5 multisig `SLASHING_COMMITTEE`
- 7-day challenge period (operator can dispute)
- On execution: 50% burned, 25% victim, 25% reporter
- Mainnet path: replace committee with UMA OptimisticOracleV3 or Kleros

## Setup

Requires [Foundry](https://getfoundry.sh).

```bash
forge install
forge build
forge test
```

## Roadmap

- Q3 2026: Sepolia testnet deployment + SDK v1.0
- Q4 2026: Decentralized oracle network + SAID/Gitcoin integration
- Q1 2027: Mainnet + $CSIG TGE
- Q2 2027: Cross-chain (Solana + Base via LayerZero)

## License

MIT
