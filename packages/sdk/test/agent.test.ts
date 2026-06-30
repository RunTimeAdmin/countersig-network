import { describe, it, expect } from 'vitest';
import nacl from 'tweetnacl';
import { CountersigAgent } from '../src/agent';
import {
  parseChallengePayload,
  verifyChallenge,
  isChallengeExpired,
} from '../src/challenge';
import { base58Decode, bytes32ToPubKey } from '../src/keys';
import { computeDidHash, formatDid } from '../src/did';

const CHAIN_ID = 11155111;
const AGENT_ADDR = '0x0000000000000000000000000000000000001234';
const PEER_ADDR  = '0x0000000000000000000000000000000000005678';

function makeAgent(address: string = AGENT_ADDR) {
  return new CountersigAgent({
    privateKey: nacl.randomBytes(32),
    agentAddress: address,
    chainId: CHAIN_ID,
  });
}

describe('CountersigAgent — identity', () => {
  it('exposes the correct DID', () => {
    const agent = makeAgent();
    expect(agent.did).toBe(formatDid(AGENT_ADDR, CHAIN_ID));
  });

  it('exposes the correct didHash', () => {
    const agent = makeAgent();
    expect(agent.didHash).toBe(computeDidHash(AGENT_ADDR, CHAIN_ID));
  });

  it('publicKeyBytes32 is 32 bytes (0x + 64 hex chars)', () => {
    const agent = makeAgent();
    expect(agent.publicKeyBytes32).toMatch(/^0x[0-9a-f]{64}$/);
  });
});

describe('CountersigAgent — issueChallenge', () => {
  it('challenge payload contains the peer DID', () => {
    const agentB = makeAgent();
    const peerDid = formatDid(PEER_ADDR, CHAIN_ID);
    const challenge = agentB.issueChallenge(peerDid);
    expect(challenge.payload).toContain(peerDid);
  });

  it('each issued challenge has a unique nonce', () => {
    const agentB = makeAgent();
    const peerDid = formatDid(PEER_ADDR, CHAIN_ID);
    const c1 = agentB.issueChallenge(peerDid);
    const c2 = agentB.issueChallenge(peerDid);
    expect(c1.nonce).not.toBe(c2.nonce);
  });
});

describe('CountersigAgent — A2A sign/verify flow', () => {
  it('Agent A signs a challenge issued by Agent B and signature verifies', () => {
    const agentA = makeAgent(AGENT_ADDR);
    const agentB = makeAgent(PEER_ADDR);

    // B issues a challenge to A
    const challenge = agentB.issueChallenge(agentA.did);

    // A signs the challenge payload
    const signature = agentA.signChallenge(challenge.payload);

    // Signature is base58 encoded, 64 bytes
    expect(base58Decode(signature).length).toBe(64);

    // Parse the payload — the DID should be Agent A's DID
    const parsed = parseChallengePayload(challenge.payload);
    expect(parsed.did).toBe(agentA.did);

    // Reconstruct Agent A's public key from its on-chain bytes32 representation
    // (this is what the verifier would fetch from chain)
    const pubKey = bytes32ToPubKey(agentA.publicKeyBytes32);
    expect(verifyChallenge(challenge.payload, signature, pubKey)).toBe(true);
  });

  it('signature does not verify against the wrong public key', () => {
    const agentA = makeAgent(AGENT_ADDR);
    const agentB = makeAgent(PEER_ADDR);
    const agentC = makeAgent('0x0000000000000000000000000000000000009999');

    const challenge = agentB.issueChallenge(agentA.did);
    const signature = agentA.signChallenge(challenge.payload);

    const wrongPubKey = bytes32ToPubKey(agentC.publicKeyBytes32);
    expect(verifyChallenge(challenge.payload, signature, wrongPubKey)).toBe(false);
  });

  it('issued challenge is not yet expired', () => {
    const agentB = makeAgent();
    const challenge = agentB.issueChallenge(formatDid(PEER_ADDR, CHAIN_ID));
    expect(isChallengeExpired(challenge.payload)).toBe(false);
  });

  it('deterministic keypair produces the same public key each time', () => {
    const seed = nacl.randomBytes(32);
    const a1 = new CountersigAgent({ privateKey: seed, agentAddress: AGENT_ADDR, chainId: CHAIN_ID });
    const a2 = new CountersigAgent({ privateKey: seed, agentAddress: AGENT_ADDR, chainId: CHAIN_ID });
    expect(a1.publicKeyBytes32).toBe(a2.publicKeyBytes32);
  });
});
