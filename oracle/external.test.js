'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computeExternalScore, MAX_EXTERNAL_SCORE } = require('./external');

// ---- computeExternalScore (the pure normalization) -------------------------

test('externalScore: no rows = 0', () => {
  assert.equal(computeExternalScore([]), 0);
});

test('externalScore: only unrecognized tags = 0 (excluded, not guessed)', () => {
  const rows = [
    { value: 1500, tag: 'glicko2-mu' },
    { value: 2, tag: 'match-count' },
    { value: 5, tag: 'swap-execution' },
  ];
  assert.equal(computeExternalScore(rows), 0);
});

test('externalScore: a perfect 0-100 quality rating = 15', () => {
  assert.equal(computeExternalScore([{ value: 100, tag: 'quality' }]), MAX_EXTERNAL_SCORE);
});

test('externalScore: a zero rating = 0', () => {
  assert.equal(computeExternalScore([{ value: 0, tag: 'quality' }]), 0);
});

test('externalScore: normalizes different scales onto 0..1 before averaging', () => {
  // quality 80/100 = 0.8, win-rate 0.6, e2e-test 4/5 = 0.8 -> mean 0.733 -> 11
  const rows = [
    { value: 80, tag: 'quality' },
    { value: 0.6, tag: 'win-rate' },
    { value: 4, tag: 'e2e-test' },
  ];
  assert.equal(computeExternalScore(rows), 11);
});

test('externalScore: excludes unrecognized tags from the mean', () => {
  // only the quality=100 counts; glicko2-mu is dropped -> 15, not dragged down
  const rows = [
    { value: 100, tag: 'quality' },
    { value: 1500, tag: 'glicko2-mu' },
  ];
  assert.equal(computeExternalScore(rows), MAX_EXTERNAL_SCORE);
});

test('externalScore: negative rating clamps to 0 contribution', () => {
  // reliability -20 -> clamp01(-0.2)=0, quality 100 -> 1 ; mean 0.5 -> 8 (rounded)
  const rows = [
    { value: -20, tag: 'reliability' },
    { value: 100, tag: 'quality' },
  ];
  assert.equal(computeExternalScore(rows), 8);
});
