import { ethers } from 'ethers';
import { IDENTITY_ABI, REPUTATION_ABI, STAKING_ABI } from './abis';
import { parseDid, computeDidHash } from './did';
import { verifyChallenge, parseChallengePayload, isChallengeExpired } from './challenge';
import { bytes32ToPubKey, pubKeyToMultibase } from './keys';
import type {
  VerifierConfig,
  AgentIdentity,
  AgentStatus,
  ReputationData,
  DidDocument,
  ContractAddresses,
} from './types';

export class CountersigVerifier {
  private readonly provider: ethers.JsonRpcProvider;
  private readonly addresses: ContractAddresses;
  private _chainId: number | undefined;

  // Cached lazily — avoids re-parsing the ABI on every call.
  private _identity?: ethers.Contract;
  private _reputation?: ethers.Contract;
  private _staking?: ethers.Contract;

  constructor(config: VerifierConfig) {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.addresses = config.addresses;
    this._chainId = config.chainId;
  }

  private identity() {
    return (this._identity ??= new ethers.Contract(this.addresses.identity, IDENTITY_ABI, this.provider));
  }

  private reputation() {
    return (this._reputation ??= new ethers.Contract(this.addresses.reputation, REPUTATION_ABI, this.provider));
  }

  private staking() {
    return (this._staking ??= new ethers.Contract(this.addresses.staking, STAKING_ABI, this.provider));
  }

  private async chainId(): Promise<number> {
    if (this._chainId !== undefined) return this._chainId;
    const network = await this.provider.getNetwork();
    this._chainId = Number(network.chainId);
    return this._chainId;
  }

  private async didHashFromDid(did: string): Promise<string> {
    const { chainId, agentAddress } = parseDid(did);
    return computeDidHash(agentAddress, chainId);
  }

  async getIdentity(did: string): Promise<AgentIdentity> {
    const didHash = await this.didHashFromDid(did);
    const raw = await this.identity().getIdentity(didHash);
    return {
      operator: raw.operator,
      agentAddress: raw.agentAddress,
      ed25519PubKey: raw.ed25519PubKey,
      status: Number(raw.status) as AgentStatus,
      registeredAt: BigInt(raw.registeredAt),
    };
  }

  async isActive(did: string): Promise<boolean> {
    const didHash = await this.didHashFromDid(did);
    return this.identity().isActive(didHash) as Promise<boolean>;
  }

  async getReputation(did: string): Promise<ReputationData> {
    const didHash = await this.didHashFromDid(did);
    const [raw, total] = await Promise.all([
      this.reputation().getReputation(didHash),
      this.reputation().getTotalScore(didHash),
    ]);
    return {
      feeScore: Number(raw.feeScore),
      successScore: Number(raw.successScore),
      ageScore: Number(raw.ageScore),
      externalScore: Number(raw.externalScore),
      communityScore: Number(raw.communityScore),
      propagationScore: Number(raw.propagationScore),
      lastUpdated: BigInt(raw.lastUpdated),
      total: Number(total),
    };
  }

  async meetsThreshold(did: string, threshold: number): Promise<boolean> {
    const didHash = await this.didHashFromDid(did);
    return this.reputation().meetsThreshold(didHash, threshold) as Promise<boolean>;
  }

  async getStake(did: string): Promise<bigint> {
    const didHash = await this.didHashFromDid(did);
    return this.staking().getStake(didHash) as Promise<bigint>;
  }

  async hasMinimumStake(did: string): Promise<boolean> {
    const didHash = await this.didHashFromDid(did);
    return this.staking().hasMinimumStake(didHash) as Promise<boolean>;
  }

  // Resolve the agent's Ed25519 public key from chain and verify the signature.
  //
  // Besides the cryptographic check, this binds the challenge to `did` and rejects
  // stale challenges so a captured (payload, signature) pair can't be replayed after
  // it expires. Nonce uniqueness within the freshness window is still the caller's
  // responsibility — track consumed nonces if you need strict single-use semantics.
  async verifySignature(
    did: string,
    challengePayload: string,
    signatureBase58: string,
    maxAgeSeconds = 300
  ): Promise<boolean> {
    // The payload must name this DID as the prover, otherwise a signature made for a
    // different challenge/DID could be presented against this one.
    let parsed;
    try {
      parsed = parseChallengePayload(challengePayload);
    } catch {
      return false;
    }
    if (parsed.did !== did) return false;
    if (isChallengeExpired(challengePayload, maxAgeSeconds)) return false;

    const identity = await this.getIdentity(did);
    if (identity.registeredAt === 0n) return false;
    if (identity.ed25519PubKey === ethers.ZeroHash) return false;
    const pubKey = bytes32ToPubKey(identity.ed25519PubKey);
    return verifyChallenge(challengePayload, signatureBase58, pubKey);
  }

  async buildDidDocument(did: string): Promise<DidDocument> {
    const identity = await this.getIdentity(did);
    const { agentAddress } = parseDid(did);
    const pubKey = bytes32ToPubKey(identity.ed25519PubKey);
    const keyId = `${did}#key-1`;
    return {
      '@context': [
        'https://www.w3.org/ns/did/v1',
        'https://w3id.org/security/suites/ed25519-2020/v1',
      ],
      id: did,
      controller: `did:pkh:eip155:${(await this.chainId())}:${identity.operator}`,
      verificationMethod: [
        {
          id: keyId,
          type: 'Ed25519VerificationKey2020',
          controller: did,
          publicKeyMultibase: pubKeyToMultibase(pubKey),
        },
      ],
      authentication: [keyId],
      assertionMethod: [keyId],
    };
  }
}

// Standalone helper: operator registers an agent on-chain.
export async function registerAgent(
  signer: ethers.Signer,
  agentAddress: string,
  ed25519PubKeyBytes32: string,
  identityAddress: string
): Promise<{ didHash: string; txHash: string }> {
  const contract = new ethers.Contract(identityAddress, IDENTITY_ABI, signer);
  const tx = await contract.registerAgent(agentAddress, ed25519PubKeyBytes32);
  const receipt = await tx.wait();
  const iface = new ethers.Interface(IDENTITY_ABI);
  let didHash = '';
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: log.topics, data: log.data });
      if (parsed && parsed.name === 'AgentRegistered') {
        didHash = parsed.args.didHash;
        break;
      }
    } catch {
      // not this event
    }
  }
  return { didHash, txHash: receipt.hash };
}
