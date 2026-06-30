import { describe, it, expect } from 'vitest';
import {
  generateChallenge,
  signChallenge,
  verifyChallenge,
  parseChallengePayload,
  isChallengeExpired,
} from '../src/challenge';
import { seedToKeyPair, base58Decode } from '../src/keys';
import nacl from 'tweetnacl';

const PEER_DID = 'did:countersig:11155111:0x0000000000000000000000000000000000000001';

describe('generateChallenge', () => {
  it('produces a well-formed payload', () => {
    const c = generateChallenge(PEER_DID);
    expect(c.payload.startsWith('COUNTERSIG-VERIFY:')).toBe(true);
    expect(c.payload).toContain(PEER_DID);
    expect(c.nonce).toMatch(/^[0-9a-f]{32}$/);
    expect(c.expiresAt).toBeGreaterThan(c.timestamp);
  });

  it('each challenge has a unique nonce', () => {
    const a = generateChallenge(PEER_DID);
    const b = generateChallenge(PEER_DID);
    expect(a.nonce).not.toBe(b.nonce);
    expect(a.payload).not.toBe(b.payload);
  });

  it('respects custom TTL', () => {
    const c = generateChallenge(PEER_DID, 60);
    expect(c.expiresAt - c.timestamp).toBe(60);
  });
});

describe('parseChallengePayload', () => {
  it('recovers the DID, nonce, and timestamp', () => {
    const { payload, nonce, timestamp } = generateChallenge(PEER_DID);
    const parsed = parseChallengePayload(payload);
    expect(parsed.did).toBe(PEER_DID);
    expect(parsed.nonce).toBe(nonce);
    expect(parsed.timestamp).toBe(timestamp);
  });

  it('throws on invalid prefix', () => {
    expect(() => parseChallengePayload('INVALID:stuff')).toThrow('Invalid challenge prefix');
  });
});

describe('signChallenge + verifyChallenge', () => {
  it('valid signature verifies', () => {
    const kp = seedToKeyPair(nacl.randomBytes(32));
    const { payload } = generateChallenge(PEER_DID);
    const sig = signChallenge(payload, kp.secretKey);
    expect(verifyChallenge(payload, sig, kp.publicKey)).toBe(true);
  });

  it('wrong key does not verify', () => {
    const kp1 = seedToKeyPair(nacl.randomBytes(32));
    const kp2 = seedToKeyPair(nacl.randomBytes(32));
    const { payload } = generateChallenge(PEER_DID);
    const sig = signChallenge(payload, kp1.secretKey);
    expect(verifyChallenge(payload, sig, kp2.publicKey)).toBe(false);
  });

  it('tampered payload does not verify', () => {
    const kp = seedToKeyPair(nacl.randomBytes(32));
    const { payload } = generateChallenge(PEER_DID);
    const sig = signChallenge(payload, kp.secretKey);
    expect(verifyChallenge(payload + 'x', sig, kp.publicKey)).toBe(false);
  });

  it('signature is 64 bytes encoded as base58', () => {
    const kp = seedToKeyPair(nacl.randomBytes(32));
    const { payload } = generateChallenge(PEER_DID);
    const sig = signChallenge(payload, kp.secretKey);
    expect(base58Decode(sig).length).toBe(64);
  });
});

describe('isChallengeExpired', () => {
  it('fresh challenge is not expired', () => {
    const { payload } = generateChallenge(PEER_DID);
    expect(isChallengeExpired(payload, 300)).toBe(false);
  });

  it('old timestamp is expired', () => {
    const oldTs = Math.floor(Date.now() / 1000) - 400;
    const payload = `COUNTERSIG-VERIFY:${PEER_DID}:abc123:${oldTs}`;
    expect(isChallengeExpired(payload, 300)).toBe(true);
  });

  it('malformed payload is expired', () => {
    expect(isChallengeExpired('garbage', 300)).toBe(true);
  });
});
