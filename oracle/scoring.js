'use strict';

// Ported from bagsReputation.js — adapted for the Countersig EVM protocol.
// All six factors are self-contained pure functions so they can be unit-tested in isolation.
//
// Phase 1 stubs: externalScore (SAID integration) and propagationScore (trust graph)
// are always 0 until Phase 2 oracle network is live.

function feeScore(attestationTotal) {
  // Proxy for fee activity: 1 point per 10 attestations received, capped at 30.
  return Math.min(30, Math.floor(attestationTotal / 10));
}

function successScore(successful, total) {
  if (total === 0) return 0;
  return Math.floor((successful / total) * 25);
}

function ageScore(registeredAtSeconds) {
  // Logarithmic formula matches the Solidity on-chain reference value.
  // Reaches max (20) around day 31: log2(32) * 4 = 20.
  const days = (Date.now() / 1000 - registeredAtSeconds) / 86400;
  return Math.min(20, Math.floor(Math.log2(days + 1) * 4));
}

function communityScore(unresolvedFlags) {
  // 0 flags → 5 pts, 1 flag → 3 pts, 2 flags → 1 pt, 3+ flags → 0
  // Formula: max(0, 5 - flags*2)
  return Math.max(0, 5 - unresolvedFlags * 2);
}

/**
 * @param {{ registeredAt: number, attestations: { successful: number, total: number }, flags: number }} opts
 * @returns {{ feeScore, successScore, ageScore, externalScore, communityScore, propagationScore, total }}
 */
function computeScore({ registeredAt, attestations, flags }) {
  const { successful = 0, total = 0 } = attestations;

  const fs = feeScore(total);
  const ss = successScore(successful, total);
  const as = ageScore(registeredAt);
  const es = 0;  // SAID / Gitcoin Passport — Phase 2
  const cs = communityScore(flags ?? 0);
  const ps = 0;  // Trust propagation graph — Phase 2

  return { feeScore: fs, successScore: ss, ageScore: as, externalScore: es, communityScore: cs, propagationScore: ps, total: fs + ss + as + cs };
}

module.exports = { computeScore, feeScore, successScore, ageScore, communityScore };
