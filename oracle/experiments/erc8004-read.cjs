'use strict';

// ERC-8004 interop prototype: read live agent feedback from the Base Sepolia
// Reputation Registry and compute a Countersig externalScore (0-15) from it.
//
// Why this exists: ERC-8004's Reputation Registry stores only RAW signed
// feedback (int128 value + decimals + a free-text tag) and explicitly leaves
// score computation off-chain. In practice every client invents its own tag
// and scale — quality=85 (0-100), win-rate=0.5 (0-1), e2e-test=4.5 (0-5),
// glicko2-mu=1500 (a rating), match-count=2 (a raw count). Averaging those is
// meaningless (the registry's own getSummary does exactly that and returns
// garbage). Normalizing heterogeneous feedback into one comparable number is
// the value layer Countersig provides. This script proves the read + that
// normalization end to end against real on-chain data.
//
// Run: node oracle/experiments/erc8004-read.cjs [agentId]

try { require('truststore').inject_into_ssl(); } catch (_) {} // desktop TLS intercept; no-op on Linux

const { ethers } = require('ethers');
const { TAG_NORMALIZERS } = require('../external'); // single source of truth for the normalization map

const RPC = process.env.BASE_SEPOLIA_RPC || 'https://sepolia.base.org';
// Canonical ERC-8004 testnet singletons (same vanity addresses on every chain)
const IDENTITY = '0x8004A818BFB912233c491871b3d84c89A494BD9e';
const REPUTATION = '0x8004B663056A597Dffe9eCcC1965A193B7388713';

const REP_ABI = [
  'function getClients(uint256 agentId) view returns (address[])',
  'function getLastIndex(uint256 agentId, address clientAddress) view returns (uint64)',
  'function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex) view returns (int128 value, uint8 valueDecimals, string tag1, string tag2, bool isRevoked)',
];
const ID_ABI = ['function ownerOf(uint256) view returns (address)'];

// The normalization map (TAG_NORMALIZERS) lives in ../external.js so the oracle
// and this experiment agree on the judgment. This script adds a display of the
// recognized/excluded breakdown to make the heterogeneity visible.

async function readAgentFeedback(rep, agentId) {
  const clients = Array.from(await rep.getClients(agentId));
  const rows = [];
  for (const c of clients) {
    let last = 0;
    try { last = Number(await rep.getLastIndex(agentId, c)); } catch { continue; }
    for (let i = 1; i <= last; i++) {
      try {
        const fb = await rep.readFeedback(agentId, c, i);
        if (fb.isRevoked) continue;
        rows.push({
          client: c,
          value: Number(fb.value) / 10 ** Number(fb.valueDecimals),
          tag: (fb.tag1 || '').toLowerCase(),
        });
      } catch { /* gaps in the index are expected; skip */ }
    }
  }
  return { clients, rows };
}

function computeExternalScore(rows) {
  const recognized = [];
  const excluded = new Map();
  for (const r of rows) {
    const norm = TAG_NORMALIZERS[r.tag];
    if (norm) recognized.push(norm(r.value));
    else excluded.set(r.tag, (excluded.get(r.tag) || 0) + 1);
  }
  if (!recognized.length) return { externalScore: 0, recognizedCount: 0, mean: 0, excluded };
  const mean = recognized.reduce((a, b) => a + b, 0) / recognized.length;
  return { externalScore: Math.round(mean * 15), recognizedCount: recognized.length, mean, excluded };
}

async function main() {
  const agentId = Number(process.argv[2] || 1);
  const p = new ethers.JsonRpcProvider(RPC);
  const net = await p.getNetwork();
  console.log(`ERC-8004 read — Base Sepolia (chainId ${net.chainId}) — agent ${agentId}\n`);

  const id = new ethers.Contract(IDENTITY, ID_ABI, p);
  const rep = new ethers.Contract(REPUTATION, REP_ABI, p);

  let owner;
  try { owner = await id.ownerOf(agentId); } catch { console.log(`agent ${agentId} not registered`); return; }
  console.log(`owner: ${owner}`);

  const { clients, rows } = await readAgentFeedback(rep, agentId);
  console.log(`${clients.length} clients, ${rows.length} non-revoked feedback records\n`);

  // Show the heterogeneity the standard leaves unresolved
  const byTag = {};
  for (const r of rows) (byTag[r.tag] ||= []).push(r.value);
  console.log('raw feedback by tag (this is what ERC-8004 stores — no common scale):');
  for (const [tag, vals] of Object.entries(byTag)) {
    console.log(`  ${tag.padEnd(14)} ${vals.join(', ')}${TAG_NORMALIZERS[tag] ? '' : '   <- excluded (no recognized scale)'}`);
  }

  const { externalScore, recognizedCount, mean, excluded } = computeExternalScore(rows);
  console.log(`\nCountersig externalScore: ${externalScore} / 15`);
  console.log(`  from ${recognizedCount} recognized rating(s), normalized mean ${mean.toFixed(3)}`);
  if (excluded.size) console.log(`  excluded tags: ${[...excluded.entries()].map(([t, n]) => `${t}(${n})`).join(', ')}`);
}

main().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
