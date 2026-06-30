'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computeScore, feeScore, successScore, ageScore, communityScore } = require('./scoring');

// ---- feeScore --------------------------------------------------------------

test('feeScore: 0 attestations = 0', () => {
  assert.equal(feeScore(0), 0);
});

test('feeScore: 10 attestations = 1', () => {
  assert.equal(feeScore(10), 1);
});

test('feeScore: capped at 30', () => {
  assert.equal(feeScore(300), 30);
  assert.equal(feeScore(9999), 30);
});

// ---- successScore ----------------------------------------------------------

test('successScore: no attestations = 0', () => {
  assert.equal(successScore(0, 0), 0);
});

test('successScore: 100% success = 25', () => {
  assert.equal(successScore(100, 100), 25);
});

test('successScore: 50% success = 12', () => {
  assert.equal(successScore(5, 10), 12);
});

test('successScore: 0% success = 0', () => {
  assert.equal(successScore(0, 100), 0);
});

// ---- ageScore --------------------------------------------------------------

test('ageScore: just registered = 0', () => {
  const registeredAt = Math.floor(Date.now() / 1000);
  assert.equal(ageScore(registeredAt), 0);
});

test('ageScore: day 1 > 0', () => {
  const registeredAt = Math.floor(Date.now() / 1000) - 86400;
  assert.ok(ageScore(registeredAt) > 0);
});

test('ageScore: day 31 reaches max of 20', () => {
  const registeredAt = Math.floor(Date.now() / 1000) - 31 * 86400;
  assert.equal(ageScore(registeredAt), 20);
});

test('ageScore: capped at 20 for very old agents', () => {
  const registeredAt = Math.floor(Date.now() / 1000) - 365 * 86400;
  assert.equal(ageScore(registeredAt), 20);
});

// ---- communityScore --------------------------------------------------------

test('communityScore: 0 flags = 5', () => {
  assert.equal(communityScore(0), 5);
});

test('communityScore: 1 flag = 3', () => {
  assert.equal(communityScore(1), 3);
});

test('communityScore: 2 flags = 1', () => {
  assert.equal(communityScore(2), 1);
});

test('communityScore: 3+ flags = 0', () => {
  assert.equal(communityScore(3), 0);
  assert.equal(communityScore(10), 0);
});

// ---- computeScore ----------------------------------------------------------

test('computeScore: new agent with no activity = age+community only', () => {
  const registeredAt = Math.floor(Date.now() / 1000);
  const s = computeScore({ registeredAt, attestations: { successful: 0, total: 0 }, flags: 0 });
  assert.equal(s.feeScore, 0);
  assert.equal(s.successScore, 0);
  assert.equal(s.ageScore, 0);
  assert.equal(s.externalScore, 0);
  assert.equal(s.communityScore, 5);
  assert.equal(s.propagationScore, 0);
  assert.equal(s.total, 5);
});

test('computeScore: total never exceeds 100', () => {
  // Max possible: 30+25+20+0+5+0 = 80 (external and propagation stubs at 0)
  const registeredAt = Math.floor(Date.now() / 1000) - 365 * 86400;
  const s = computeScore({ registeredAt, attestations: { successful: 300, total: 300 }, flags: 0 });
  assert.ok(s.total <= 100);
  assert.equal(s.total, 80);
});

test('computeScore: slashed-like scenario (high flags)', () => {
  const registeredAt = Math.floor(Date.now() / 1000) - 10 * 86400;
  const s = computeScore({ registeredAt, attestations: { successful: 5, total: 10 }, flags: 5 });
  assert.equal(s.communityScore, 0);
  assert.ok(s.total >= 0);
});
