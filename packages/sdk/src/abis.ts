export const IDENTITY_ABI = [
  'function registerAgent(address agentAddress, bytes32 ed25519PubKey) returns (bytes32 didHash)',
  'function getIdentity(bytes32 didHash) view returns (tuple(address operator, address agentAddress, bytes32 ed25519PubKey, uint8 status, uint256 registeredAt))',
  'function computeDidHash(address agentAddress) view returns (bytes32)',
  'function isActive(bytes32 didHash) view returns (bool)',
  'function rotatePublicKey(bytes32 didHash, bytes32 newEd25519PubKey)',
  'function updateStatus(bytes32 didHash, uint8 newStatus)',
  'function getOperatorAgents(address operator) view returns (bytes32[])',
  'event AgentRegistered(bytes32 indexed didHash, address indexed operator, address indexed agentAddress, bytes32 ed25519PubKey)',
] as const;

export const REPUTATION_ABI = [
  'function getReputation(bytes32 didHash) view returns (tuple(uint8 feeScore, uint8 successScore, uint8 ageScore, uint8 externalScore, uint8 communityScore, uint8 propagationScore, uint256 lastUpdated))',
  'function getTotalScore(bytes32 didHash) view returns (uint8)',
  'function meetsThreshold(bytes32 didHash, uint8 threshold) view returns (bool)',
] as const;

export const STAKING_ABI = [
  'function depositStake(bytes32 didHash, uint256 amount)',
  'function withdrawStake(bytes32 didHash, uint256 amount)',
  'function getStake(bytes32 didHash) view returns (uint256)',
  'function hasMinimumStake(bytes32 didHash) view returns (bool)',
  'function minimumStake() view returns (uint256)',
] as const;
