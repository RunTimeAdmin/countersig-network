import nacl from 'tweetnacl';
import { base58Encode, base58Decode } from './keys';
import type { Challenge, ParsedChallenge } from './types';

const DEFAULT_TTL = 300;

// Challenge format: COUNTERSIG-VERIFY:{proverDid}:{nonce}:{timestamp}
// The DID may contain colons (did:countersig:1:0x...), so we parse from the right.

export function generateChallenge(proverDid: string, ttlSeconds = DEFAULT_TTL): Challenge {
  const nonce = randomHex(16);
  const timestamp = Math.floor(Date.now() / 1000);
  const payload = `COUNTERSIG-VERIFY:${proverDid}:${nonce}:${timestamp}`;
  return { payload, nonce, timestamp, expiresAt: timestamp + ttlSeconds };
}

// Returns a base58-encoded Ed25519 signature over the UTF-8 challenge payload.
export function signChallenge(payload: string, secretKey: Uint8Array): string {
  const messageBytes = new TextEncoder().encode(payload);
  const sigBytes = nacl.sign.detached(messageBytes, secretKey);
  return base58Encode(sigBytes);
}

// Verifies a base58-encoded Ed25519 signature against the challenge payload.
export function verifyChallenge(
  payload: string,
  signatureBase58: string,
  publicKey: Uint8Array
): boolean {
  const messageBytes = new TextEncoder().encode(payload);
  const sigBytes = base58Decode(signatureBase58);
  if (sigBytes.length !== 64) return false;
  return nacl.sign.detached.verify(messageBytes, sigBytes, publicKey);
}

// Parses the payload into its components. Timestamp and nonce are the last two segments;
// everything before is the DID (which contains colons internally).
export function parseChallengePayload(payload: string): ParsedChallenge {
  const prefix = 'COUNTERSIG-VERIFY:';
  if (!payload.startsWith(prefix)) throw new Error('Invalid challenge prefix');
  const body = payload.slice(prefix.length);

  const lastColon = body.lastIndexOf(':');
  if (lastColon === -1) throw new Error('Malformed challenge payload');
  const timestamp = parseInt(body.slice(lastColon + 1), 10);
  if (isNaN(timestamp)) throw new Error('Challenge payload has invalid timestamp');

  const rest = body.slice(0, lastColon);
  const secondLastColon = rest.lastIndexOf(':');
  if (secondLastColon === -1) throw new Error('Malformed challenge payload');
  const nonce = rest.slice(secondLastColon + 1);
  const did = rest.slice(0, secondLastColon);

  return { did, nonce, timestamp };
}

export function isChallengeExpired(payload: string, maxAgeSeconds = DEFAULT_TTL): boolean {
  const match = payload.match(/:(\d+)$/);
  if (!match) return true;
  const age = Math.floor(Date.now() / 1000) - parseInt(match[1], 10);
  return age > maxAgeSeconds;
}

function randomHex(bytes: number): string {
  const arr = new Uint8Array(bytes);
  if (typeof globalThis.crypto !== 'undefined' && globalThis.crypto.getRandomValues) {
    globalThis.crypto.getRandomValues(arr);
  } else {
    // Node.js fallback
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { randomBytes } = require('crypto') as typeof import('crypto');
    const buf = randomBytes(bytes);
    buf.copy(Buffer.from(arr.buffer));
  }
  return Array.from(arr)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
