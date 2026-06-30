'use strict';

const { ethers } = require('ethers');

const IDENTITY_ABI = [
  'event AgentRegistered(bytes32 indexed didHash, address indexed operator, address indexed agentAddress, bytes32 ed25519PubKey)',
  'function getIdentity(bytes32 didHash) view returns (tuple(address operator, address agentAddress, bytes32 ed25519PubKey, uint8 status, uint256 registeredAt))',
];

const REPUTATION_ABI = [
  'function updateReputation(bytes32 didHash, tuple(uint8 feeScore, uint8 successScore, uint8 ageScore, uint8 externalScore, uint8 communityScore, uint8 propagationScore, uint256 lastUpdated) data)',
];

// AgentStatus enum — must match CountersigIdentity.sol
const STATUS_SLASHED = 2;

let provider, wallet, identityContract, reputationContract;

function init(cfg) {
  provider = new ethers.JsonRpcProvider(cfg.rpcUrl);
  wallet = new ethers.Wallet(cfg.privateKey, provider);
  identityContract = new ethers.Contract(cfg.identityAddress, IDENTITY_ABI, provider);
  reputationContract = new ethers.Contract(cfg.reputationAddress, REPUTATION_ABI, wallet);
}

// Returns all agents ever registered, with their block number for cursor tracking.
async function getRegisteredAgents(fromBlock = 0) {
  const filter = identityContract.filters.AgentRegistered();
  const events = await identityContract.queryFilter(filter, fromBlock, 'latest');
  return events.map(e => ({
    didHash: e.args.didHash,
    agentAddress: e.args.agentAddress,
    blockNumber: e.blockNumber,
  }));
}

async function getAgentInfo(didHash) {
  const id = await identityContract.getIdentity(didHash);
  return {
    registeredAt: Number(id.registeredAt),
    status: Number(id.status),
  };
}

async function writeReputation(didHash, scores) {
  const tx = await reputationContract.updateReputation(didHash, {
    feeScore:         scores.feeScore,
    successScore:     scores.successScore,
    ageScore:         scores.ageScore,
    externalScore:    scores.externalScore,
    communityScore:   scores.communityScore,
    propagationScore: scores.propagationScore,
    lastUpdated:      BigInt(Math.floor(Date.now() / 1000)),
  });
  await tx.wait(1);
  return tx.hash;
}

module.exports = { init, getRegisteredAgents, getAgentInfo, writeReputation, STATUS_SLASHED };
