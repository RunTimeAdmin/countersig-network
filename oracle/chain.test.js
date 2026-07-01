'use strict';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const chain = require('./chain');

const CFG = {
  rpcUrl: 'http://fake',
  privateKey: '0x' + '1'.repeat(64),
  identityAddress: '0xIdentity',
  reputationAddress: '0xReputation',
  fromBlock: 100,
  logChunkSize: 2000, // large enough that all test fixtures fit in one chunk
};

// Minimal fakes covering only the ethers.Contract/Provider surface chain.js
// actually calls — no real network, no real ethers objects.
function makeFakeProvider(latestBlock) {
  return { getBlockNumber: async () => latestBlock };
}

function makeFakeIdentityContract({ events = [], identities = {} } = {}) {
  return {
    filters: { AgentRegistered: () => 'AgentRegistered-filter' },
    queryFilter: async (_filter, start, end) =>
      events.filter(e => e.blockNumber >= start && e.blockNumber <= end),
    getIdentity: async didHash => {
      const id = identities[didHash];
      if (!id) throw new Error(`no fake identity configured for ${didHash}`);
      return id;
    },
  };
}

function makeFakeReputationContract({ pending = {}, challengeWindow = 3600 } = {}) {
  const calls = { proposeReputation: [], finalizeReputation: [] };
  const fakeTx = hash => ({ hash, wait: async () => ({}) });
  return {
    calls,
    proposeReputation: async (didHash, data) => {
      calls.proposeReputation.push({ didHash, data });
      return fakeTx('0xproposeTxHash');
    },
    finalizeReputation: async didHash => {
      calls.finalizeReputation.push({ didHash });
      return fakeTx('0xfinalizeTxHash');
    },
    getPendingScore: async didHash =>
      pending[didHash] ?? { exists: false, proposedAt: 0n, data: {} },
    challengeWindow: async () => BigInt(challengeWindow),
  };
}

beforeEach(() => {
  chain.reset();
});

// -------------------------------------------------------------------------
// getRegisteredAgents / pruneAgent
// -------------------------------------------------------------------------

test('getRegisteredAgents: returns agents registered since fromBlock', async () => {
  const events = [
    { blockNumber: 105, args: { didHash: '0xaaa', agentAddress: '0xAgentA' } },
    { blockNumber: 110, args: { didHash: '0xbbb', agentAddress: '0xAgentB' } },
  ];
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract({ events }),
    reputationContract: makeFakeReputationContract(),
  });

  const agents = await chain.getRegisteredAgents();

  assert.equal(agents.length, 2);
  assert.deepEqual(agents.map(a => a.didHash).sort(), ['0xaaa', '0xbbb']);
});

test('getRegisteredAgents: second call only scans new blocks but keeps prior agents', async () => {
  const firstBatch = [{ blockNumber: 105, args: { didHash: '0xaaa', agentAddress: '0xAgentA' } }];
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract({ events: firstBatch }),
    reputationContract: makeFakeReputationContract(),
  });
  const firstAgents = await chain.getRegisteredAgents();
  assert.equal(firstAgents.length, 1);

  // Simulate a new agent registered in a later block, and the chain having advanced.
  const secondBatchContract = makeFakeIdentityContract({
    events: [{ blockNumber: 150, args: { didHash: '0xbbb', agentAddress: '0xAgentB' } }],
  });
  chain.init(CFG, {
    provider: makeFakeProvider(160),
    identityContract: secondBatchContract,
    reputationContract: makeFakeReputationContract(),
  });

  const secondAgents = await chain.getRegisteredAgents();
  assert.equal(secondAgents.length, 2, 'previously known agent should still be present');
  assert.deepEqual(secondAgents.map(a => a.didHash).sort(), ['0xaaa', '0xbbb']);
});

test('getRegisteredAgents: returns empty array when no agents registered', async () => {
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract({ events: [] }),
    reputationContract: makeFakeReputationContract(),
  });

  const agents = await chain.getRegisteredAgents();
  assert.deepEqual(agents, []);
});

test('pruneAgent: removes an agent from the known set', async () => {
  const events = [
    { blockNumber: 105, args: { didHash: '0xaaa', agentAddress: '0xAgentA' } },
    { blockNumber: 110, args: { didHash: '0xbbb', agentAddress: '0xAgentB' } },
  ];
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract({ events }),
    reputationContract: makeFakeReputationContract(),
  });
  await chain.getRegisteredAgents();

  chain.pruneAgent('0xaaa');

  const agents = await chain.getRegisteredAgents();
  assert.deepEqual(agents.map(a => a.didHash), ['0xbbb']);
});

// -------------------------------------------------------------------------
// getAgentInfo
// -------------------------------------------------------------------------

test('getAgentInfo: converts on-chain fields to numbers', async () => {
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract({
      identities: { '0xaaa': { registeredAt: 1_700_000_000n, status: 0n } },
    }),
    reputationContract: makeFakeReputationContract(),
  });

  const info = await chain.getAgentInfo('0xaaa');
  assert.equal(info.registeredAt, 1_700_000_000);
  assert.equal(info.status, 0);
  assert.equal(typeof info.registeredAt, 'number');
});

// -------------------------------------------------------------------------
// proposeScore / finalizeScore
// -------------------------------------------------------------------------

test('proposeScore: forwards score fields and returns tx hash', async () => {
  const repContract = makeFakeReputationContract();
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract(),
    reputationContract: repContract,
  });

  const scores = { feeScore: 10, successScore: 20, ageScore: 5, externalScore: 0, communityScore: 5, propagationScore: 0, total: 40 };
  const txHash = await chain.proposeScore('0xaaa', scores);

  assert.equal(txHash, '0xproposeTxHash');
  assert.equal(repContract.calls.proposeReputation.length, 1);
  const call = repContract.calls.proposeReputation[0];
  assert.equal(call.didHash, '0xaaa');
  assert.equal(call.data.feeScore, 10);
  assert.equal(call.data.successScore, 20);
});

test('finalizeScore: calls finalizeReputation and returns tx hash', async () => {
  const repContract = makeFakeReputationContract();
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract(),
    reputationContract: repContract,
  });

  const txHash = await chain.finalizeScore('0xaaa');

  assert.equal(txHash, '0xfinalizeTxHash');
  assert.deepEqual(repContract.calls.finalizeReputation, [{ didHash: '0xaaa' }]);
});

// -------------------------------------------------------------------------
// getPendingScore / getChallengeWindow
// -------------------------------------------------------------------------

test('getPendingScore: converts proposedAt to a number and preserves exists', async () => {
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract(),
    reputationContract: makeFakeReputationContract({
      pending: { '0xaaa': { exists: true, proposedAt: 1_700_000_000n, data: {} } },
    }),
  });

  const pending = await chain.getPendingScore('0xaaa');
  assert.equal(pending.exists, true);
  assert.equal(pending.proposedAt, 1_700_000_000);
  assert.equal(typeof pending.proposedAt, 'number');
});

test('getPendingScore: no pending proposal reports exists=false', async () => {
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract(),
    reputationContract: makeFakeReputationContract(),
  });

  const pending = await chain.getPendingScore('0xnotset');
  assert.equal(pending.exists, false);
});

test('getChallengeWindow: converts to a number', async () => {
  chain.init(CFG, {
    provider: makeFakeProvider(120),
    identityContract: makeFakeIdentityContract(),
    reputationContract: makeFakeReputationContract({ challengeWindow: 21600 }),
  });

  const window = await chain.getChallengeWindow();
  assert.equal(window, 21600);
  assert.equal(typeof window, 'number');
});
