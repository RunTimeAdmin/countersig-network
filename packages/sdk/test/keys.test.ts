import { describe, it, expect } from 'vitest';
import nacl from 'tweetnacl';
import {
  base58Encode,
  base58Decode,
  hexToBytes,
  bytesToHex,
  seedToKeyPair,
  pubKeyToBytes32,
  bytes32ToPubKey,
  pubKeyToMultibase,
} from '../src/keys';

describe('base58', () => {
  it('round-trips arbitrary bytes', () => {
    const cases: Uint8Array[] = [
      new Uint8Array([0]),
      new Uint8Array([0, 0, 255]),
      new Uint8Array(32).fill(0xab),
      new Uint8Array(64).fill(0xff),
      nacl.randomBytes(64),
    ];
    for (const bytes of cases) {
      expect(base58Decode(base58Encode(bytes))).toEqual(bytes);
    }
  });

  it('encodes known vectors', () => {
    expect(base58Encode(new Uint8Array([0]))).toBe('1');
    expect(base58Encode(new Uint8Array([0, 1]))).toBe('12');
    expect(base58Encode(new Uint8Array([255]))).toBe('5Q');
  });

  it('throws on invalid base58 character', () => {
    expect(() => base58Decode('0OIl')).toThrow('Invalid base58 character');
  });
});

describe('hex encoding', () => {
  it('round-trips', () => {
    const bytes = nacl.randomBytes(32);
    expect(hexToBytes(bytesToHex(bytes))).toEqual(bytes);
  });

  it('handles 0x prefix', () => {
    expect(hexToBytes('0x0102')).toEqual(new Uint8Array([1, 2]));
  });

  it('throws on odd-length hex', () => {
    expect(() => hexToBytes('abc')).toThrow();
  });
});

describe('seedToKeyPair', () => {
  it('derives consistent keypair from hex seed', () => {
    const seed = '0x' + 'ab'.repeat(32);
    const kp1 = seedToKeyPair(seed);
    const kp2 = seedToKeyPair(seed);
    expect(kp1.publicKey).toEqual(kp2.publicKey);
    expect(kp1.secretKey).toEqual(kp2.secretKey);
  });

  it('derives consistent keypair from Uint8Array seed', () => {
    const seed = nacl.randomBytes(32);
    const kp1 = seedToKeyPair(seed);
    const kp2 = seedToKeyPair(seed);
    expect(kp1.publicKey).toEqual(kp2.publicKey);
  });

  it('different seeds produce different keypairs', () => {
    const kp1 = seedToKeyPair(nacl.randomBytes(32));
    const kp2 = seedToKeyPair(nacl.randomBytes(32));
    expect(kp1.publicKey).not.toEqual(kp2.publicKey);
  });

  it('throws on 31-byte seed', () => {
    expect(() => seedToKeyPair(new Uint8Array(31))).toThrow('32 bytes');
  });

  it('throws on wrong-length hex seed', () => {
    expect(() => seedToKeyPair('ab'.repeat(31))).toThrow('64 hex chars');
  });
});

describe('pubKey encoding', () => {
  it('bytes32 round-trips through Uint8Array', () => {
    const kp = seedToKeyPair(nacl.randomBytes(32));
    const bytes32 = pubKeyToBytes32(kp.publicKey);
    expect(bytes32).toMatch(/^0x[0-9a-f]{64}$/);
    expect(bytes32ToPubKey(bytes32)).toEqual(kp.publicKey);
  });

  it('multibase has z prefix', () => {
    const kp = seedToKeyPair(nacl.randomBytes(32));
    const mb = pubKeyToMultibase(kp.publicKey);
    expect(mb.startsWith('z')).toBe(true);
    // z-prefix is stripped before base58 decode
    expect(base58Decode(mb.slice(1))).toEqual(kp.publicKey);
  });
});
