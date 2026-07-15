# Quickstart: Register Your First Agent

This guide takes you from zero to a registered, reputation-tracked AI agent on **Robinhood Chain testnet** (chain ID `46630`) in about 10 minutes. For deploy / RPC details see [Robinhood Chain](robinhood-chain.md).

## Prerequisites

- Node.js 18+
- A wallet with Robinhood testnet ETH ([faucet](https://faucet.testnet.chain.robinhood.com))
- $CSIG testnet tokens — call the faucet on the CSIGToken contract (see below)

## 1. Install the SDK

```bash
npm install @countersig/protocol-sdk ethers
```

## 2. Set up your environment

```bash
# .env
OPERATOR_PRIVATE_KEY=0x...      # needs RH testnet ETH for gas + CSIG for stake
RPC_URL=https://rpc.testnet.chain.robinhood.com
```

Testnet contract addresses (Robinhood Chain testnet, chain ID `46630` — from `deployments/46630.json`):

```
IDENTITY_ADDRESS=0xCCF2Fd69c07EDFbc3C215cfD31e2F20FC208A16C
REPUTATION_ADDRESS=0xbB0c9C2DF28af31905dEfEa04c80372C0909f1bF
STAKING_ADDRESS=0x7281cf35ae9Bf56EAF5B1d0C2C8e167e50BCEC75
CSIG_TOKEN=0x7E44aF56d14EBfd16D5D7Ba4F011b5206d487D55
```

> Legacy Sepolia (`11155111`) addresses remain in `deployments/11155111.json` if you still need them.

## 3. Get testnet $CSIG

The CSIGToken has an `onlyOwner` mint and a public `faucet()`. Call it once per wallet:

```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const signer = new ethers.Wallet(process.env.OPERATOR_PRIVATE_KEY, provider);

const csig = new ethers.Contract(
  '0x7E44aF56d14EBfd16D5D7Ba4F011b5206d487D55',
  ['function faucet() external', 'function balanceOf(address) view returns (uint256)'],
  signer
);

await csig.faucet();
const balance = await csig.balanceOf(signer.address);
console.log('CSIG balance:', ethers.formatEther(balance));
```

## 4. Generate an Ed25519 keypair

The agent's cryptographic identity. Store the private key securely — it cannot be recovered.

```typescript
import { CountersigAgent } from '@countersig/protocol-sdk';

// The agent address can differ from the operator address.
// Often it IS the operator address on testnet.
const agentAddress = signer.address;

const { agent, privateKey } = CountersigAgent.generate({
  agentAddress,
  chainId: 46630,
});

console.log('DID:', agent.did);
// → did:countersig:46630:0x...

console.log('Ed25519 private key (store this):', privateKey);
```

## 5. Register on-chain

Two transactions: approve the staking contract to spend CSIG, then register.

```typescript
import { registerAgent } from '@countersig/protocol-sdk';

// Approve staking contract to pull CSIG (1000 CSIG minimum stake)
const minStake = ethers.parseEther('1000');
await csig.approve(STAKING_ADDRESS, minStake);

// Register — this calls depositStake + registerAgent atomically
const { didHash, txHash } = await registerAgent(
  signer,
  agentAddress,
  agent.publicKeyBytes32,
  IDENTITY_ADDRESS,
  STAKING_ADDRESS,
  minStake,
);

console.log('didHash:', didHash);
console.log('tx:', `https://explorer.testnet.chain.robinhood.com/tx/${txHash}`);
```

After a few blocks the oracle will detect the `AgentRegistered` event and begin tracking the agent. The initial score will be low (age=0, activity=0) and will grow over time.

## 6. Verify registration

```typescript
import { CountersigVerifier } from '@countersig/protocol-sdk';

const verifier = new CountersigVerifier({
  rpcUrl: process.env.RPC_URL,
  addresses: { identity: IDENTITY_ADDRESS, reputation: REPUTATION_ADDRESS, staking: STAKING_ADDRESS },
  chainId: 46630,
});

const identity = await verifier.getIdentity(agent.did);
console.log('Status:', identity.status);   // → Active
console.log('Registered at block:', identity.registeredAt);

const score = await verifier.getTotalScore(agent.did);
console.log('Reputation score:', score);   // → 5 (new agent baseline)
```

## 7. Sign a challenge (agent-to-agent authentication)

This is how your agent proves its identity to another agent without a central authority.

```typescript
// Your agent (the prover) — loaded from stored private key
const myAgent = new CountersigAgent({
  privateKey: process.env.AGENT_ED25519_SEED,
  agentAddress,
  chainId: 46630,
});

// Peer agent (the verifier) issues a challenge
const challenge = peerAgent.issueChallenge(myAgent.did);

// Sign the challenge payload with your Ed25519 key
const signature = myAgent.signChallenge(challenge.payload);

// Peer verifies: resolves pubkey from chain, checks signature + reputation
const valid = await verifier.verifySignature(myAgent.did, challenge.payload, signature);
const trusted = await verifier.meetsThreshold(myAgent.did, 60);

console.log('Signature valid:', valid);
console.log('Meets 60-point threshold:', trusted);
```

## 8. Wire up CounterAudit (optional but recommended)

If you're using [CounterAudit](https://counteraudit.io) to audit your agent's actions, pass `agent_did` in every ingest call. CounterAudit will enrich each sealed packet with the agent's live on-chain identity and reputation score.

```typescript
await fetch('https://api.counteraudit.io/v1/audit/ingest', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${CA_API_KEY}`,
  },
  body: JSON.stringify({
    connector_id: 'my-agent',
    agent_did: myAgent.did,
    raw_event: {
      action: 'tool_call',
      tool: 'web_search',
      query: 'latest AI safety papers',
      result_count: 10,
    },
  }),
});
```

The sealed packet will contain `agent_reputation_score`, `agent_identity_status`, `agent_identity_verified`, and related fields — frozen at the moment of the action.

---

## Next steps

- [Robinhood Chain](robinhood-chain.md) — RPC, deploy, oracle wiring
- [CounterAudit Integration Guide](counteraudit-integration.md) — full setup and field reference
- [AI Framework Integration](ai-frameworks.md) — LangChain, AutoGen, CrewAI patterns
- [Reputation Model](reputation-model.md) — how your score grows over time
- [Ecosystem Overview](ecosystem.md) — the full protocol picture
