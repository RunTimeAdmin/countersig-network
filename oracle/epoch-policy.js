'use strict';

// Decides what an epoch should do for a single agent's reputation score, given
// whether a proposal is currently pending and how old it is.
//
// proposeReputation() on-chain always overwrites any pending proposal and
// restarts its challenge window. That means re-proposing every epoch while a
// score is still pending would perpetually reset the clock — it would never
// actually finalize. So the rule is:
//   - nothing pending            -> 'propose' a fresh score
//   - pending, window elapsed    -> 'finalize-then-propose' (finalize the old
//                                    one, then propose fresh once it's clear)
//   - pending, window still open -> 'skip' this agent this epoch
//
// Pure function — no I/O, no ethers, easy to unit test in isolation.
function decideAction(pending, challengeWindowSeconds, nowSeconds) {
  if (!pending || !pending.exists) return 'propose';

  const ready = nowSeconds >= pending.proposedAt + challengeWindowSeconds;
  return ready ? 'finalize-then-propose' : 'skip';
}

module.exports = { decideAction };
