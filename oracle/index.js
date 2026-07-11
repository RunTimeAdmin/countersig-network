'use strict';

require('dotenv').config();

const http = require('http');
const chain = require('./chain');
const { computeScore } = require('./scoring');
const { decideAction } = require('./epoch-policy');
const { json, readBody, isAuthorized, parseScorePath, rateLimited } = require('./http-helpers');

// Per-client key for rate limiting. Behind the container's 127.0.0.1 port map all
// requests may share one source IP, so this degrades to a global cap — still a
// useful flood guard for the write endpoints.
const clientKey = req => req.socket?.remoteAddress || 'unknown';

// ---- Config ----------------------------------------------------------------

const cfg = {
  rpcUrl:            process.env.RPC_URL            || '',
  privateKey:        process.env.ORACLE_PRIVATE_KEY || '',
  identityAddress:   process.env.IDENTITY_ADDRESS   || '',
  reputationAddress: process.env.REPUTATION_ADDRESS || '',
  epochMs:           Number(process.env.EPOCH_HOURS || 24) * 3_600_000,
  host:              process.env.HOST || '127.0.0.1',
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
  let proposed = 0;
  let finalized = 0;

  const challengeWindow = await chain.getChallengeWindow();
  // Use the chain's clock for window math, not the local one — the contract
  // compares against block.timestamp. Fetched once per epoch; going slightly
  // stale during a long epoch only errs toward 'skip', never toward a
  // premature finalize that would revert.
  const chainNow = await chain.getLatestBlockTimestamp();

  // Phase 1: reads are stateless — fire them concurrently instead of one at a time.
  const agentInfos = await Promise.all(
    agents.map(async ({ didHash }) => {
      try {
        const [info, pending] = await Promise.all([
          chain.getAgentInfo(didHash),
          chain.getPendingScore(didHash),
        ]);
        return { didHash, ...info, pending, error: null };
      } catch (err) {
        return { didHash, registeredAt: 0, status: -1, pending: null, error: err };
      }
    })
  );

  // Phase 2: writes share the oracle wallet's nonce, so they stay sequential.
  for (const { didHash, registeredAt, status, pending, error } of agentInfos) {
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

      const action = decideAction(pending, challengeWindow, chainNow);

      if (action === 'skip') {
        console.log(`[oracle]   ${didHash.slice(0, 10)}… score still pending, waiting out challenge window`);
        continue;
      }

      if (action === 'finalize-then-propose') {
        try {
          const finalizeTx = await chain.finalizeScore(didHash);
          console.log(`[oracle]   ${didHash.slice(0, 10)}… finalized tx=${finalizeTx.slice(0, 10)}…`);
          finalized++;
        } catch (finalizeErr) {
          // finalizeReputation is permissionless, so another party can front-run
          // us. If the pending proposal is gone, that's exactly what happened —
          // the score is live, carry on and propose fresh. Anything else is a
          // real failure and should skip this agent via the outer catch.
          const still = await chain.getPendingScore(didHash);
          if (still.exists) throw finalizeErr;
          console.log(`[oracle]   ${didHash.slice(0, 10)}… already finalized by another party`);
        }
      }

      const att       = attestations.get(didHash) ?? { successful: 0, total: 0 };
      const flagCount = flags.get(didHash) ?? 0;
      const scores    = computeScore({ registeredAt, attestations: att, flags: flagCount });
      const txHash    = await chain.proposeScore(didHash, scores);

      console.log(`[oracle]   ${didHash.slice(0, 10)}… proposed score=${scores.total}/100 tx=${txHash.slice(0, 10)}…`);
      proposed++;
    } catch (err) {
      console.error(`[oracle]   ${didHash.slice(0, 10)}… error: ${err.message}`);
    }
  }

  console.log(`[oracle] epoch done — ${proposed} proposed, ${finalized} finalized in ${Date.now() - start}ms`);
}

// ---- HTTP API --------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${cfg.port}`);
  const { pathname } = url;

  // GET /health
  if (req.method === 'GET' && pathname === '/health') {
    return json(res, 200, { ok: true, epochMs: cfg.epochMs });
  }

  // POST /epoch  — trigger a manual run (useful for testing)
  if (req.method === 'POST' && pathname === '/epoch') {
    // Gated: a manual epoch submits on-chain tx's paid from the oracle wallet, so
    // it must not be triggerable by anyone who can reach the port.
    if (!isAuthorized(req.headers, cfg.adminToken)) return json(res, 401, { error: 'Unauthorized' });
    if (rateLimited(clientKey(req))) return json(res, 429, { error: 'Rate limited' });
    if (epochRunning) return json(res, 409, { error: 'Epoch already running' });
    runEpoch().catch(err => console.error('[oracle] manual epoch error:', err.message));
    return json(res, 202, { message: 'Epoch started' });
  }

  // POST /attest  — body: { didHash, success }
  if (req.method === 'POST' && pathname === '/attest') {
    if (!isAuthorized(req.headers, cfg.adminToken)) return json(res, 401, { error: 'Unauthorized' });
    if (rateLimited(clientKey(req))) return json(res, 429, { error: 'Rate limited' });
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
    if (!isAuthorized(req.headers, cfg.adminToken)) return json(res, 401, { error: 'Unauthorized' });
    if (rateLimited(clientKey(req))) return json(res, 429, { error: 'Rate limited' });
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
  const didHash = parseScorePath(pathname);
  if (req.method === 'GET' && didHash) {
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

server.listen(cfg.port, cfg.host, () => {
  if (!cfg.adminToken) {
    console.warn('[oracle] WARNING: ORACLE_ADMIN_TOKEN is unset — /attest, /flag, and /epoch are UNAUTHENTICATED. Set a token before exposing this service.');
  }
  console.log(`[oracle] HTTP on ${cfg.host}:${cfg.port}  epoch every ${cfg.epochMs / 3_600_000}h`);
  runEpoch();
  setInterval(runEpoch, cfg.epochMs);
});
