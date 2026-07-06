'use strict';

const crypto = require('crypto');

// Pure-ish HTTP helpers extracted from index.js so the auth gate, body-size
// limit, and route parsing can be unit tested without a live server.

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

const SCORE_PATH_RE = /^\/score\/(0x[0-9a-fA-F]{64})$/;

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

// req only needs to be an EventEmitter emitting 'data' | 'end' | 'error' and
// exposing destroy() — a real http.IncomingMessage satisfies this, and so
// does a plain fake in tests.
async function readBody(req, maxBodySize = MAX_BODY_SIZE) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > maxBodySize) {
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

// Takes the raw headers object and the configured admin token directly
// (rather than the whole request/config) so it's trivial to unit test.
function isAuthorized(headers, adminToken) {
  if (!adminToken) return true; // auth disabled if no token configured
  const header = headers['authorization'] || '';
  const expected = `Bearer ${adminToken}`;
  // Constant-time compare to avoid leaking the token via response timing.
  // timingSafeEqual requires equal-length buffers, so length-mismatch fails first.
  const a = Buffer.from(header);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Returns the didHash from a /score/:didHash path, or null if it doesn't match.
function parseScorePath(pathname) {
  const match = pathname.match(SCORE_PATH_RE);
  return match ? match[1] : null;
}

module.exports = { MAX_BODY_SIZE, json, readBody, isAuthorized, parseScorePath };
