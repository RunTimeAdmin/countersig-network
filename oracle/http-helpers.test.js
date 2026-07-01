'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { readBody, isAuthorized, parseScorePath } = require('./http-helpers');

// Minimal fake matching the subset of http.IncomingMessage that readBody uses:
// an EventEmitter with data/end/error events plus a destroy() method.
function makeFakeRequest() {
  const req = new EventEmitter();
  req.destroy = () => req.emit('destroyed');
  return req;
}

// -------------------------------------------------------------------------
// isAuthorized
// -------------------------------------------------------------------------

test('isAuthorized: no admin token configured -> always authorized', () => {
  assert.equal(isAuthorized({}, ''), true);
  assert.equal(isAuthorized({ authorization: 'garbage' }, ''), true);
});

test('isAuthorized: token configured, missing header -> unauthorized', () => {
  assert.equal(isAuthorized({}, 'secret'), false);
});

test('isAuthorized: token configured, wrong header -> unauthorized', () => {
  assert.equal(isAuthorized({ authorization: 'Bearer wrong' }, 'secret'), false);
});

test('isAuthorized: token configured, correct bearer header -> authorized', () => {
  assert.equal(isAuthorized({ authorization: 'Bearer secret' }, 'secret'), true);
});

test('isAuthorized: header without Bearer prefix does not match', () => {
  assert.equal(isAuthorized({ authorization: 'secret' }, 'secret'), false);
});

// -------------------------------------------------------------------------
// readBody
// -------------------------------------------------------------------------

test('readBody: parses a valid JSON body', async () => {
  const req = makeFakeRequest();
  const promise = readBody(req);
  req.emit('data', Buffer.from('{"didHash":"0xabc","success":true}'));
  req.emit('end');

  const body = await promise;
  assert.deepEqual(body, { didHash: '0xabc', success: true });
});

test('readBody: empty body resolves to an empty object', async () => {
  const req = makeFakeRequest();
  const promise = readBody(req);
  req.emit('end');

  const body = await promise;
  assert.deepEqual(body, {});
});

test('readBody: invalid JSON rejects', async () => {
  const req = makeFakeRequest();
  const promise = readBody(req);
  req.emit('data', Buffer.from('not json'));
  req.emit('end');

  await assert.rejects(promise, /Invalid JSON/);
});

test('readBody: oversized body destroys the request and rejects', async () => {
  const req = makeFakeRequest();
  let destroyed = false;
  req.on('destroyed', () => { destroyed = true; });

  const promise = readBody(req, 10); // 10-byte limit for this test
  req.emit('data', Buffer.from('this is way more than ten bytes'));

  await assert.rejects(promise, /too large/);
  assert.equal(destroyed, true);
});

test('readBody: chunks are reassembled in order', async () => {
  const req = makeFakeRequest();
  const promise = readBody(req);
  req.emit('data', Buffer.from('{"didHash":'));
  req.emit('data', Buffer.from('"0xabc"}'));
  req.emit('end');

  const body = await promise;
  assert.deepEqual(body, { didHash: '0xabc' });
});

// -------------------------------------------------------------------------
// parseScorePath
// -------------------------------------------------------------------------

test('parseScorePath: valid path returns the didHash', () => {
  const didHash = '0x' + 'a'.repeat(64);
  assert.equal(parseScorePath(`/score/${didHash}`), didHash);
});

test('parseScorePath: wrong hex length returns null', () => {
  assert.equal(parseScorePath('/score/0x1234'), null);
});

test('parseScorePath: missing 0x prefix returns null', () => {
  assert.equal(parseScorePath(`/score/${'a'.repeat(64)}`), null);
});

test('parseScorePath: unrelated path returns null', () => {
  assert.equal(parseScorePath('/health'), null);
});
