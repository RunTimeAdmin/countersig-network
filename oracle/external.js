'use strict';

// externalScore — the ERC-8004 cross-protocol trust factor (max 15).
//
// ERC-8004's Reputation Registry stores only raw, signed client feedback
// (int128 value + free-text tag) and leaves scoring off-chain. In the wild
// every client invents its own tag and scale (quality=85 on 0-100, win-rate=0.5
// on 0-1, glicko2-mu=1500, e2e-test=4.5 on 0-5), so the registry's own average
// is meaningless. This module reads an agent's 8004 feedback and normalizes the
// dimensions it recognizes into a single 0-15 factor — the opinionated judgment
// the standard deliberately omits.
//
// Trust: an ERC-8004 identity is a transferable ERC-721. Before using an agent's
// feedback we verify the 8004 NFT is owned by the SAME wallet as the Countersig
// operator, so no one can claim another agent's reputation. Opt-in: when the
// EXTERNAL_* env is unset the module is inert and every externalScore is 0.

const { ethers } = require('ethers');

const ID_ABI = ['function ownerOf(uint256) view returns (address)'];
const REP_ABI = [
  'function getClients(uint256 agentId) view returns (address[])',
  'function getLastIndex(uint256 agentId, address clientAddress) view returns (uint64)',
  'function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex) view returns (int128 value, uint8 valueDecimals, string tag1, string tag2, bool isRevoked)',
];

const MAX_EXTERNAL_SCORE = 15;
const READ_TIMEOUT_MS = 8000;

// ---- pure normalization (the oracle's judgment; curated deliberately) -------
// Map a recognized feedback tag to a 0..1 rating. Unrecognized tags (bespoke
// rating systems, raw counts) are excluded rather than guessed, so the score
// stays meaningful. Extend this map on purpose, never blindly.
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const TAG_NORMALIZERS = {
  quality:     (v) => clamp01(v / 100),
  trustscore:  (v) => clamp01(v / 100),
  reliability: (v) => clamp01(v / 100),
  accuracy:    (v) => clamp01(v / 100),
  credit:      (v) => clamp01(v / 100),
  'win-rate':  (v) => clamp01(v),
  rating:      (v) => clamp01(v / 5),
  'e2e-test':  (v) => clamp01(v / 5),
  stars:       (v) => clamp01(v / 5),
};

// rows: [{ value: Number, tag: String (already lowercased) }]
function computeExternalScore(rows) {
  const recognized = [];
  for (const r of rows) {
    const norm = TAG_NORMALIZERS[r.tag];
    if (norm) recognized.push(norm(r.value));
  }
  if (!recognized.length) return 0;
  const mean = recognized.reduce((a, b) => a + b, 0) / recognized.length;
  return Math.round(mean * MAX_EXTERNAL_SCORE);
}

// ---- chain-connected side (opt-in) -----------------------------------------
let provider, idContract, repContract, enabled = false;

// deps lets tests inject fake contracts. Production (index.js) calls init(cfg).
function init(cfg, deps = {}) {
  enabled = !!(cfg.externalRpc && cfg.externalIdentity && cfg.externalReputation);
  if (!enabled) return;
  provider = deps.provider ?? new ethers.JsonRpcProvider(cfg.externalRpc);
  idContract = deps.idContract ?? new ethers.Contract(cfg.externalIdentity, ID_ABI, provider);
  repContract = deps.repContract ?? new ethers.Contract(cfg.externalReputation, REP_ABI, provider);
}

function configured() { return enabled; }

const withTimeout = (promise) =>
  Promise.race([promise, new Promise((_, rej) => setTimeout(() => rej(new Error('external read timeout')), READ_TIMEOUT_MS))]);

// getClients -> per-client getLastIndex -> readFeedback. The registry is not
// enumerable and public RPCs cap getLogs ranges, so per-agent reads beat event
// scanning. ethers Result arrays are frozen, hence the Array.from copy.
async function readFeedbackRows(agentId) {
  const clients = Array.from(await withTimeout(repContract.getClients(agentId)));
  const rows = [];
  for (const c of clients) {
    let last = 0;
    try { last = Number(await withTimeout(repContract.getLastIndex(agentId, c))); } catch { continue; }
    for (let i = 1; i <= last; i++) {
      try {
        const fb = await withTimeout(repContract.readFeedback(agentId, c, i));
        if (fb.isRevoked) continue;
        rows.push({ value: Number(fb.value) / 10 ** Number(fb.valueDecimals), tag: (fb.tag1 || '').toLowerCase() });
      } catch { /* index gaps are expected — skip */ }
    }
  }
  return rows;
}

// True iff the 8004 agent NFT is owned by expectedOwner (same wallet across
// chains). Case-insensitive. Any error (bad id, RPC) is treated as "no".
async function verifyOwnership(agentId, expectedOwner) {
  if (!enabled) return false;
  try {
    const owner = await withTimeout(idContract.ownerOf(agentId));
    return owner.toLowerCase() === String(expectedOwner).toLowerCase();
  } catch { return false; }
}

// externalScore for a linked agent. Re-verifies ownership every call (the NFT is
// transferable), then reads + normalizes feedback. Fail-safe: any error or
// ownership mismatch yields 0 and never blocks the epoch.
async function externalScoreFor(agentId, expectedOwner) {
  if (!enabled) return 0;
  try {
    if (!(await verifyOwnership(agentId, expectedOwner))) return 0;
    return computeExternalScore(await readFeedbackRows(agentId));
  } catch { return 0; }
}

module.exports = {
  init, configured, computeExternalScore, readFeedbackRows,
  verifyOwnership, externalScoreFor, TAG_NORMALIZERS, MAX_EXTERNAL_SCORE,
};
