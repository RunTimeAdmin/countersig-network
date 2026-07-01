'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { decideAction } = require('./epoch-policy');

const CHALLENGE_WINDOW = 3600; // 1 hour

test('decideAction: nothing pending -> propose', () => {
  const pending = { exists: false, proposedAt: 0 };
  assert.equal(decideAction(pending, CHALLENGE_WINDOW, 1_000_000), 'propose');
});

test('decideAction: pending, window just opened -> skip', () => {
  const now = 1_000_000;
  const pending = { exists: true, proposedAt: now };
  assert.equal(decideAction(pending, CHALLENGE_WINDOW, now), 'skip');
});

test('decideAction: pending, window almost elapsed -> skip', () => {
  const proposedAt = 1_000_000;
  const now = proposedAt + CHALLENGE_WINDOW - 1;
  const pending = { exists: true, proposedAt };
  assert.equal(decideAction(pending, CHALLENGE_WINDOW, now), 'skip');
});

test('decideAction: pending, window exactly elapsed -> finalize-then-propose', () => {
  const proposedAt = 1_000_000;
  const now = proposedAt + CHALLENGE_WINDOW;
  const pending = { exists: true, proposedAt };
  assert.equal(decideAction(pending, CHALLENGE_WINDOW, now), 'finalize-then-propose');
});

test('decideAction: pending, window well past -> finalize-then-propose', () => {
  const proposedAt = 1_000_000;
  const now = proposedAt + CHALLENGE_WINDOW * 10;
  const pending = { exists: true, proposedAt };
  assert.equal(decideAction(pending, CHALLENGE_WINDOW, now), 'finalize-then-propose');
});

test('decideAction: repeated propose while pending never advances past skip until window elapses', () => {
  // Regression test for the exact bug this module exists to prevent: if the
  // epoch interval is shorter than the challenge window, naively re-proposing
  // every tick would perpetually reset proposedAt and the score would never
  // finalize. Simulate several epoch ticks against a FIXED proposedAt (as if
  // the oracle correctly skipped instead of re-proposing) and confirm the
  // decision eventually flips to finalize once real time catches up.
  const proposedAt = 1_000_000;
  const epochIntervalSeconds = 60; // epoch far shorter than the challenge window

  let now = proposedAt;
  let sawSkip = false;
  for (let tick = 0; tick < 100; tick++) {
    const pending = { exists: true, proposedAt }; // proposedAt never changes — oracle didn't re-propose
    const action = decideAction(pending, CHALLENGE_WINDOW, now);
    if (action === 'finalize-then-propose') {
      assert.ok(sawSkip, 'expected at least one skip before the window elapsed');
      assert.ok(now >= proposedAt + CHALLENGE_WINDOW);
      return;
    }
    assert.equal(action, 'skip');
    sawSkip = true;
    now += epochIntervalSeconds;
  }
  assert.fail('window never elapsed within 100 epoch ticks');
});

test('decideAction: null pending is treated as nothing pending', () => {
  assert.equal(decideAction(null, CHALLENGE_WINDOW, 1_000_000), 'propose');
});
