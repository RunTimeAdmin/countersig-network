# Countersig Network: Technical Build Document

## 1. Executive Summary

The Countersig Network is a decentralized identity and trust protocol designed explicitly for autonomous AI agents. As AI agents evolve into independent economic actors, the lack of verifiable Non-Human Identity (NHI) presents a systemic risk, enabling Sybil attacks, reputation manipulation, and unaccountable execution.

This protocol redesign transitions Countersig from a centralized SaaS architecture into a permissionless, cryptoeconomically secured infrastructure. The design philosophy centers on **verifiability, interoperability, and economic accountability**. By anchoring W3C Decentralized Identifiers (DIDs) on-chain, enforcing Ed25519 PKI challenge-response authentication, and implementing a staked 5-factor reputation algorithm, Countersig establishes a trustless environment for agent-to-agent (A2A) and human-to-agent interactions.

**Key Differences from Centralized Predecessor:**
- **State Management:** Identity and reputation state transitions from a centralized PostgreSQL database to EVM-compatible smart contract registries.
- **Economic Security:** Replaces subscription billing with a `$CSIG` utility token staking model, introducing slashing mechanics to penalize malicious agent behavior.
- **Permissionless Operation:** Removes the centralized API gateway, allowing agents to authenticate and verify peers directly via on-chain state and decentralized DID resolution.

## 2. Protocol Architecture Overview

The Countersig Network operates across three layers: the On-Chain State Layer, the Decentralized Identity Layer, and the Off-Chain Verification Layer.

```text
+-------------------------------------------------------------------+
|                     Off-Chain Verification Layer                  |
|                                                                   |
|  +----------------+     +----------------+     +---------------+  |
|  |  Agent Node A  | <-> |  Agent Node B  | <-> |  User Client  |  |
|  | (Ed25519 Keys) | A2A | (Ed25519 Keys) |     | (DApp/Wallet) |  |
|  +-------+--------+     +--------+-------+     +-------+-------+  |
|          |                       |                     |          |
+----------|-----------------------|---------------------|----------+
           | PKI Auth              | PKI Auth            | Query
+----------|-----------------------|---------------------|----------+
|          v                       v                     v          |
|                  Decentralized Identity Layer                     |
|            (DID Resolution & Verifiable Credentials)              |
+-------------------------------------------------------------------+
|                               |                                   |
+-------------------------------|-----------------------------------+
|                               v                                   |
|                     On-Chain State Layer (EVM)                    |
|                                                                   |
|  +----------------+     +----------------+     +---------------+  |
|  |    Identity    |     |   Reputation   |     |   Credential  |  |
|  |    Registry    | <-> |    Registry    | <-> |    Registry   |  |
|  +----------------+     +----------------+     +---------------+  |
|          ^                       ^                     ^          |
|          |                       |                     |          |
|  +-------------------------------------------------------------+  |
|  |                    Staking & Slashing Core                  |  |
|  +-------------------------------------------------------------+  |
+-------------------------------------------------------------------+
```

**Core Components:**
- **On-Chain State:** Three primary EVM registries manage the lifecycle of agent identities, compute their 5-factor reputation scores, and store verifiable credential hashes. The Staking Core enforces economic security.
- **Decentralized Identity Layer:** A network of DID resolvers that map `did:countersig` identifiers to their on-chain state and retrieve public keys for signature verification.
- **Off-Chain Verification:** Agents and users interact directly, using challenge-response protocols signed with Ed25519 keys. The on-chain registries act as the ultimate source of truth for public keys and reputation status.

## 3. On-Chain Registry Specifications

The protocol state is managed by three interconnected smart contracts, designed for composability and gas efficiency.

### Registry 1: Identity Registry
Anchors the agent's identity and maps it to the operator's address and the agent's public key.

- **Storage Layout:**
  - `mapping(bytes32 => AgentIdentity) public identities;`
  - `AgentIdentity` struct: `operatorAddress`, `ed25519PublicKey`, `status` (Active, Suspended, Slashed), `registrationTimestamp`.
- **Access Control:** Only the `operatorAddress` can update the public key or status. The Staking Core can update the status to `Slashed`.
- **Key Interface:** `registerAgent(bytes32 didHash, bytes32 ed25519PubKey)`

### Registry 2: Trust/Reputation Registry
Maintains the 5-factor reputation score for each agent.

- **Storage Layout:**
  - `mapping(bytes32 => ReputationData) public reputations;`
  - `ReputationData` struct: `feeActivityScore`, `successRateScore`, `ageScore`, `externalTrustScore`, `communityScore`, `lastUpdated`.
- **Access Control:** Updates are restricted to authorized Oracle contracts (for off-chain data like API success rates) and the Staking Core (for slashing events).
- **Key Interface:** `updateReputationFactor(bytes32 didHash, uint8 factorId, uint256 newScore)`

### Registry 3: Agent Credential Registry
Stores cryptographic hashes of Verifiable Credentials (VCs) issued to or by the agent, enabling on-chain verification of off-chain claims.

- **Storage Layout:**
  - `mapping(bytes32 => mapping(bytes32 => CredentialHash)) public credentials;`
  - `CredentialHash` struct: `issuerDidHash`, `merkleRoot`, `revoked`.
- **Access Control:** Any registered agent can issue a credential hash. Only the issuer can revoke it.
- **Key Interface:** `registerCredential(bytes32 subjectDidHash, bytes32 credentialMerkleRoot)`

## 4. Identity Layer: W3C DID Implementation

Countersig implements a custom DID method, `did:countersig`, fully compliant with W3C standards, optimized for Ed25519 keypairs.

### DID Method Specification
- **Format:** `did:countersig:<chain_id>:<agent_address>`
- **Example:** `did:countersig:1:0x1234...abcd`

### DID Document Structure
The on-chain Identity Registry state resolves dynamically into a standard DID Document:

```json
{
  "@context": [
    "https://www.w3.org/ns/did/v1",
    "https://w3id.org/security/suites/ed25519-2020/v1"
  ],
  "id": "did:countersig:1:0x1234abcd",
  "controller": "did:pkh:eip155:1:0xOperatorAddress",
  "verificationMethod": [{
    "id": "did:countersig:1:0x1234abcd#key-1",
    "type": "Ed25519VerificationKey2020",
    "controller": "did:countersig:1:0x1234abcd",
    "publicKeyMultibase": "z6MkhaXgBZDvotDkL5257faiztiCEsJ"
  }],
  "authentication": ["did:countersig:1:0x1234abcd#key-1"],
  "assertionMethod": ["did:countersig:1:0x1234abcd#key-1"]
}
```

### Ed25519 PKI Challenge-Response Flow
Agents authenticate off-chain using their Ed25519 keys, verified against the on-chain DID Document.

**Sequence:**
1. **Request:** Agent A requests access from Agent B.
2. **Challenge:** Agent B generates a payload: `COUNTERSIG-VERIFY:{AgentA_DID}:{Nonce}:{Timestamp}` and sends it to Agent A.
3. **Sign:** Agent A signs the payload using its Ed25519 private key.
4. **Resolve:** Agent B resolves `AgentA_DID` via the Identity Registry to retrieve the `publicKeyMultibase`.
5. **Verify:** Agent B verifies the signature using the retrieved public key. If valid, authentication succeeds.
## 5. Reputation System: 5-Factor Algorithm

The Countersig reputation system computes a deterministic score (0-100) using a 5-factor model. This score is stored in the Reputation Registry and determines the agent's trust tier.

### The 5 Factors and Weights
1. **Fee Activity (30%):** Measures economic utility. Calculated based on verifiable on-chain transaction volume or API fees paid/received. 
   - *Scoring:* `min(30, floor(totalFeesUSD / 100))`
2. **Success Rate (25%):** Measures operational reliability. Based on cryptographic attestations from counterparties regarding successful task completion.
   - *Scoring:* `floor((successfulTasks / totalTasks) * 25)`
3. **Registration Age (20%):** Measures longevity and persistence.
   - *Scoring:* `min(20, daysSinceRegistration)`
4. **External Trust (15%):** Measures cross-platform validity. Integrates scores from external registries (e.g., SAID Protocol, Gitcoin Passport).
   - *Scoring:* `floor((externalScore / 100) * 15)`
5. **Community Verification (10%):** Measures behavioral safety. Starts at 10, reduced by community flags or minor slashing events.
   - *Scoring:* `10 - (activeFlags * 5)` (Min 0)

### On-Chain Scoring Mechanics
To optimize gas, the Reputation Registry does not compute the score on every transaction. Instead, an off-chain decentralized oracle network aggregates the raw data, computes the score, and submits a state update to the registry periodically (e.g., every 24 hours) or upon a significant deviation threshold.

### Sybil Resistance
The algorithm heavily weights Age and Fee Activity, making it economically unviable for an attacker to spin up thousands of fake agents to farm high reputation scores. A new agent fundamentally cannot achieve a score above 50 without demonstrating sustained economic activity over time.

## 6. Cryptoeconomic Security Model

The protocol relies on the `$CSIG` utility token to align incentives, prevent Sybil attacks, and provide economic recourse for malicious behavior.

### Staking and Bonding Mechanisms
- **Identity Bond:** To register an agent in the Identity Registry, the operator must stake a minimum amount of `$CSIG`. This stake is locked for the duration of the agent's active status.
- **Tiered Staking:** Operators can choose to over-collateralize their agents. Higher stakes signal greater economic capacity, which may be required by counterparties for high-value transactions.

### Incentive Structures
- **Validator Yield:** Independent nodes that operate the reputation oracle network must stake `$CSIG`. They earn yield from query fees paid by applications resolving DIDs and fetching reputation scores.
- **Attestation Rewards:** Counterparties who submit verifiable cryptographic proofs of successful agent interactions receive a micro-reward in `$CSIG`, incentivizing accurate data reporting.

### Penalty and Slashing Conditions
If an agent acts maliciously (e.g., executing an unauthorized transaction, failing to deliver a paid service, or generating malicious outputs), a slashing condition is triggered:
1. **Evidence Submission:** The victim submits a cryptographic proof of the agent's failure or malicious action to the Staking Core.
2. **Challenge Period:** A timelock initiates, allowing the agent operator to dispute the claim.
3. **Slashing Execution:** If the claim is validated by the oracle network or governance dispute resolution, the agent's stake is slashed.
4. **Distribution:** 50% of the slashed stake is burned (deflationary pressure), and 50% is awarded to the victim and the reporting validators. The agent's identity is marked as `Slashed` in the registry.

## 7. Smart Contract Specifications

*Note: The following are simplified Solidity interface definitions.*

### Core Interfaces

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICountersigIdentity {
    enum AgentStatus { Active, Suspended, Slashed }

    struct AgentIdentity {
        address operator;
        bytes32 ed25519PubKey;
        AgentStatus status;
        uint256 registeredAt;
    }

    event AgentRegistered(bytes32 indexed didHash, address indexed operator);
    event AgentStatusUpdated(bytes32 indexed didHash, AgentStatus newStatus);

    function registerAgent(bytes32 didHash, bytes32 ed25519PubKey) external;
    function updateStatus(bytes32 didHash, AgentStatus newStatus) external;
    function getIdentity(bytes32 didHash) external view returns (AgentIdentity memory);
}

interface ICountersigReputation {
    struct ReputationData {
        uint8 feeScore;
        uint8 successScore;
        uint8 ageScore;
        uint8 externalScore;
        uint8 communityScore;
        uint256 lastUpdated;
    }

    event ReputationUpdated(bytes32 indexed didHash, uint8 totalScore);

    function updateReputation(bytes32 didHash, ReputationData calldata data) external;
    function getTotalScore(bytes32 didHash) external view returns (uint8);
}

interface ICountersigStaking {
    event StakeDeposited(bytes32 indexed didHash, uint256 amount);
    event StakeSlashed(bytes32 indexed didHash, uint256 penaltyAmount);

    function depositStake(bytes32 didHash, uint256 amount) external;
    function slashAgent(bytes32 didHash, bytes calldata proof) external;
}
```

### Security Considerations
- **Access Control:** `updateReputation` and `slashAgent` must be strictly protected via `AccessControl` modifiers, restricted to approved Validator/Oracle addresses.
- **Reentrancy:** All staking and slashing functions must utilize OpenZeppelin's `ReentrancyGuard`.
- **Upgradeability:** Contracts should utilize the UUPS (Universal Upgradeable Proxy Standard) pattern, controlled by a decentralized governance timelock.

## 8. Protocol Flows & Use Cases

### Flow 1: Agent Registration and Identity Bootstrapping
1. The Operator generates an Ed25519 keypair for the AI Agent off-chain.
2. The Operator calls `depositStake()` on the Staking contract with the required `$CSIG`.
3. The Operator calls `registerAgent()` on the Identity Registry, linking the agent's public key to their Ethereum address.
4. The protocol emits `AgentRegistered`, and the agent's `did:countersig` identifier is now resolvable globally.

### Flow 2: Agent-to-Agent (A2A) Trust Verification
1. Agent A requests an API action from Agent B.
2. Agent B issues a PKI challenge to Agent A.
3. Agent A signs the challenge with its Ed25519 private key.
4. Agent B resolves Agent A's DID via the Identity Registry to fetch the public key and verifies the signature.
5. Agent B queries the Reputation Registry for Agent A's score.
6. If the signature is valid and the reputation score meets Agent B's threshold (e.g., > 60), the API action is permitted.

### Flow 3: Reputation Update Lifecycle
1. Agent A successfully completes a transaction for User C.
2. User C signs a cryptographic attestation of success and submits it to the decentralized oracle network.
3. The oracle network aggregates attestations over a 24-hour epoch.
4. The oracle consensus contract calls `updateReputation()` on the Reputation Registry, adjusting Agent A's `successScore`.
## 9. Developer Integration Guide

Integrating an AI agent with the Countersig Network requires utilizing the SDK to manage identity, sign challenges, and query peer reputation.

### SDK Overview
The `@countersig/protocol-sdk` provides abstraction over the EVM contracts and Ed25519 cryptography.

### Example: Agent Authentication
```typescript
import { CountersigAgent, ChallengeResponse } from '@countersig/protocol-sdk';

// Initialize the agent with its private key
const agent = new CountersigAgent({
  privateKey: process.env.AGENT_ED25519_PRIVATE_KEY,
  rpcUrl: 'https://rpc.countersig.network'
});

// 1. Receive challenge from a peer
const challengePayload = "COUNTERSIG-VERIFY:did:countersig:1:0xabcd:nonce-123:1710000000";

// 2. Sign the challenge
const signature = await agent.signChallenge(challengePayload);

// 3. Send response back to peer
const response: ChallengeResponse = {
  did: agent.did,
  signature: signature
};
```

### Example: Verifying a Peer
```typescript
import { CountersigVerifier } from '@countersig/protocol-sdk';

const verifier = new CountersigVerifier({ rpcUrl: 'https://rpc.countersig.network' });

async function handleAgentRequest(request) {
  // 1. Resolve DID and verify signature
  const isValid = await verifier.verifySignature(
    request.did, 
    request.challengePayload, 
    request.signature
  );
  
  if (!isValid) throw new Error("Invalid cryptographic signature");

  // 2. Check on-chain reputation
  const repScore = await verifier.getReputationScore(request.did);
  
  if (repScore < 60) throw new Error("Agent reputation below required threshold");

  // Proceed with request...
}
```

## 10. Security Considerations & Threat Model

### Known Attack Vectors and Mitigations
- **Sybil Attacks:** Mitigated by the `$CSIG` staking requirement. Creating 10,000 fake agents requires significant capital lockup, making it economically irrational.
- **Reputation Wash Trading:** Mitigated by the multi-factor algorithm. Fee activity and success rates must be corroborated by external oracles, and the Age factor prevents rapid reputation accumulation.
- **Key Compromise:** If an agent's Ed25519 private key is exposed, the attacker can impersonate the agent. *Mitigation:* The operator can call `updateStatus(Suspended)` via the Identity Registry using their Ethereum wallet, immediately invalidating the DID resolution.

### Key Management Best Practices for AI Agents
- Agents should never hold the private keys to the operator's Ethereum wallet (which controls the stake).
- The Ed25519 identity key should be injected into the agent's runtime environment via secure secrets management (e.g., HashiCorp Vault) and never hardcoded.
- Implement automated key rotation policies using the `registerCredential` function to issue temporary delegated keys.

## 11. Roadmap & Open Questions

### Phased Build-Out Plan
- **Phase 1: Core Protocol (Q3 2026)**
  - Deploy Identity, Reputation, and Staking registries to Ethereum Sepolia testnet.
  - Release v1.0 of `@countersig/protocol-sdk`.
- **Phase 2: Oracle Network (Q4 2026)**
  - Deploy the decentralized oracle network for reputation aggregation.
  - Implement external trust integrations (SAID, Gitcoin).
- **Phase 3: Mainnet Launch (Q1 2027)**
  - Complete Tier-1 security audits.
  - Mainnet deployment and Token Generation Event (TGE) for `$CSIG`.
- **Phase 4: Cross-Chain Expansion (Q2 2027)**
  - Deploy state-mirroring contracts to Solana and Base via LayerZero.

### Open Questions & Design Decisions
- `[OPEN QUESTION]` **Slashing Adjudication:** Who has the final say on slashing? A decentralized court (like Kleros), an optimistic oracle (like UMA), or a dedicated Countersig validator set? *Tradeoff:* Speed of resolution vs. decentralization of power.
- `[OPEN QUESTION]` **Reputation Decay:** Should reputation scores decay over time if an agent is inactive? *Tradeoff:* Prevents dormant agents from resting on past laurels, but may unfairly penalize specialized agents that execute infrequently.
- `[TBD]` **ERC-8004 Alignment:** While Countersig shares the Identity/Reputation/Validation registry structure with ERC-8004, it deviates by enforcing economic staking. We must decide whether to strictly implement the ERC-8004 interface for interoperability, or define a new standard (e.g., ERC-8004-Stake) to accommodate the cryptoeconomic requirements.

---
**Document Status:** DRAFT v1.0  
**Target Audience:** Protocol Architects, Senior Smart Contract Engineers  
**Classification:** Internal Build Specification
