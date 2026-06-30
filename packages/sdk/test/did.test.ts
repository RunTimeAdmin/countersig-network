import { describe, it, expect } from 'vitest';
import { computeDidHash, formatDid, parseDid } from '../src/did';

const AGENT = '0x0000000000000000000000000000000000000001';
const SEPOLIA = 11155111;
const MAINNET = 1;

describe('formatDid', () => {
  it('formats lowercase address', () => {
    const did = formatDid(AGENT, SEPOLIA);
    expect(did).toBe(`did:countersig:${SEPOLIA}:${AGENT}`);
  });

  it('lowercases mixed-case address', () => {
    const did = formatDid('0x0000000000000000000000000000000000000001', MAINNET);
    expect(did).toBe(`did:countersig:${MAINNET}:${AGENT}`);
  });
});

describe('parseDid', () => {
  it('parses a valid DID', () => {
    const { chainId, agentAddress } = parseDid(`did:countersig:${SEPOLIA}:${AGENT}`);
    expect(chainId).toBe(SEPOLIA);
    expect(agentAddress.toLowerCase()).toBe(AGENT);
  });

  it('throws on invalid format', () => {
    expect(() => parseDid('did:example:1:0xabc')).toThrow('Invalid did:countersig');
    expect(() => parseDid('not-a-did')).toThrow();
    expect(() => parseDid(`did:countersig:abc:${AGENT}`)).toThrow();
  });
});

describe('computeDidHash', () => {
  it('produces a 32-byte hex string', () => {
    const hash = computeDidHash(AGENT, SEPOLIA);
    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it('is deterministic', () => {
    expect(computeDidHash(AGENT, SEPOLIA)).toBe(computeDidHash(AGENT, SEPOLIA));
  });

  it('differs by chain', () => {
    expect(computeDidHash(AGENT, SEPOLIA)).not.toBe(computeDidHash(AGENT, MAINNET));
  });

  it('differs by address', () => {
    const a = '0x0000000000000000000000000000000000000001';
    const b = '0x0000000000000000000000000000000000000002';
    expect(computeDidHash(a, SEPOLIA)).not.toBe(computeDidHash(b, SEPOLIA));
  });

  it('formatDid + computeDidHash is self-consistent', () => {
    const did = formatDid(AGENT, SEPOLIA);
    const { chainId, agentAddress } = parseDid(did);
    const hash = computeDidHash(agentAddress, chainId);
    expect(hash).toBe(computeDidHash(AGENT, SEPOLIA));
  });
});
