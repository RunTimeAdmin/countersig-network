# Robinhood Chain Migration

Countersig contracts are EVM-generic (`block.chainid` for DIDs). This guide moves
**testing and deployment** from Ethereum Sepolia (`11155111`) to **Robinhood Chain
testnet** (`46630`), with mainnet (`4663`) as the production target.

| Network | Chain ID | Public RPC | Explorer | Faucet |
|---|---|---|---|---|
| Robinhood testnet | `46630` | `https://rpc.testnet.chain.robinhood.com` | [explorer.testnet…](https://explorer.testnet.chain.robinhood.com) | [faucet.testnet…](https://faucet.testnet.chain.robinhood.com) |
| Robinhood mainnet | `4663` | `https://rpc.mainnet.chain.robinhood.com` | [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com) | — |
| Sepolia (legacy) | `11155111` | Alchemy / Infura | Etherscan | sepoliafaucet.com |

Official network docs: [Connecting to Robinhood Chain](https://docs.robinhood.com/chain/connecting/).

Public RPCs are rate-limited. Prefer Alchemy (`robinhood-testnet` / `robinhood-mainnet`) for oracle indexing and heavy testing.

---

## 1. Prerequisites

- Foundry (`forge`, `cast`)
- Solidity deps locally (same as CI; `lib/` is gitignored):

```bash
git clone --depth 1 --branch v5.6.1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
git clone --depth 1 --branch v5.6.1 https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git lib/openzeppelin-contracts-upgradeable
git clone --depth 1 https://github.com/foundry-rs/forge-std.git lib/forge-std
```

- A funded deployer on Robinhood testnet (ETH for gas — use the faucet above)
- `DEPLOYER_PRIVATE_KEY` exported in your shell (never commit it)

```powershell
# PowerShell — verify RPC before deploying
cast chain-id --rpc-url robinhood_testnet
# → 46630
```

```bash
export DEPLOYER_PRIVATE_KEY=0x...
# optional role overrides (default to deployer):
export ORACLE_ADDRESS=0x...
export COMMITTEE_ADDRESS=0x...
```

---

## 2. Deploy the protocol (testnet)

Named RPC aliases live in `foundry.toml` (`robinhood_testnet` / `robinhood_mainnet`).

```bash
# Simulate first (no broadcast)
forge script script/Deploy.s.sol --rpc-url robinhood_testnet -vvvv

# Broadcast — writes deployments/46630.json
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast -vvvv
```

Optional Blockscout verification (do **not** put `[etherscan]` chain entries for
46630/4663 in `foundry.toml` yet — Foundry rejects unknown chain IDs and breaks
`forge script`):

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast \
  --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api/ -vvvv
```

On success you should see `deployments/46630.json` with `identity`, `reputation`,
`staking`, and `csigToken`. Commit that file once the deployment is intentional.

### Live deployment (2026-07-15)

| Contract | Address |
|---|---|
| CSIG Token | [`0x7E44aF56d14EBfd16D5D7Ba4F011b5206d487D55`](https://explorer.testnet.chain.robinhood.com/address/0x7E44aF56d14EBfd16D5D7Ba4F011b5206d487D55) |
| Identity | [`0xCCF2Fd69c07EDFbc3C215cfD31e2F20FC208A16C`](https://explorer.testnet.chain.robinhood.com/address/0xCCF2Fd69c07EDFbc3C215cfD31e2F20FC208A16C) |
| Reputation | [`0xbB0c9C2DF28af31905dEfEa04c80372C0909f1bF`](https://explorer.testnet.chain.robinhood.com/address/0xbB0c9C2DF28af31905dEfEa04c80372C0909f1bF) |
| Staking | [`0x7281cf35ae9Bf56EAF5B1d0C2C8e167e50BCEC75`](https://explorer.testnet.chain.robinhood.com/address/0x7281cf35ae9Bf56EAF5B1d0C2C8e167e50BCEC75) |
| Deployer / oracle / committee | `0xfB38fA3C085FD9D06564524855d00E098ae0c450` |
| Deploy block | `~90338571` |

Addresses are also in `deployments/46630.json`.


**DID note:** agents on Robinhood get `did:countersig:46630:0x...`. Sepolia DIDs
(`11155111`) are a different namespace — there is no automatic carry-over.

---

## 3. Point the oracle at Robinhood

Copy `oracle/.env.example` → `oracle/.env`, then set:

```bash
RPC_URL=https://rpc.testnet.chain.robinhood.com   # or your Alchemy URL
IDENTITY_ADDRESS=0x...      # from deployments/46630.json
REPUTATION_ADDRESS=0x...
FROM_BLOCK=<deploy block>   # cast block-number around deploy time; subtract a small buffer
LOG_CHUNK_SIZE=2000         # public/Alchemy RH can take larger windows than Alchemy Sepolia free tier
EPOCH_HOURS=1
ORACLE_PRIVATE_KEY=0x...    # must hold ORACLE_ROLE on Reputation
```

Grant `ORACLE_ROLE` to the oracle wallet if it differs from the deployer used at deploy time.

---

## 4. Run SDK live integration tests

```bash
cd packages/sdk
export COUNTERSIG_RPC_URL=https://rpc.testnet.chain.robinhood.com
export COUNTERSIG_CHAIN_ID=46630
export COUNTERSIG_IDENTITY_ADDRESS=0x...
export COUNTERSIG_REPUTATION_ADDRESS=0x...
export COUNTERSIG_STAKING_ADDRESS=0x...
export COUNTERSIG_OPERATOR_PRIVATE_KEY=0x...   # funded; used to register a test agent

npx vitest run test/integration.test.ts
```

Unit tests (`did.test.ts`, `agent.test.ts`, etc.) stay chain-agnostic fixtures —
they still use Sepolia IDs as dummy numbers and do not hit a network.

---

## 5. Forge unit tests

Unchanged. They run on Foundry’s in-memory EVM:

```bash
forge test
FOUNDRY_PROFILE=ci forge test   # denser fuzz, matches CI
```

Optional later: add a fork test suite against `robinhood_testnet` for post-deploy smoke checks.

---

## 6. Production (Robinhood mainnet)

Use `script/DeployMainnet.s.sol` + fixed-supply `CSIG` (not the testnet `CSIGToken`
faucet) when you are ready for TGE on chain `4663`. Uniswap is available on
Robinhood Chain for liquidity; revisit any Ethereum-only assumptions in
`docs/tokenomics.md` (e.g. Unicrypt) before mainnet.

---

## Checklist

- [x] Fund deployer on Robinhood testnet
- [x] `forge script …Deploy.s.sol --rpc-url robinhood_testnet --broadcast`
- [x] Commit `deployments/46630.json` (and RH harness docs)
- [x] Wire `oracle/.env` + roles (deployer holds ORACLE_ROLE)
- [x] Pass SDK `integration.test.ts` with `COUNTERSIG_CHAIN_ID=46630`
- [x] Update consumer docs/apps away from Sepolia examples when RH is primary
