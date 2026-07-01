'use strict';

const { ethers } = require('ethers');

const IDENTITY_ABI = [
  'event AgentRegistered(bytes32 indexed didHash, address indexed operator, address indexed agentAddress, bytes32 ed25519PubKey)',
  'function getIdentity(bytes32 didHash) view returns (tuple(address operator, address agentAddress, bytes32 ed25519PubKey, uint8 status, uint256 registeredAt))',
];

const REPUTATION_ABI = [
  'function proposeReputation(bytes32 didHash, tuple(uint8 feeScore, uint8 successScore, uint8 ageScore, uint8 externalScore, uint8 communityScore, uint8 propagationScore, uint256 lastUpdated) data)',
  'function finalizeReputation(bytes32 didHash)',
  'function getPendingScore(bytes32 didHash) view returns (tuple(tuple(uint8 feeScore, uint8 successScore, uint8 ageScore, uint8 externalScore, uint8 communityScore, uint8 propagationScore, uint256 lastUpdated) data, uint256 proposedAt, bool exists))',
  'function challengeWindow() view returns (uint256)',
];
// Note: lastUpdated in the tuple above is required by the contract's function selector
// (ABI shape), but the contract always overwrites it with block.timestamp on finalize —
// see finalizeReputation() in CountersigReputation.sol. The client-side value is discarded.

// AgentStatus enum — must match CountersigIdentity.sol
const STATUS_SLASHED = 2;

const sleep = ms => new Promise(r => setTimeout(r, ms));

let provider, wallet, identityContract, reputationContract, cfg_;
let lastScannedBlock = null;
let knownAgents = new Map(); // didHash => { didHash, agentAddress, blockNumber }

// deps lets tests inject fake provider/wallet/contracts instead of connecting
// to a real RPC. Production usage (index.js) calls init(cfg) with no deps.
function init(cfg, deps = {}) {
  cfg_ = cfg;
  provider = deps.provider ?? new ethers.JsonRpcProvider(cfg.rpcUrl);
  wallet = deps.wallet ?? new ethers.Wallet(cfg.privateKey, provider);
  identityContract = deps.identityContract ?? new ethers.Contract(cfg.identityAddress, IDENTITY_ABI, provider);
  reputationContract = deps.reputationContract ?? new ethers.Contract(cfg.reputationAddress, REPUTATION_ABI, wallet);
}

// Clears in-memory scan state — used between tests, not called in production.
function reset() {
  lastScannedBlock = null;
  knownAgents = new Map();
}

// Returns ALL agents registered so far. Only scans new blocks since the last call
// (chunking getLogs into windows of chunkSize to stay within free-tier RPC limits,
// e.g. Alchemy: 10) and accumulates them into knownAgents, so repeated epochs don't
// rescan chain history but every previously-seen agent is still rescored each epoch.
async function getRegisteredAgents() {
  const chunkSize = cfg_.logChunkSize;
  const filter = identityContract.filters.AgentRegistered();
  const latest = await provider.getBlockNumber();
  const fromBlock = lastScannedBlock !== null ? lastScannedBlock + 1 : cfg_.fromBlock;

  if (fromBlock <= latest) {
    for (let start = fromBlock; start <= latest; start += chunkSize) {
      const end = Math.min(start + chunkSize - 1, latest);
      const chunk = await identityContract.queryFilter(filter, start, end);
      for (const e of chunk) {
        knownAgents.set(e.args.didHash, {
          didHash: e.args.didHash,
          agentAddress: e.args.agentAddress,
          blockNumber: e.blockNumber,
        });
      }
      if (end < latest) await sleep(400);
    }
    lastScannedBlock = latest;
  }

  return Array.from(knownAgents.values());
}

// Removes a slashed agent from the known set. Safe because Slashed is terminal in
// CountersigIdentity and didHash is deterministic — the same address can never
// re-register, so there's no risk of losing track of an agent that could return.
function pruneAgent(didHash) {
  knownAgents.delete(didHash);
}

async function getAgentInfo(didHash) {
  const id = await identityContract.getIdentity(didHash);
  return {
    registeredAt: Number(id.registeredAt),
    status: Number(id.status),
  };
}

async function proposeScore(didHash, scores) {
  const tx = await reputationContract.proposeReputation(didHash, {
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

async function finalizeScore(didHash) {
  const tx = await reputationContract.finalizeReputation(didHash);
  await tx.wait(1);
  return tx.hash;
}

// Returns { exists, proposedAt } — proposedAt is 0 when no proposal is pending.
async function getPendingScore(didHash) {
  const pending = await reputationContract.getPendingScore(didHash);
  return { exists: pending.exists, proposedAt: Number(pending.proposedAt) };
}

async function getChallengeWindow() {
  const seconds = await reputationContract.challengeWindow();
  return Number(seconds);
}

// The contract compares against block.timestamp, so epoch decisions should use
// the chain's clock rather than the oracle host's (local skew ahead of the chain
// would trigger premature finalize attempts that just revert and waste gas).
async function getLatestBlockTimestamp() {
  const block = await provider.getBlock('latest');
  return Number(block.timestamp);
}

module.exports = {
  init,
  reset,
  getRegisteredAgents,
  getAgentInfo,
  proposeScore,
  finalizeScore,
  getPendingScore,
  getChallengeWindow,
  getLatestBlockTimestamp,
  pruneAgent,
  STATUS_SLASHED,
};
