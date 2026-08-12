import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  parseClientMessage,
  parseServerMessage,
  encodeMessage,
  actionFingerprint,
  isExpired,
  ProtocolError,
  MESSAGE_TYPES,
} from '../src/protocol.js';

import {
  INVARIANTS,
  MAX_MESSAGE_BYTES,
  ACTION_LIFETIME_MS,
  CLOCK_SKEW_TOLERANCE_MS,
} from '../src/constants.js';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '../../contracts/fixtures');
const load = (name) => readFileSync(join(FIX, name), 'utf8').trim();
const obj = (name) => JSON.parse(load(name));

const throwsCode = (fn, code) =>
  assert.throws(fn, (e) => e instanceof ProtocolError && e.code === code,
    `expected ProtocolError ${code}`);

// ---------------------------------------------------------------------------
// Invariants
// ---------------------------------------------------------------------------

test('timing invariants hold', () => {
  for (const [name, ok] of INVARIANTS) assert.ok(ok, name);
});

// ---------------------------------------------------------------------------
// Fixtures round-trip
// ---------------------------------------------------------------------------

test('every fixture file re-encodes to itself', () => {
  const files = readdirSync(FIX).filter((f) => f.endsWith('.json'));
  assert.ok(files.length >= 13, 'expected the full fixture set');
  for (const f of files) {
    const parsed = obj(f);
    assert.equal(encodeMessage(parsed), JSON.stringify(parsed), `${f} round-trip`);
  }
});

test('every declared message type has a fixture', () => {
  const files = readdirSync(FIX).map((f) => JSON.parse(load(f)).type);
  for (const t of MESSAGE_TYPES) assert.ok(files.includes(t), `no fixture for ${t}`);
});

// ---------------------------------------------------------------------------
// Valid paths
// ---------------------------------------------------------------------------

test('hello is accepted pre-authentication for both roles', () => {
  assert.equal(parseClientMessage(load('hello.phone.json'), null).role, 'phone');
  assert.equal(parseClientMessage(load('hello.mac.json'), null).role, 'mac');
});

test('phone action.request is accepted from an authenticated phone', () => {
  const m = parseClientMessage(load('action.request.json'), 'phone');
  assert.equal(m.action, 'click');
});

test('mac.state and action.result are accepted from an authenticated mac', () => {
  assert.equal(parseClientMessage(load('mac.state.json'), 'mac').permission, 'ready');
  assert.equal(parseClientMessage(load('action.result.posted.json'), 'mac').status, 'posted');
});

test('heartbeat flows from either role', () => {
  for (const role of ['phone', 'mac']) {
    assert.equal(parseClientMessage(load('heartbeat.request.json'), role).sequence, 17);
    assert.equal(parseClientMessage(load('heartbeat.ack.json'), role).sequence, 17);
  }
});

test('clients accept server-originated messages', () => {
  assert.equal(parseServerMessage(load('state.json')).macOnline, true);
  assert.equal(parseServerMessage(load('relay.ack.json')).status, 'forwarded');
  assert.equal(parseServerMessage(load('hello.ok.json')).role, 'phone');
});

// ---------------------------------------------------------------------------
// Role enforcement
// ---------------------------------------------------------------------------

test('phone cannot send mac.state', () => {
  throwsCode(() => parseClientMessage(load('mac.state.json'), 'phone'),
    'message_not_allowed_for_role');
});

test('phone cannot send action.result', () => {
  throwsCode(() => parseClientMessage(load('action.result.posted.json'), 'phone'),
    'message_not_allowed_for_role');
});

test('mac cannot send action.request', () => {
  throwsCode(() => parseClientMessage(load('action.request.json'), 'mac'),
    'message_not_allowed_for_role');
});

test('no client may send a server-originated message', () => {
  for (const f of ['state.json', 'relay.ack.json', 'hello.ok.json']) {
    throwsCode(() => parseClientMessage(load(f), 'phone'), 'message_not_allowed_for_role');
    throwsCode(() => parseClientMessage(load(f), 'mac'), 'message_not_allowed_for_role');
  }
});

test('a second hello after authentication is rejected', () => {
  throwsCode(() => parseClientMessage(load('hello.phone.json'), 'phone'),
    'already_authenticated');
});

test('anything other than hello is rejected pre-authentication', () => {
  throwsCode(() => parseClientMessage(load('action.request.json'), null), 'expected_hello');
});

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

test('malformed JSON is rejected', () => {
  throwsCode(() => parseClientMessage('{nope', null), 'malformed_json');
});

test('non-object JSON is rejected', () => {
  for (const raw of ['[]', '"str"', '42', 'null']) {
    throwsCode(() => parseClientMessage(raw, null), 'not_an_object');
  }
});

test('binary frames are rejected', () => {
  throwsCode(() => parseClientMessage(Buffer.from('{}'), null), 'binary_frame');
});

test('unknown type is rejected', () => {
  throwsCode(() => parseClientMessage('{"type":"nope","v":1}', null), 'unknown_type');
});

test('wrong protocol version is rejected', () => {
  const m = { ...obj('hello.phone.json'), v: 2 };
  throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'unsupported_version');
});

test('missing version is rejected', () => {
  const m = obj('hello.phone.json');
  delete m.v;
  throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'unsupported_version');
});

test('unknown field is rejected', () => {
  const m = { ...obj('hello.phone.json'), extra: 1 };
  throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'unknown_field');
});

test('missing field is rejected', () => {
  const m = obj('hello.phone.json');
  delete m.token;
  throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'missing_field');
});

test('oversized frame is rejected', () => {
  const m = obj('hello.phone.json');
  const raw = JSON.stringify(m).replace('}', `,"pad":"${'x'.repeat(MAX_MESSAGE_BYTES)}"}`);
  throwsCode(() => parseClientMessage(raw, null), 'message_too_large');
});

// ---------------------------------------------------------------------------
// Field-level validation
// ---------------------------------------------------------------------------

test('token must be exactly 64 lowercase hex', () => {
  for (const bad of ['', 'abc', 'A'.repeat(64), 'g'.repeat(64), '1'.repeat(63), '1'.repeat(65)]) {
    const m = { ...obj('hello.phone.json'), token: bad };
    throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'invalid_token_shape');
  }
});

test('invalid role is rejected', () => {
  const m = { ...obj('hello.phone.json'), role: 'admin' };
  throwsCode(() => parseClientMessage(JSON.stringify(m), null), 'invalid_value');
});

test('invalid UUID is rejected', () => {
  const m = { ...obj('action.request.json'), actionId: 'not-a-uuid' };
  throwsCode(() => parseClientMessage(JSON.stringify(m), 'phone'), 'invalid_uuid');
});

test('any action other than click is rejected', () => {
  for (const bad of ['key', 'scroll', 'CLICK', '']) {
    const m = { ...obj('action.request.json'), action: bad };
    throwsCode(() => parseClientMessage(JSON.stringify(m), 'phone'), 'invalid_value');
  }
});

test('expiry must be exactly ACTION_LIFETIME_MS after issue', () => {
  const base = obj('action.request.json');
  for (const delta of [0, 1000, 1999, 2001, 5000, -2000]) {
    const m = { ...base, expiresAtUnixMs: base.issuedAtUnixMs + delta };
    if (delta === ACTION_LIFETIME_MS) continue;
    throwsCode(() => parseClientMessage(JSON.stringify(m), 'phone'), 'invalid_lifetime');
  }
});

test('strings are not coerced to numbers', () => {
  const m = { ...obj('action.request.json'), issuedAtUnixMs: '1786497600000' };
  throwsCode(() => parseClientMessage(JSON.stringify(m), 'phone'), 'invalid_type');
});

test('invalid result status and reason are rejected', () => {
  const base = obj('action.result.posted.json');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, status: 'maybe' }), 'mac'), 'invalid_value');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, reason: 'because' }), 'mac'), 'invalid_value');
});

test('posted result must carry reason ok and a real timestamp', () => {
  const base = obj('action.result.posted.json');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, reason: 'expired' }), 'mac'), 'invalid_value');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, mouseDownPostedUnixMs: null }), 'mac'), 'invalid_type');
});

test('rejected result must carry a non-ok reason and a null timestamp', () => {
  const base = obj('action.result.rejected.json');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, reason: 'ok' }), 'mac'), 'invalid_value');
  throwsCode(() => parseClientMessage(
    JSON.stringify({ ...base, mouseDownPostedUnixMs: 123 }), 'mac'), 'invalid_value');
});

test('invalid acceptedVia is rejected', () => {
  const m = { ...obj('action.result.posted.json'), acceptedVia: 'carrier-pigeon' };
  throwsCode(() => parseClientMessage(JSON.stringify(m), 'mac'), 'invalid_value');
});

test('time-sync with impossible ordering is rejected', () => {
  const base = obj('time.sync.response.json');
  const m = { ...base, macSendUnixMs: base.macReceiveUnixMs - 1 };
  throwsCode(() => parseClientMessage(JSON.stringify(m), 'mac'), 'invalid_value');
});

test('negative heartbeat sequence is rejected', () => {
  const m = { ...obj('heartbeat.request.json'), sequence: -1 };
  throwsCode(() => parseClientMessage(JSON.stringify(m), 'phone'), 'invalid_value');
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

test('fingerprint excludes actionId but covers timing fields', () => {
  const a = obj('action.request.json');
  const b = { ...a, actionId: '018f63f5-6f3d-7d21-88bc-9ef561f030ff' };
  assert.equal(actionFingerprint(a), actionFingerprint(b), 'id must not affect fingerprint');

  const c = { ...a, issuedAtUnixMs: a.issuedAtUnixMs + 1, expiresAtUnixMs: a.expiresAtUnixMs + 1 };
  assert.notEqual(actionFingerprint(a), actionFingerprint(c), 'timing must affect fingerprint');
});

test('expiry honours the skew tolerance band', () => {
  const a = obj('action.request.json');
  const T = CLOCK_SKEW_TOLERANCE_MS;
  assert.equal(isExpired(a, a.expiresAtUnixMs - 1, T), false);
  assert.equal(isExpired(a, a.expiresAtUnixMs + T, T), false, 'inside tolerance');
  assert.equal(isExpired(a, a.expiresAtUnixMs + T + 1, T), true, 'past tolerance');
});

test('encodeMessage rejects an invalid message', () => {
  throwsCode(() => encodeMessage({ type: 'hello', v: 1, role: 'phone', token: 'short' }),
    'invalid_token_shape');
});
