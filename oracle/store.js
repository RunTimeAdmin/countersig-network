'use strict';

// Durable store for oracle attestation and flag state.
//
// The score factors driven by /attest and /flag (successScore, feeScore,
// communityScore) accumulate over time and cannot be recomputed from on-chain
// data — so unlike the rest of the epoch loop, they must survive a restart.
// State is small (one small object per agent), single-writer (only this
// process), and low-frequency (both endpoints are rate-limited), so a JSON
// file on a mounted volume is enough. Writes are atomic (temp + rename) so a
// crash mid-write cannot corrupt the file.

const fs = require('fs');
const path = require('path');

const STATE_PATH = process.env.ORACLE_STATE_PATH || '/data/oracle-state.json';

// didHash → { successful, total }
const attestations = new Map();
// didHash → unresolved flag count
const flags = new Map();
// didHash → ERC-8004 agentId (string) this agent is linked to (ownership-verified at link time)
const links = new Map();

function load() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8'));
    for (const [k, v] of Object.entries(parsed.attestations || {})) attestations.set(k, v);
    for (const [k, v] of Object.entries(parsed.flags || {})) flags.set(k, v);
    for (const [k, v] of Object.entries(parsed.links || {})) links.set(k, v);
    console.log(`[oracle] state loaded from ${STATE_PATH}: ${attestations.size} attestations, ${flags.size} flags, ${links.size} links`);
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.log(`[oracle] no prior state at ${STATE_PATH}, starting fresh`);
    } else {
      console.warn(`[oracle] state load failed (${err.message}); starting fresh`);
    }
  }
}

function persist() {
  try {
    fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
    const tmp = `${STATE_PATH}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({
      attestations: Object.fromEntries(attestations),
      flags: Object.fromEntries(flags),
      links: Object.fromEntries(links),
      savedAt: new Date().toISOString(),
    }));
    fs.renameSync(tmp, STATE_PATH);
  } catch (err) {
    console.error(`[oracle] state persist FAILED: ${err.message}`);
  }
}

module.exports = { attestations, flags, links, load, persist };
