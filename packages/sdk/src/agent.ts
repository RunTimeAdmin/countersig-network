import nacl from 'tweetnacl';
import { seedToKeyPair, pubKeyToBytes32, bytesToHex } from './keys';
import { formatDid, computeDidHash } from './did';
import { generateChallenge, signChallenge } from './challenge';
import type { Challenge } from './types';

export class CountersigAgent {
  private readonly keyPair: { publicKey: Uint8Array; secretKey: Uint8Array };
  private readonly _agentAddress: string;
  private readonly _chainId: number;
  private readonly _challengeTtl: number;

  constructor(options: {
    privateKey: string | Uint8Array;
    agentAddress: string;
    chainId: number;
    challengeTtlSeconds?: number;
  }) {
    this.keyPair = seedToKeyPair(options.privateKey);
    this._agentAddress = options.agentAddress.toLowerCase();
    this._chainId = options.chainId;
    this._challengeTtl = options.challengeTtlSeconds ?? 300;
  }

  /**
   * Generate a new Ed25519 keypair and return a ready-to-use agent alongside
   * the raw private key (seed) for secure storage by the caller.
   *
   * This is the recommended entry point for new agent creation. It keeps
   * tweetnacl as an internal implementation detail — callers never need to
   * import or interact with it directly.
   *
   * @example
   * const { agent, privateKey } = CountersigAgent.generate({
   *   agentAddress: '0xYourAgentAddress',
   *   chainId: 11155111,
   * });
   * // Store privateKey (hex) securely — it cannot be recovered from the agent.
   * await registerAgent(operatorWallet, agent.agentAddress, agent.publicKeyBytes32, IDENTITY_ADDRESS);
   */
  static generate(options: {
    agentAddress: string;
    chainId: number;
    challengeTtlSeconds?: number;
  }): { agent: CountersigAgent; privateKey: string } {
    const seed = nacl.randomBytes(32);
    const agent = new CountersigAgent({ ...options, privateKey: seed });
    return { agent, privateKey: '0x' + bytesToHex(seed) };
  }

  get agentAddress(): string {
    return this._agentAddress;
  }

  get did(): string {
    return formatDid(this._agentAddress, this._chainId);
  }

  get didHash(): string {
    return computeDidHash(this._agentAddress, this._chainId);
  }

  // Returns the bytes32 hex public key for on-chain registration.
  get publicKeyBytes32(): string {
    return pubKeyToBytes32(this.keyPair.publicKey);
  }

  // Generate a challenge to send to a peer agent. The challenge payload includes the
  // peer's DID — signing it proves the peer holds the corresponding private key.
  issueChallenge(peerDid: string, ttlSeconds?: number): Challenge {
    return generateChallenge(peerDid, ttlSeconds ?? this._challengeTtl);
  }

  // Sign a challenge payload received from a peer. Returns a base58-encoded signature.
  // The payload must contain this agent's DID as the prover.
  signChallenge(payload: string): string {
    return signChallenge(payload, this.keyPair.secretKey);
  }
}
