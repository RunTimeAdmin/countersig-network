'use strict';

const { ethers } = require('ethers');

const IDENTITY_ABI = [
  'event AgentRegistered(bytes32 indexed didHash, address indexed operator, address indexed agentAddress, bytes32 ed25519PubKey)',
  'function getIdentity(bytes32 didHash) view returns (tuple(address operator, address agentAddress, bytes32 ed25519PubKey, uint8 status, uint256 registeredAt))',
];

const REPUTATION_ABI = [
  'function updateReputation(bytes32 didHash, tuple(uint8 feeScore, uint8 successScore, uint8 ageScore, uint8 externalScore, uint8 communityScore, uint8 propagationScore, uint256 lastUpdated) data)',
];
// Note: lastUpdated in the tuple above is required by the contract's function selector
// (ABI shape), but the contract always overwrites it with block.timestamp on write —
// see updateReputation() in CountersigReputation.sol. The client-side value is discarded.

// AgentStatus enum — must match CountersigIdentity.sol
const STATUS_SLASHED = 2;

let provider, wallet, identityContract, reputationContract, cfg_;
let lastScannedBlock = null;
const knownAgents = new Map(); // didHash => { didHash, agentAddress, blockNumber }

function init(cfg) {
  cfg_ = cfg;
  provider = new ethers.JsonRpcProvider(cfg.rpcUrl);
  wallet = new ethers.Wallet(cfg.privateKey, provider);
  identityContract = new ethers.Contract(cfg.identityAddress, IDENTITY_ABI, provider);
  reputationContract = new ethers.Contract(cfg.reputationAddress, REPUTATION_ABI, wallet);
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
    const sleep = ms => new Promise(r => setTimeout(r, ms));
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
