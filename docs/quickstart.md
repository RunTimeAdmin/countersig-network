# Quickstart: Register Your First Agent

This guide takes you from zero to a registered, reputation-tracked AI agent on Sepolia in about 10 minutes.

## Prerequisites

- Node.js 18+
- An Ethereum wallet with Sepolia ETH (use the [Sepolia faucet](https://sepoliafaucet.com))
- $CSIG testnet tokens — call the faucet on the CSIGToken contract (see below)

## 1. Install the SDK

```bash
npm install @countersig/protocol-sdk ethers
```

## 2. Set up your environment

```bash
# .env
OPERATOR_PRIVATE_KEY=0x...      # Sepolia wallet, needs ETH for gas + CSIG for stake
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
```

Testnet contract addresses (Sepolia, chain ID 11155111):

```
IDENTITY_ADDRESS=0xD738A4cBe525d214f86059A8328786f072D6fbe1
REPUTATION_ADDRESS=0x0613C561C5003D7948Ea09dE2C1895965A5c3F27
STAKING_ADDRESS=0x60347640d46B55E7dafFA8F385bc55eE2D77ee85
CSIG_TOKEN=0x6d5E311e821c3e279dBe9833F8e33828f7716FA8
```

## 3. Get testnet $CSIG

The CSIGToken has an `onlyOwner` mint and a public `faucet()`. Call it once per wallet:

```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const signer = new ethers.Wallet(process.env.OPERATOR_PRIVATE_KEY, provider);

const csig = new ethers.Contract(
  '0x6d5E311e821c3e279dBe9833F8e33828f7716FA8',
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
  chainId: 11155111,
});

console.log('DID:', agent.did);
// → did:countersig:11155111:0x...

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
console.log('tx:', `https://sepolia.etherscan.io/tx/${txHash}`);
```

After a few blocks the oracle will detect the `AgentRegistered` event and begin tracking the agent. The initial score will be low (age=0, activity=0) and will grow over time.

## 6. Verify registration

```typescript
import { CountersigVerifier } from '@countersig/protocol-sdk';

const verifier = new CountersigVerifier({
  rpcUrl: process.env.RPC_URL,
  addresses: { identity: IDENTITY_ADDRESS, reputation: REPUTATION_ADDRESS, staking: STAKING_ADDRESS },
  chainId: 11155111,
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
  chainId: 11155111,
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

- [CounterAudit Integration Guide](counteraudit-integration.md) — full setup and field reference
- [AI Framework Integration](ai-frameworks.md) — LangChain, AutoGen, CrewAI patterns
- [Reputation Model](reputation-model.md) — how your score grows over time
- [Ecosystem Overview](ecosystem.md) — the full protocol picture
