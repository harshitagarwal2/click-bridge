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
  RESULT_REASONS,
} from '../public/wire-protocol.js';
import {
  INVARIANTS,
  MAX_MESSAGE_BYTES,
  ACTION_LIFETIME_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  CLOCK_HEALTH_SAMPLES,
  CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS,
} from '../src/constants.js';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '../../contracts/fixtures');
const INVALID_FIXTURES = join(FIXTURES, 'invalid');
const load = (name) => readFileSync(join(FIXTURES, name), 'utf8').trim();
const object = (name) => JSON.parse(load(name));
const validFiles = () => readdirSync(FIXTURES).filter((name) => name.endsWith('.json')).sort();

const throwsCode = (fn, code) =>
  assert.throws(
    fn,
    (error) => error instanceof ProtocolError && error.code === code,
    `expected ProtocolError ${code}`,
  );

function parseCanonical(raw) {
  const message = JSON.parse(raw);
  switch (message.type) {
    case 'hello':
      return parseClientMessage(raw, null);
    case 'hello.ok':
      return parseServerMessage(raw, message.role);
    case 'heartbeat.request':
      return parseClientMessage(raw, 'phone');
    case 'heartbeat.ack':
      return parseServerMessage(raw, 'phone');
    case 'action.request':
    case 'diagnostics.request':
    case 'time.sync.request':
      return parseClientMessage(raw, 'phone');
    case 'mac.state':
    case 'action.result':
    case 'diagnostics.counters':
    case 'time.sync.response':
      return parseClientMessage(raw, 'mac');
    case 'state':
    case 'relay.ack':
      return parseServerMessage(raw, 'phone');
    default:
      throw new Error(`fixture has unknown type ${message.type}`);
  }
}

test('timing invariants and clock-health constants match the plan', () => {
  for (const [name, holds] of INVARIANTS) assert.ok(holds, name);
  assert.equal(CLOCK_HEALTH_SAMPLES, 5);
  assert.equal(CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS, 3500);
});

test('every valid fixture is canonical, strictly parseable, and re-encodes identically', () => {
  const files = validFiles();
  assert.ok(files.length >= 25, 'expected the complete valid fixture corpus');
  for (const file of files) {
    const raw = load(file);
    const parsed = parseCanonical(raw);
    assert.equal(encodeMessage(parsed), raw, `${file} must be canonical JSON`);
  }
});

test('every declared message type has a canonical fixture', () => {
  const fixtureTypes = new Set(validFiles().map((name) => object(name).type));
  for (const type of MESSAGE_TYPES) assert.ok(fixtureTypes.has(type), `missing fixture for ${type}`);
});

test('every terminal action result reason has a canonical fixture', () => {
  const results = validFiles()
    .map((name) => object(name))
    .filter((message) => message.type === 'action.result');
  assert.deepEqual(
    new Set(results.map((message) => message.reason)),
    new Set(RESULT_REASONS),
  );
  for (const result of results.filter((message) => message.status === 'rejected')) {
    assert.equal('mouseDownPostedUnixMs' in result, false, 'rejected timestamp must be absent');
  }
});

test('phone cannot send mac.state', () => {
  throwsCode(
    () => parseClientMessage(load('mac.state.json'), 'phone'),
    'message_not_allowed_for_role',
  );
});

test('role-specific server parsing rejects messages delivered to the wrong client', () => {
  throwsCode(
    () => parseServerMessage(load('action.request.json'), 'phone'),
    'message_not_allowed_for_role',
  );
  throwsCode(
    () => parseServerMessage(load('action.result.posted.json'), 'mac'),
    'message_not_allowed_for_role',
  );
  throwsCode(
    () => parseServerMessage(load('hello.ok.json'), 'mac'),
    'message_not_allowed_for_role',
  );
});

test('authentication state only accepts hello before auth and rejects it afterwards', () => {
  assert.equal(parseClientMessage(load('hello.phone.json')).role, 'phone');
  assert.equal(parseClientMessage(load('hello.mac.json')).role, 'mac');
  throwsCode(() => parseClientMessage(load('action.request.json')), 'expected_hello');
  throwsCode(() => parseClientMessage(load('hello.phone.json'), 'phone'), 'already_authenticated');
});

test('malformed JSON and non-object JSON are rejected', () => {
  throwsCode(() => parseClientMessage('{nope'), 'malformed_json');
  for (const raw of ['[]', '"string"', '42', 'null']) {
    throwsCode(() => parseClientMessage(raw), 'not_an_object');
  }
});

test('binary frames are rejected', () => {
  throwsCode(() => parseClientMessage(new Uint8Array([123, 125])), 'binary_frame');
});

test('missing and wrong versions are rejected', () => {
  const hello = object('hello.phone.json');
  const missing = { ...hello };
  delete missing.v;
  throwsCode(() => parseClientMessage(JSON.stringify(missing)), 'unsupported_version');
  throwsCode(() => parseClientMessage(JSON.stringify({ ...hello, v: 2 })), 'unsupported_version');
});

test('unknown types and fields are rejected', () => {
  throwsCode(() => parseClientMessage('{"type":"unknown","v":1}'), 'unknown_type');
  const hello = object('hello.phone.json');
  throwsCode(() => parseClientMessage(JSON.stringify({ ...hello, extra: true })), 'unknown_field');
});

test('token must be exactly 64 lowercase hexadecimal characters', () => {
  const hello = object('hello.phone.json');
  for (const token of ['', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), 'g'.repeat(64)]) {
    throwsCode(
      () => parseClientMessage(JSON.stringify({ ...hello, token })),
      'invalid_token_shape',
    );
  }
});

test('UUIDs and actions are validated without coercion', () => {
  const action = object('action.request.json');
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...action, actionId: 'not-a-uuid' }), 'phone'),
    'invalid_uuid',
  );
  for (const value of ['scroll', 'CLICK', '', 1]) {
    throwsCode(
      () => parseClientMessage(JSON.stringify({ ...action, action: value }), 'phone'),
      value === 1 ? 'invalid_type' : 'invalid_value',
    );
  }
});

test('expiresAtUnixMs is exactly ACTION_LIFETIME_MS after issuedAtUnixMs', () => {
  const action = object('action.request.json');
  assert.equal(action.expiresAtUnixMs - action.issuedAtUnixMs, ACTION_LIFETIME_MS);
  for (const delta of [0, 1999, 2001, 5000, -1]) {
    throwsCode(
      () => parseClientMessage(JSON.stringify({
        ...action,
        expiresAtUnixMs: action.issuedAtUnixMs + delta,
      }), 'phone'),
      'invalid_lifetime',
    );
  }
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...action, issuedAtUnixMs: '1786497600000' }), 'phone'),
    'invalid_type',
  );
});

test('invalid result status, reason, acceptedVia, and timestamp shape are rejected', () => {
  const posted = object('action.result.posted.json');
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...posted, status: 'maybe' }), 'mac'),
    'invalid_value',
  );
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...posted, reason: 'because' }), 'mac'),
    'invalid_value',
  );
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...posted, acceptedVia: 'carrier-pigeon' }), 'mac'),
    'invalid_value',
  );
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...posted, reason: 'expired' }), 'mac'),
    'invalid_value',
  );

  const rejected = object('action.result.rejected.json');
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...rejected, reason: 'ok' }), 'mac'),
    'invalid_value',
  );
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...rejected, mouseDownPostedUnixMs: null }), 'mac'),
    'unknown_field',
  );
});

test('relay acknowledgement enforces status and reason pairing', () => {
  for (const name of [
    'relay.ack.json',
    'relay.ack.mac-offline.json',
    'relay.ack.rejected-expired.json',
    'relay.ack.rejected-invalid-request.json',
  ]) {
    assert.doesNotThrow(() => parseServerMessage(load(name), 'phone'));
  }

  const base = object('relay.ack.json');
  for (const [status, reason] of [
    ['forwarded', 'expired'],
    ['mac_offline', 'ok'],
    ['rejected', 'mac_offline'],
  ]) {
    throwsCode(
      () => parseServerMessage(JSON.stringify({ ...base, status, reason }), 'phone'),
      'invalid_value',
    );
  }
});

test('malformed time-sync requests and responses are rejected', () => {
  const request = object('time.sync.request.json');
  throwsCode(
    () => parseClientMessage(JSON.stringify({ ...request, phoneSendUnixMs: -1 }), 'phone'),
    'invalid_value',
  );

  const response = object('time.sync.response.json');
  throwsCode(
    () => parseClientMessage(JSON.stringify({
      ...response,
      macSendUnixMs: response.macReceiveUnixMs - 1,
    }), 'mac'),
    'invalid_value',
  );
});

test('the 4,096-byte boundary is exact and UTF-8 based', () => {
  const hello = load('hello.phone.json');
  const exact = hello + ' '.repeat(MAX_MESSAGE_BYTES - new TextEncoder().encode(hello).byteLength);
  assert.equal(new TextEncoder().encode(exact).byteLength, MAX_MESSAGE_BYTES);
  assert.doesNotThrow(() => parseClientMessage(exact));
  throwsCode(() => parseClientMessage(`${exact} `), 'message_too_large');

  const multibyte = `${hello}${'😀'.repeat(1024)}`;
  throwsCode(() => parseClientMessage(multibyte), 'message_too_large');
});

test('canonical invalid descriptors exercise the declared parser error', () => {
  const descriptors = readdirSync(INVALID_FIXTURES)
    .filter((name) => name.endsWith('.json'))
    .map((name) => [name, JSON.parse(readFileSync(join(INVALID_FIXTURES, name), 'utf8'))]);
  assert.ok(descriptors.length >= 9);

  for (const [name, descriptor] of descriptors) {
    let raw;
    if (descriptor.kind === 'raw') raw = descriptor.raw;
    else if (descriptor.kind === 'binary') raw = new Uint8Array(descriptor.bytes);
    else if (descriptor.kind === 'fixture') raw = load(descriptor.fixture);
    else if (descriptor.kind === 'message') raw = JSON.stringify(descriptor.message);
    else if (descriptor.kind === 'oversized') {
      raw = JSON.stringify({
        ...object(descriptor.baseFixture),
        [descriptor.field]: descriptor.repeat.repeat(descriptor.count),
      });
    } else {
      throw new Error(`unknown invalid fixture kind ${descriptor.kind}`);
    }

    const parser = descriptor.parser === 'server' ? parseServerMessage : parseClientMessage;
    throwsCode(() => parser(raw, descriptor.role), descriptor.expectedError, name);
  }
});

test('fingerprint excludes actionId and deterministically covers action timing', () => {
  const original = object('action.request.json');
  const differentId = { ...original, actionId: '018f63f5-6f3d-7d21-88bc-9ef561f030ff' };
  assert.equal(actionFingerprint(original), actionFingerprint(differentId));

  const shifted = {
    ...original,
    issuedAtUnixMs: original.issuedAtUnixMs + 1,
    expiresAtUnixMs: original.expiresAtUnixMs + 1,
  };
  assert.notEqual(actionFingerprint(original), actionFingerprint(shifted));
});

test('expiry honours the configured skew tolerance', () => {
  const action = object('action.request.json');
  assert.equal(
    isExpired(action, action.expiresAtUnixMs + CLOCK_SKEW_TOLERANCE_MS, CLOCK_SKEW_TOLERANCE_MS),
    false,
  );
  assert.equal(
    isExpired(action, action.expiresAtUnixMs + CLOCK_SKEW_TOLERANCE_MS + 1, CLOCK_SKEW_TOLERANCE_MS),
    true,
  );
});

test('encodeMessage rejects non-canonical messages', () => {
  throwsCode(
    () => encodeMessage({ type: 'hello', v: 1, role: 'phone', token: 'short' }),
    'invalid_token_shape',
  );
});
