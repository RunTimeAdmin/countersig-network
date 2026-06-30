# AI Framework Integration

This guide shows how to add Countersig identity to agents built with common AI frameworks. The pattern is the same in every framework: generate a DID at startup, sign challenges when asked to authenticate, and include `agent_did` in every audit call.

---

## LangChain (Python)

### Authenticated tool calls

Wrap your tools so that every call includes the agent's DID and gets audited:

```python
from langchain.tools import BaseTool
from countersig import CountersigAgent
import httpx, os

class AuditedTool(BaseTool):
    name: str
    description: str
    agent: CountersigAgent
    ca_api_key: str

    def _run(self, query: str) -> str:
        # Execute the tool
        result = self._execute(query)

        # Audit the action
        httpx.post(
            "https://api.counteraudit.io/v1/audit/ingest",
            headers={"Authorization": f"Bearer {self.ca_api_key}"},
            json={
                "connector_id": "langchain-agent",
                "agent_did": self.agent.did,
                "raw_event": {
                    "tool": self.name,
                    "query": query,
                    "result_preview": str(result)[:200],
                },
            },
            timeout=5,
        )
        return result

    def _execute(self, query: str) -> str:
        raise NotImplementedError


# Usage
agent = CountersigAgent.from_env()  # reads AGENT_ED25519_SEED + AGENT_ADDRESS + CHAIN_ID

web_search = AuditedWebSearch(
    name="web_search",
    description="Search the web for current information",
    agent=agent,
    ca_api_key=os.environ["CA_API_KEY"],
)
```

### Reputation-gated agent execution

```python
from countersig import CountersigVerifier

verifier = CountersigVerifier.from_env()

def run_agent_if_trusted(agent_did: str, task: str, min_score: int = 40) -> str:
    if not verifier.meets_threshold(agent_did, min_score):
        raise PermissionError(
            f"Agent {agent_did} does not meet minimum reputation score of {min_score}"
        )
    return langchain_agent.run(task)
```

---

## AutoGen (Python)

### Agent with Countersig identity

```python
import autogen
from countersig import CountersigAgent
import httpx, os

agent_identity = CountersigAgent.from_env()

class CountersigAssistant(autogen.AssistantAgent):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._cs_agent = agent_identity
        self._ca_key = os.environ["CA_API_KEY"]

    def generate_reply(self, messages, sender, **kwargs):
        reply = super().generate_reply(messages, sender, **kwargs)

        # Audit every reply
        httpx.post(
            "https://api.counteraudit.io/v1/audit/ingest",
            headers={"Authorization": f"Bearer {self._ca_key}"},
            json={
                "connector_id": "autogen-assistant",
                "agent_did": self._cs_agent.did,
                "raw_event": {
                    "action": "generate_reply",
                    "sender": str(sender.name),
                    "message_count": len(messages),
                    "reply_preview": str(reply)[:200],
                },
            },
            timeout=5,
        )
        return reply


assistant = CountersigAssistant(
    name="ResearchAssistant",
    system_message="You are a helpful research assistant.",
    llm_config={"model": "claude-opus-4-8"},
)
```

---

## CrewAI (Python)

### Audited crew tasks

```python
from crewai import Agent, Task, Crew
from countersig import CountersigAgent
import httpx, os

cs_agent = CountersigAgent.from_env()
ca_key = os.environ["CA_API_KEY"]

def audit_task_result(task_name: str, agent_did: str, result: str):
    httpx.post(
        "https://api.counteraudit.io/v1/audit/ingest",
        headers={"Authorization": f"Bearer {ca_key}"},
        json={
            "connector_id": "crewai",
            "agent_did": agent_did,
            "raw_event": {
                "task": task_name,
                "result_preview": result[:200],
            },
        },
        timeout=5,
    )

researcher = Agent(
    role="Research Analyst",
    goal="Find and summarize relevant information",
    backstory=f"Identified on-chain as {cs_agent.did}",
    verbose=True,
)

research_task = Task(
    description="Research recent developments in AI safety",
    agent=researcher,
    callback=lambda output: audit_task_result("research", cs_agent.did, str(output)),
)

crew = Crew(agents=[researcher], tasks=[research_task])
result = crew.kickoff()
```

---

## TypeScript / Node.js (framework-agnostic)

### Middleware pattern

A thin wrapper that adds identity and auditing to any async function:

```typescript
import { CountersigAgent } from '@countersig/protocol-sdk';

const myAgent = new CountersigAgent({
  privateKey: process.env.AGENT_ED25519_SEED!,
  agentAddress: process.env.AGENT_ADDRESS!,
  chainId: 11155111,
});

async function withAudit<T>(
  action: string,
  fn: () => Promise<T>,
  meta?: Record<string, unknown>
): Promise<T> {
  const result = await fn();

  // fire-and-forget audit — don't block on it
  fetch('https://api.counteraudit.io/v1/audit/ingest', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env.CA_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      connector_id: 'my-agent',
      agent_did: myAgent.did,
      raw_event: { action, ...meta },
    }),
  }).catch(console.error);

  return result;
}

// Usage
const summary = await withAudit(
  'summarize_document',
  () => llm.summarize(documentText),
  { document_id: doc.id, word_count: documentText.split(' ').length }
);
```

### Challenge-response (A2A authentication)

When your agent is challenged by a peer that requires proof of identity:

```typescript
import { CountersigAgent, CountersigVerifier } from '@countersig/protocol-sdk';

// Your agent
const myAgent = new CountersigAgent({
  privateKey: process.env.AGENT_ED25519_SEED!,
  agentAddress: process.env.AGENT_ADDRESS!,
  chainId: 11155111,
});

// Handle an inbound challenge from a peer
function handleChallenge(challengePayload: string): { did: string; signature: string } {
  return {
    did: myAgent.did,
    signature: myAgent.signChallenge(challengePayload),
  };
}

// Verify an inbound agent before trusting its output
const verifier = new CountersigVerifier({ rpcUrl, addresses, chainId: 11155111 });

async function trustAgent(did: string, payload: string, signature: string): Promise<boolean> {
  const sigValid = await verifier.verifySignature(did, payload, signature);
  const repOk = await verifier.meetsThreshold(did, 50);
  return sigValid && repOk;
}
```

---

## General Pattern

Whatever framework you use, the integration is three things:

1. **Identity at startup** — create a `CountersigAgent` from a stored Ed25519 seed. The DID is deterministic from the seed + address + chainId.

2. **Audit on action** — include `agent_did` in every `POST /v1/audit/ingest` call. This can be fire-and-forget if you don't want it on the critical path.

3. **Verify before trust** — before accepting work from or delegating to another agent, call `verifySignature` and `meetsThreshold`. Both are read-only view calls; no gas required.

---

## Related

- [Quickstart: Register your first agent](quickstart.md)
- [CounterAudit Integration Guide](counteraudit-integration.md)
- [Ecosystem Overview](ecosystem.md)
