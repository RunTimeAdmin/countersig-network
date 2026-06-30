export interface ContractAddresses {
  identity: string;
  reputation: string;
  staking: string;
}

export enum AgentStatus {
  Active = 0,
  Suspended = 1,
  Slashed = 2,
}

export interface AgentIdentity {
  operator: string;
  agentAddress: string;
  ed25519PubKey: string;
  status: AgentStatus;
  registeredAt: bigint;
}

export interface ReputationData {
  feeScore: number;
  successScore: number;
  ageScore: number;
  externalScore: number;
  communityScore: number;
  propagationScore: number;
  lastUpdated: bigint;
  total: number;
}

export interface Challenge {
  payload: string;
  nonce: string;
  timestamp: number;
  expiresAt: number;
}

export interface ParsedChallenge {
  did: string;
  nonce: string;
  timestamp: number;
}

export interface VerifierConfig {
  rpcUrl: string;
  addresses: ContractAddresses;
  chainId?: number;
}

export interface DidDocument {
  '@context': string[];
  id: string;
  controller: string;
  verificationMethod: VerificationMethod[];
  authentication: string[];
  assertionMethod: string[];
}

export interface VerificationMethod {
  id: string;
  type: string;
  controller: string;
  publicKeyMultibase: string;
}
