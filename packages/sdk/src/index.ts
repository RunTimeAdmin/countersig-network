export { CountersigAgent } from './agent';
export { CountersigVerifier, registerAgent } from './verifier';
export {
  generateChallenge,
  signChallenge,
  verifyChallenge,
  parseChallengePayload,
  isChallengeExpired,
} from './challenge';
export {
  computeDidHash,
  formatDid,
  parseDid,
} from './did';
export {
  base58Encode,
  base58Decode,
  hexToBytes,
  bytesToHex,
  seedToKeyPair,
  pubKeyToBytes32,
  bytes32ToPubKey,
  pubKeyToMultibase,
} from './keys';
export type {
  ContractAddresses,
  AgentIdentity,
  ReputationData,
  Challenge,
  ParsedChallenge,
  VerifierConfig,
  DidDocument,
  VerificationMethod,
} from './types';
export { AgentStatus } from './types';
