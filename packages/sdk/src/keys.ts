import nacl from 'tweetnacl';

// Bitcoin's base58 alphabet
const B58_ALPHA = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const B58_MAP = new Map(Array.from(B58_ALPHA).map((c, i) => [c, BigInt(i)]));

export function base58Encode(bytes: Uint8Array): string {
  let n = BigInt(0);
  for (const b of bytes) {
    n = n * 256n + BigInt(b);
  }
  let result = '';
  while (n > 0n) {
    result = B58_ALPHA[Number(n % 58n)] + result;
    n = n / 58n;
  }
  for (const b of bytes) {
    if (b !== 0) break;
    result = '1' + result;
  }
  return result;
}

export function base58Decode(str: string): Uint8Array {
  let n = BigInt(0);
  for (const c of str) {
    const digit = B58_MAP.get(c);
    if (digit === undefined) throw new Error(`Invalid base58 character: '${c}'`);
    n = n * 58n + digit;
  }
  const bytes: number[] = [];
  while (n > 0n) {
    bytes.push(Number(n % 256n));
    n = n / 256n;
  }
  bytes.reverse();
  let leadingZeros = 0;
  for (const c of str) {
    if (c !== '1') break;
    leadingZeros++;
  }
  const out = new Uint8Array(leadingZeros + bytes.length);
  out.set(bytes, leadingZeros);
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (h.length % 2 !== 0) throw new Error('Hex string must have even length');
  const bytes = new Uint8Array(h.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

export function seedToKeyPair(seed: string | Uint8Array): { publicKey: Uint8Array; secretKey: Uint8Array } {
  let seedBytes: Uint8Array;
  if (typeof seed === 'string') {
    const hex = seed.startsWith('0x') ? seed.slice(2) : seed;
    if (hex.length !== 64) throw new Error('Ed25519 seed must be 32 bytes (64 hex chars)');
    seedBytes = hexToBytes(hex);
  } else {
    if (seed.length !== 32) throw new Error('Ed25519 seed must be 32 bytes');
    seedBytes = seed;
  }
  return nacl.sign.keyPair.fromSeed(seedBytes);
}

// Returns the raw 32-byte public key as a bytes32 hex string (0x-prefixed) for on-chain use.
export function pubKeyToBytes32(pubKey: Uint8Array): string {
  if (pubKey.length !== 32) throw new Error('Ed25519 public key must be 32 bytes');
  return '0x' + bytesToHex(pubKey);
}

export function bytes32ToPubKey(bytes32: string): Uint8Array {
  const hex = bytes32.startsWith('0x') ? bytes32.slice(2) : bytes32;
  if (hex.length !== 64) throw new Error('bytes32 must be 64 hex chars');
  return hexToBytes(hex);
}

// Multibase encoding: z-prefix + base58btc, as required for W3C DID Documents.
export function pubKeyToMultibase(pubKey: Uint8Array): string {
  return 'z' + base58Encode(pubKey);
}
