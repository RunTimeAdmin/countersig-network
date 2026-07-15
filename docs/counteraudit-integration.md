# CounterAudit Integration Guide

CounterAudit is a tamper-evident AI audit trail service. When you add an `agent_did` field to your ingest calls, CounterAudit enriches each sealed packet with the agent's live on-chain Countersig identity and reputation score before sealing. The enrichment is embedded inside the AES-GCM seal, so it is covered by the same tamper-evidence and RFC 3161 timestamp as the rest of the packet.

This guide is for CounterAudit customers who want to add Countersig identity enrichment to their existing setup.

---

## How It Works

When your application calls `POST /v1/audit/ingest` with an `agent_did` field:

1. CounterAudit parses the DID: `did:countersig:<chainId>:<agentAddress>`
2. It computes the `didHash` using the same formula as the on-chain contract
3. It queries `CountersigIdentity.getIdentity(didHash)` and `CountersigReputation.getTotalScore(didHash)` in parallel
4. The results are spread into the packet body **before** the AES-GCM seal is applied
5. The full packet body — including Countersig fields — is then sealed, hashed, and timestamped

This means the reputation score is frozen in time. If an agent's reputation changes after the action, the sealed record still shows what it was at the moment the action occurred.

---

## Setup

### Self-hosted CounterAudit

Add these variables to your `.env`:

```bash
# Countersig identity enrichment (Robinhood Chain testnet)
COUNTERSIG_RPC_URL=https://rpc.testnet.chain.robinhood.com
COUNTERSIG_IDENTITY_ADDRESS=0xCCF2Fd69c07EDFbc3C215cfD31e2F20FC208A16C
COUNTERSIG_REPUTATION_ADDRESS=0xbB0c9C2DF28af31905dEfEa04c80372C0909f1bF
COUNTERSIG_CHAIN_ID=46630

# Optional — default is 5000ms
COUNTERSIG_ENRICH_TIMEOUT_MS=5000
```

> For the legacy Sepolia deployment use `deployments/11155111.json` and `COUNTERSIG_CHAIN_ID=11155111`.

Then rebuild and restart the container:

```bash
docker compose -f docker-compose.selfhost.yml build --no-cache counteraudit
docker compose -f docker-compose.selfhost.yml up -d counteraudit
```

On startup you will see: `[counteraudit] countersig enrichment enabled`

If the three required vars are absent, the service silently no-ops. No existing ingest calls are affected.

### Managed CounterAudit (api.counteraudit.io)

Contact CounterAudit to enable Countersig enrichment on your organization. The managed service is already running the integration.

---

## Making Ingest Calls

Add `agent_did` alongside your existing fields:

```bash
curl -X POST https://api.counteraudit.io/v1/audit/ingest \
  -H "Authorization: Bearer $CA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "connector_id": "my-agent-connector",
    "agent_did": "did:countersig:46630:0xYourAgentAddress",
    "raw_event": {
      "action": "tool_call",
      "tool": "web_search",
      "query": "carbon capture techniques",
      "result_count": 10
    }
  }'
```

Response is unchanged — you get `packet_id`, `entry_hash`, `created_at` as normal.

### TypeScript

```typescript
async function auditAction(agentDid: string, event: Record<string, unknown>) {
  const res = await fetch('https://api.counteraudit.io/v1/audit/ingest', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env.CA_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      connector_id: 'my-agent',
      agent_did: agentDid,
      raw_event: event,
    }),
  });
  return res.json();
}
```

### Python

```python
import httpx, os

def audit_action(agent_did: str, event: dict) -> dict:
    resp = httpx.post(
        "https://api.counteraudit.io/v1/audit/ingest",
        headers={
            "Authorization": f"Bearer {os.environ['CA_API_KEY']}",
            "Content-Type": "application/json",
        },
        json={
            "connector_id": "my-agent",
            "agent_did": agent_did,
            "raw_event": event,
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()
```

---

## Reading Enriched Data

Call the verify endpoint with the `packet_id` returned from ingest:

```bash
curl https://api.counteraudit.io/v1/audit/verify/$PACKET_ID \
  -H "Authorization: Bearer $CA_API_KEY"
```

The decrypted `packet` object contains:

```json
{
  "agent_did": "did:countersig:46630:0xbCB531B68A87F4BcC3a0394ccD2DB95C52bB4E08",
  "agent_did_hash": "0x2d657d1d166f5c7ed90bebc6808f50d07d7e70cba897d91e7f7d918629d4b0be",
  "agent_chain_id": 46630,
  "agent_reputation_score": 47,
  "agent_identity_status": "Active",
  "agent_identity_verified": true,
  "agent_enriched_at": "2026-06-30T16:33:39.381Z"
}
```

---

## Enriched Field Reference

| Field | Type | Present when | Description |
|---|---|---|---|
| `agent_did` | string | Always (if agent_did provided) | The W3C DID |
| `agent_did_hash` | hex string | DID parses successfully | On-chain index key |
| `agent_chain_id` | number | DID registered | EVM chain ID |
| `agent_reputation_score` | 0–100 | DID registered | Total score at seal time |
| `agent_identity_status` | string | DID registered | `Active`, `Suspended`, or `Slashed` |
| `agent_identity_verified` | boolean | Always | `true` if registered and Active |
| `agent_enriched_at` | ISO 8601 | Always | When the enrichment query ran |
| `agent_enrichment_error` | string | On failure only | Reason (see below) |

### Error values for `agent_enrichment_error`

| Value | Meaning |
|---|---|
| `invalid_did_format` | DID string is malformed |
| `unsupported_chain:<id>` | Chain ID in the DID is not configured |
| `not_registered` | DID parses and resolves but is not registered |
| `rpc_timeout` | Enrichment query exceeded `COUNTERSIG_ENRICH_TIMEOUT_MS` |
| `rpc_error` | RPC call failed for another reason |

In all error cases, `agent_identity_verified` is `false` and the packet still seals normally. Enrichment is never a blocking dependency.

---

## Forensic Properties

**Reputation is frozen at seal time.** If an agent is slashed next month, every audit packet sealed today still shows `agent_reputation_score: 47` and `agent_identity_status: Active`. The RFC 3161 timestamp proves when the seal was applied.

**Enrichment is inside the AES-GCM seal.** The seal covers the entire `bodyForHash` object including Countersig fields. Tampering with any field — including `agent_reputation_score` — invalidates the seal.

**The `didHash` is deterministic.** Any party can verify the hash independently:

```typescript
import { ethers } from 'ethers';

const didHash = ethers.keccak256(
  ethers.solidityPacked(
    ['string', 'uint256', 'string', 'address'],
    ['did:countersig:', BigInt(46630), ':', agentAddress]
  )
);
```

This means an auditor can confirm the `agent_did_hash` in a sealed packet matches the agent's actual on-chain identity without trusting CounterAudit's computation.

---

## Building a Trust Gate

You can gate which agents are allowed to operate by checking reputation before accepting their actions. Example using the CounterAudit ingest plus an on-chain check:

```typescript
import { CountersigVerifier } from '@countersig/protocol-sdk';

const verifier = new CountersigVerifier({ rpcUrl, addresses, chainId: 46630 });

async function handleAgentAction(agentDid: string, action: object) {
  // Block agents below threshold before their action is even audited
  const meets = await verifier.meetsThreshold(agentDid, 30);
  if (!meets) {
    throw new Error(`Agent ${agentDid} does not meet minimum reputation threshold`);
  }

  // Audit the action — enrichment will confirm identity and seal current score
  return auditAction(agentDid, action);
}
```

The threshold check (`meetsThreshold`) is a view call — no gas, <100ms on a good RPC.

---

## Related

- [Ecosystem Overview](ecosystem.md) — how Countersig and CounterAudit fit together
- [Quickstart: Register your first agent](quickstart.md)
- [AI Framework Integration](ai-frameworks.md)
