import { describe, it, expect } from 'vitest';
import { CountersigVerifier } from '../src/verifier';
import { generateChallenge } from '../src/challenge';

// These cases all short-circuit inside verifySignature BEFORE any on-chain call,
// so they run without a live RPC. The dummy config is never actually dialed.
const verifier = new CountersigVerifier({
  rpcUrl: 'http://127.0.0.1:0',
  addresses: {
    identity: '0x0000000000000000000000000000000000000001',
    reputation: '0x0000000000000000000000000000000000000002',
    staking: '0x0000000000000000000000000000000000000003',
  },
  chainId: 11155111,
});

const DID_A = 'did:countersig:11155111:0x00000000000000000000000000000000000000aa';
const DID_B = 'did:countersig:11155111:0x00000000000000000000000000000000000000bb';
const SIG = '1'.repeat(64); // shape doesn't matter — rejected before verification

describe('verifySignature pre-chain guards', () => {
  it('rejects a malformed challenge payload', async () => {
    expect(await verifier.verifySignature(DID_A, 'not-a-challenge', SIG)).toBe(false);
  });

  it('rejects a challenge whose prover DID does not match', async () => {
    const c = generateChallenge(DID_A);
    expect(await verifier.verifySignature(DID_B, c.payload, SIG)).toBe(false);
  });

  it('rejects an expired challenge (replay past its TTL)', async () => {
    const staleTs = Math.floor(Date.now() / 1000) - 3600;
    const payload = `COUNTERSIG-VERIFY:${DID_A}:deadbeef:${staleTs}`;
    expect(await verifier.verifySignature(DID_A, payload, SIG, 300)).toBe(false);
  });
});
