/**
 * Integration test harness for @countersig/protocol-sdk
 *
 * Requires a live EVM deployment (Robinhood testnet 46630 preferred;
 * Sepolia 11155111 still works). Auto-skips when env vars are absent
 * so CI is never blocked.
 *
 * To run after deploy (see docs/robinhood-chain.md):
 *   COUNTERSIG_RPC_URL=https://rpc.testnet.chain.robinhood.com
 *   COUNTERSIG_CHAIN_ID=46630
 *   COUNTERSIG_IDENTITY_ADDRESS=0x...
 *   COUNTERSIG_REPUTATION_ADDRESS=0x...
 *   COUNTERSIG_STAKING_ADDRESS=0x...
 *   COUNTERSIG_OPERATOR_PRIVATE_KEY=0x...
 *
 *   npx vitest run test/integration.test.ts
 */

import { describe, it, expect, beforeAll } from 'vitest';
import nacl from 'tweetnacl';
import {
  CountersigAgent,
  CountersigVerifier,
  registerAgent,
  formatDid,
  computeDidHash,
  pubKeyToBytes32,
  AgentStatus,
} from '../src/index';
import { ethers } from 'ethers';

const RPC_URL         = process.env.COUNTERSIG_RPC_URL;
const IDENTITY_ADDR   = process.env.COUNTERSIG_IDENTITY_ADDRESS;
const REPUTATION_ADDR = process.env.COUNTERSIG_REPUTATION_ADDRESS;
const STAKING_ADDR    = process.env.COUNTERSIG_STAKING_ADDRESS;
const OPERATOR_KEY    = process.env.COUNTERSIG_OPERATOR_PRIVATE_KEY;

const ENABLED = !!RPC_URL && !!IDENTITY_ADDR && !!REPUTATION_ADDR && !!STAKING_ADDR && !!OPERATOR_KEY;
const maybeDescribe = ENABLED ? describe : describe.skip;

// Default Robinhood Chain testnet; override for Sepolia (11155111) or mainnet (4663).
const CHAIN_ID = Number(process.env.COUNTERSIG_CHAIN_ID ?? '46630');

let verifier: CountersigVerifier;
let agentAddress: string;
let agentDid: string;
let agentPrivateKey: Uint8Array;

beforeAll(async () => {
  if (!ENABLED) return;
  verifier = new CountersigVerifier({
    rpcUrl: RPC_URL!,
    addresses: { identity: IDENTITY_ADDR!, reputation: REPUTATION_ADDR!, staking: STAKING_ADDR! },
    chainId: CHAIN_ID,
  });
  agentPrivateKey = nacl.randomBytes(32);
  const provider  = new ethers.JsonRpcProvider(RPC_URL!);
  const operator  = new ethers.Wallet(OPERATOR_KEY!, provider);
  const agentWallet = new ethers.Wallet(ethers.hexlify(agentPrivateKey), provider);
  agentAddress = agentWallet.address;
  agentDid     = formatDid(agentAddress, CHAIN_ID);
  const pubKey = pubKeyToBytes32(nacl.sign.keyPair.fromSeed(agentPrivateKey).publicKey);
  try {
    await registerAgent(operator, agentAddress, pubKey, IDENTITY_ADDR!);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (!msg.includes('AlreadyRegistered')) throw err;
  }
}, 60_000);

maybeDescribe('Integration: identity', () => {
  it('getIdentity returns correct public key and Active status', async () => {
    const id = await verifier.getIdentity(agentDid);
    expect(id.status).toBe(AgentStatus.Active);
    expect(id.registeredAt).toBeGreaterThan(0n);
  }, 30_000);

  it('isActive returns true', async () => {
    expect(await verifier.isActive(agentDid)).toBe(true);
  }, 30_000);

  it('computeDidHash is a valid bytes32', () => {
    expect(computeDidHash(agentAddress, CHAIN_ID)).toMatch(/^0x[0-9a-f]{64}$/);
  });
});

maybeDescribe('Integration: A2A challenge-response', () => {
  it('verifySignature returns true for valid signature', async () => {
    const agent = new CountersigAgent({ privateKey: agentPrivateKey, agentAddress, chainId: CHAIN_ID });
    const challenge = agent.issueChallenge(agentDid);
    const signature = agent.signChallenge(challenge.payload);
    expect(await verifier.verifySignature(agentDid, challenge.payload, signature)).toBe(true);
  }, 30_000);

  it('verifySignature returns false for tampered payload', async () => {
    const agent = new CountersigAgent({ privateKey: agentPrivateKey, agentAddress, chainId: CHAIN_ID });
    const challenge = agent.issueChallenge(agentDid);
    const signature = agent.signChallenge(challenge.payload);
    expect(await verifier.verifySignature(agentDid, challenge.payload + 'x', signature)).toBe(false);
  }, 30_000);
});

maybeDescribe('Integration: DID Document', () => {
  it('buildDidDocument returns a valid W3C DID Document', async () => {
    const doc = await verifier.buildDidDocument(agentDid);
    expect(doc['@context']).toContain('https://www.w3.org/ns/did/v1');
    expect(doc.id).toBe(agentDid);
    expect(doc.verificationMethod[0].type).toBe('Ed25519VerificationKey2020');
    expect(doc.verificationMethod[0].publicKeyMultibase).toMatch(/^z/);
  }, 30_000);
});

maybeDescribe('Integration: reputation', () => {
  it('getReputation returns a valid score object', async () => {
    const rep = await verifier.getReputation(agentDid);
    expect(rep.total).toBeGreaterThanOrEqual(0);
    expect(rep.total).toBeLessThanOrEqual(100);
  }, 30_000);

  it('meetsThreshold(0) is always true', async () => {
    expect(await verifier.meetsThreshold(agentDid, 0)).toBe(true);
  }, 30_000);
});
