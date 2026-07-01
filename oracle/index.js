'use strict';

require('dotenv').config();

const http = require('http');
const chain = require('./chain');
const { computeScore } = require('./scoring');

// ---- Config ----------------------------------------------------------------

const cfg = {
  rpcUrl:            process.env.RPC_URL            || '',
  privateKey:        process.env.ORACLE_PRIVATE_KEY || '',
  identityAddress:   process.env.IDENTITY_ADDRESS   || '',
  reputationAddress: process.env.REPUTATION_ADDRESS || '',
  epochMs:           Number(process.env.EPOCH_HOURS || 24) * 3_600_000,
  port:              Number(process.env.PORT || 3030),
  fromBlock:         Number(process.env.FROM_BLOCK  || 0),
  logChunkSize:      Number(process.env.LOG_CHUNK_SIZE || 2000),
  adminToken:        process.env.ORACLE_ADMIN_TOKEN || '',
};

if (!cfg.rpcUrl || !cfg.privateKey || !cfg.identityAddress || !cfg.reputationAddress) {
  console.error('[oracle] Missing required env vars. Copy .env.example to .env and fill it in.');
  process.exit(1);
}

chain.init(cfg);

// ---- In-memory state -------------------------------------------------------
// Production would use Postgres or SQLite. For testnet, memory is fine — the
// epoch recomputes everything from on-chain data on restart anyway.

// didHash → { successful: number, total: number }
const attestations = new Map();
// didHash → number (unresolved flag count)
const flags = new Map();

// ---- Epoch -----------------------------------------------------------------

// Guards against overlapping epochs from the setInterval tick and the manual
// /epoch endpoint firing at the same time, which would submit tx's with colliding
// nonces from the shared oracle wallet.
let epochRunning = false;

async function runEpoch() {
  if (epochRunning) {
    console.log('[oracle] epoch already running, skipping this trigger');
    return;
  }
  epochRunning = true;

  try {
    await runEpochInner();
  } finally {
    epochRunning = false;
  }
}

async function runEpochInner() {
  const start = Date.now();
  console.log(`[oracle] epoch start — ${new Date().toISOString()}`);

  let agents;
  try {
    agents = await chain.getRegisteredAgents();
  } catch (err) {
    console.error('[oracle] could not fetch registered agents:', err.message);
    return;
  }

  console.log(`[oracle] ${agents.length} agent(s) found`);
  let updated = 0;

  // Phase 1: reads are stateless — fire them concurrently instead of one at a time.
  const agentInfos = await Promise.all(
    agents.map(async ({ didHash }) => {
      try {
        const info = await chain.getAgentInfo(didHash);
        return { didHash, ...info, error: null };
      } catch (err) {
        return { didHash, registeredAt: 0, status: -1, error: err };
      }
    })
  );

  // Phase 2: writes share the oracle wallet's nonce, so they stay sequential.
  for (const { didHash, registeredAt, status, error } of agentInfos) {
    if (error) {
      console.error(`[oracle]   ${didHash.slice(0, 10)}… error: ${error.message}`);
      continue;
    }
    try {
      // Slashed agents are terminal — their score was zeroed by CountersigStaking.
      if (status === chain.STATUS_SLASHED) {
        chain.pruneAgent(didHash);
        continue;
      }

      const att       = attestations.get(didHash) ?? { successful: 0, total: 0 };
      const flagCount = flags.get(didHash) ?? 0;
      const scores    = computeScore({ registeredAt, attestations: att, flags: flagCount });
      const txHash    = await chain.writeReputation(didHash, scores);

      console.log(`[oracle]   ${didHash.slice(0, 10)}… score=${scores.total}/100 tx=${txHash.slice(0, 10)}…`);
      updated++;
    } catch (err) {
      console.error(`[oracle]   ${didHash.slice(0, 10)}… error: ${err.message}`);
    }
  }

  console.log(`[oracle] epoch done — ${updated} updated in ${Date.now() - start}ms`);
}

// ---- HTTP API --------------------------------------------------------------

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

async function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY_SIZE) {
        req.destroy();
        return reject(new Error('Request body too large'));
      }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString() || '{}')); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

function isAuthorized(req) {
  if (!cfg.adminToken) return true; // auth disabled if no token configured
  const header = req.headers['authorization'] || '';
  return header === `Bearer ${cfg.adminToken}`;
}

const SCORE_PATH_RE = /^\/score\/(0x[0-9a-fA-F]{64})$/;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${cfg.port}`);
  const { pathname } = url;

  // GET /health
  if (req.method === 'GET' && pathname === '/health') {
    return json(res, 200, { ok: true, epochMs: cfg.epochMs });
  }

  // POST /epoch  — trigger a manual run (useful for testing)
  if (req.method === 'POST' && pathname === '/epoch') {
    if (epochRunning) return json(res, 409, { error: 'Epoch already running' });
    runEpoch().catch(err => console.error('[oracle] manual epoch error:', err.message));
    return json(res, 202, { message: 'Epoch started' });
  }

  // POST /attest  — body: { didHash, success }
  if (req.method === 'POST' && pathname === '/attest') {
    if (!isAuthorized(req)) return json(res, 401, { error: 'Unauthorized' });
    try {
      const { didHash, success } = await readBody(req);
      if (!didHash) return json(res, 400, { error: 'didHash required' });
      const att = attestations.get(didHash) ?? { successful: 0, total: 0 };
      att.total++;
      if (success) att.successful++;
      attestations.set(didHash, att);
      return json(res, 200, { didHash, ...att });
    } catch (err) {
      return json(res, 400, { error: err.message });
    }
  }

  // POST /flag  — body: { didHash }
  if (req.method === 'POST' && pathname === '/flag') {
    if (!isAuthorized(req)) return json(res, 401, { error: 'Unauthorized' });
    try {
      const { didHash } = await readBody(req);
      if (!didHash) return json(res, 400, { error: 'didHash required' });
      flags.set(didHash, (flags.get(didHash) ?? 0) + 1);
      return json(res, 200, { didHash, flags: flags.get(didHash) });
    } catch (err) {
      return json(res, 400, { error: err.message });
    }
  }

  // GET /score/:didHash  — preview computed score without writing to chain
  const scoreMatch = pathname.match(SCORE_PATH_RE);
  if (req.method === 'GET' && scoreMatch) {
    const didHash = scoreMatch[1];
    try {
      const { registeredAt, status } = await chain.getAgentInfo(didHash);
      const att       = attestations.get(didHash) ?? { successful: 0, total: 0 };
      const flagCount = flags.get(didHash) ?? 0;
      const scores    = computeScore({ registeredAt, attestations: att, flags: flagCount });
      return json(res, 200, { didHash, status, scores, attestations: att, flags: flagCount });
    } catch (err) {
      return json(res, 500, { error: err.message });
    }
  }

  return json(res, 404, { error: 'Not found' });
});

server.listen(cfg.port, () => {
  console.log(`[oracle] HTTP on :${cfg.port}  epoch every ${cfg.epochMs / 3_600_000}h`);
  runEpoch();
  setInterval(runEpoch, cfg.epochMs);
});
