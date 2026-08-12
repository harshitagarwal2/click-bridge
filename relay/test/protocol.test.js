import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  parseClientMessage,
  parseServerMessage,
  parsePairingServerMessage,
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
import * as relayConstants from '../src/constants.js';

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

function parsePairingFixture(raw) {
  const message = JSON.parse(raw);
  const state = message.type === 'pair.credential'
    ? 'awaiting_credential'
    : message.type === 'pair.active'
      ? 'awaiting_activation'
      : 'claiming';
  return parsePairingServerMessage(raw, {
    state,
    claimId: message.claimId,
    generation: 1,
    activeGeneration: 1,
  });
}

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
    case 'pair.create':
    case 'pair.status.request':
    case 'pair.cancel':
    case 'pair.approve':
    case 'pair.deny':
      return parseClientMessage(raw, 'mac');
    case 'pair.claim':
      return parseClientMessage(raw, 'pairing.claim');
    case 'pair.credential.ack':
    case 'pair.cancel.claim':
      return parseClientMessage(raw, 'pairing.claimed');
    case 'pair.created':
    case 'pair.status':
    case 'pair.claimed.mac':
    case 'pair.completed':
      return parseServerMessage(raw, 'mac');
    case 'pair.claimed.phone':
      return parsePairingServerMessage(raw, {
        state: 'claiming', claimId: message.claimId, generation: 1, activeGeneration: 1,
      });
    case 'pair.credential':
      return parsePairingServerMessage(raw, {
        state: 'awaiting_credential', claimId: message.claimId, generation: 1, activeGeneration: 1,
      });
    case 'pair.active':
      return parsePairingServerMessage(raw, {
        state: 'awaiting_activation', claimId: message.claimId, generation: 1, activeGeneration: 1,
      });
    case 'pair.failed':
      return 'requestId' in message
        ? parseServerMessage(raw, 'mac')
        : parsePairingServerMessage(raw, {
          state: 'claiming', claimId: message.claimId, generation: 1, activeGeneration: 1,
        });
    default:
      throw new Error(`fixture has unknown type ${message.type}`);
  }
}

test('timing invariants and clock-health constants match the plan', () => {
  for (const [name, holds] of INVARIANTS) assert.ok(holds, name);
  assert.equal(CLOCK_HEALTH_SAMPLES, 5);
  assert.equal(CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS, 3500);
});

test('pairing constants freeze the approved protocol and invitation lifetime', () => {
  assert.equal(relayConstants.PAIRING_VERSION, 1);
  assert.equal(relayConstants.PAIRING_TTL_MS, 300_000);
  assert.equal(relayConstants.LEGACY_PHONE_CREDENTIAL_VERSION, 0);
  assert.equal(relayConstants.CREDENTIAL_REPLACED_CLOSE_CODE, 4004);
  assert.equal(relayConstants.CREDENTIAL_REPLACED_CLOSE_REASON, 'credential_replaced');
});

test('pairing claims require an explicit unauthenticated pairing state', () => {
  const claim = load('pair.claim.json');
  const cancel = load('pair.cancel.claim.json');

  throwsCode(() => parseClientMessage(claim), 'expected_hello');
  throwsCode(() => parseClientMessage(claim, 'phone'), 'message_not_allowed_for_role');
  assert.equal(parseClientMessage(claim, 'pairing.claim').type, 'pair.claim');

  throwsCode(
    () => parseClientMessage(cancel, 'pairing.claim'),
    'message_not_allowed_for_state',
  );
  assert.equal(parseClientMessage(cancel, 'pairing.claimed').type, 'pair.cancel.claim');
});

test('prototype names cannot masquerade as pairing states', () => {
  const claim = load('pair.claim.json');
  for (const state of ['toString', 'constructor', '__proto__']) {
    throwsCode(() => parseClientMessage(claim, state), 'invalid_role');
  }
});

test('pairing messages are restricted to their exact client and server roles', () => {
  throwsCode(
    () => parseClientMessage(load('pair.create.json'), 'phone'),
    'message_not_allowed_for_role',
  );
  throwsCode(
    () => parseServerMessage(load('pair.created.json'), 'phone'),
    'message_not_allowed_for_role',
  );
  throwsCode(
    () => parseServerMessage(load('pair.credential.json'), 'mac'),
    'message_not_allowed_for_role',
  );
});

test('server pairing messages require the current dedicated claimant context', () => {
  const claimed = object('pair.claimed.phone.json');
  const raw = JSON.stringify(claimed);
  const current = {
    state: 'claiming', claimId: claimed.claimId, generation: 7, activeGeneration: 7,
  };

  throwsCode(() => parseServerMessage(raw, 'phone'), 'message_not_allowed_for_role');
  assert.equal(parsePairingServerMessage(raw, current).type, 'pair.claimed.phone');
  throwsCode(
    () => parsePairingServerMessage(raw, { ...current, state: 'awaiting_credential' }),
    'message_not_allowed_for_state',
  );
  throwsCode(
    () => parsePairingServerMessage(raw, {
      ...current, claimId: '018f63f5-6f3d-7d21-88bc-9ef561f030e3',
    }),
    'claim_mismatch',
  );
  throwsCode(
    () => parsePairingServerMessage(raw, { ...current, activeGeneration: 8 }),
    'stale_generation',
  );
});

test('claimant context fields must be own data properties', () => {
  const claimed = object('pair.claimed.phone.json');
  const raw = JSON.stringify(claimed);
  const current = {
    state: 'claiming',
    claimId: claimed.claimId,
    generation: 7,
    activeGeneration: 7,
  };
  throwsCode(
    () => parsePairingServerMessage(raw, Object.create(current)),
    'missing_field',
  );

  for (const key of Object.keys(current)) {
    let getterCalls = 0;
    const accessor = { ...current };
    Object.defineProperty(accessor, key, {
      enumerable: true,
      get() {
        getterCalls += 1;
        return current[key];
      },
    });
    assert.throws(() => parsePairingServerMessage(raw, accessor), ProtocolError);
    assert.equal(getterCalls, 0, `${key} getter must not run`);
  }

  const descriptorReads = new Map();
  const proxy = new Proxy(current, {
    get() {
      throw new Error('context properties must not be read after capture');
    },
    getOwnPropertyDescriptor(target, key) {
      descriptorReads.set(key, (descriptorReads.get(key) ?? 0) + 1);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.equal(parsePairingServerMessage(raw, proxy).type, claimed.type);
  assert.deepEqual(Object.fromEntries(descriptorReads), {
    state: 1,
    claimId: 1,
    generation: 1,
    activeGeneration: 1,
  });
});

test('ordinary server parsing never accepts claimant pairing frames without an authenticated role', () => {
  for (const name of [
    'pair.claimed.phone.json',
    'pair.credential.json',
    'pair.active.json',
    'pair.failed.claimant.json',
  ]) {
    const raw = load(name);
    throwsCode(() => parseServerMessage(raw, null), 'invalid_role');
    throwsCode(() => parseServerMessage(raw, undefined), 'message_not_allowed_for_role');
  }
});

test('pairing status is an explicit capability-gated request and legacy version zero is enrolled', () => {
  const request = object('pair.status.request.json');
  const status = object('pair.status.json');

  assert.equal(parseClientMessage(JSON.stringify(request), 'mac').type, 'pair.status.request');
  throwsCode(
    () => parseClientMessage(JSON.stringify(request), 'phone'),
    'message_not_allowed_for_role',
  );
  assert.equal(status.requestId, request.requestId);
  assert.equal(status.enrollmentState, 'legacy');
  assert.equal(status.activePhoneCredentialVersion, relayConstants.LEGACY_PHONE_CREDENTIAL_VERSION);
  assert.equal(parseServerMessage(JSON.stringify(status), 'mac').type, 'pair.status');

  for (const mismatch of [
    { ...status, enrollmentState: 'paired' },
    { ...status, activePhoneCredentialVersion: 1 },
  ]) {
    throwsCode(() => parseServerMessage(JSON.stringify(mismatch), 'mac'), 'invalid_value');
  }
});

test('credential rotation reserves version zero exclusively for legacy enrollment status', () => {
  const cases = [
    [object('pair.credential.json'), parsePairingFixture],
    [object('pair.credential.ack.json'), (raw) => parseClientMessage(raw, 'pairing.claimed')],
    [object('pair.active.json'), parsePairingFixture],
    [object('pair.completed.json'), (raw) => parseServerMessage(raw, 'mac')],
  ];

  for (const [message, parse] of cases) {
    const versionField = Object.hasOwn(message, 'credentialVersion')
      ? 'credentialVersion'
      : 'activePhoneCredentialVersion';
    throwsCode(() => parse(JSON.stringify({ ...message, [versionField]: 0 })), 'invalid_value');
  }
});

test('pairing references are canonical unpadded base64url encodings of exactly 32 bytes', () => {
  const claim = object('pair.claim.json');
  assert.equal(claim.reference, 'A'.repeat(43));
  assert.doesNotThrow(() => parseClientMessage(JSON.stringify(claim), 'pairing.claim'));

  for (const reference of [
    `${'A'.repeat(42)}B`,
    `${'A'.repeat(43)}=`,
    `${'A'.repeat(42)}+`,
    'A'.repeat(42),
  ]) {
    throwsCode(
      () => parseClientMessage(JSON.stringify({ ...claim, reference }), 'pairing.claim'),
      'invalid_reference',
    );
  }
});

test('pair.failed accepts only the three role-specific exact shapes', () => {
  assert.doesNotThrow(() => parseServerMessage(load('pair.failed.mac-before-claim.json'), 'mac'));
  assert.doesNotThrow(() => parseServerMessage(load('pair.failed.mac-after-claim.json'), 'mac'));
  assert.doesNotThrow(() => parsePairingFixture(load('pair.failed.claimant.json')));

  const mixed = {
    ...object('pair.failed.claimant.json'),
    requestId: object('pair.failed.mac-before-claim.json').requestId,
  };
  throwsCode(
    () => parsePairingFixture(JSON.stringify(mixed)),
    'message_not_allowed_for_role',
  );
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

test('object-valued versions never invoke attacker-controlled coercion', () => {
  const hostileVersion = { toString: null, valueOf: null };
  const clientRaw = JSON.stringify({ ...object('hello.phone.json'), v: hostileVersion });
  const serverRaw = JSON.stringify({ ...object('hello.ok.json'), v: hostileVersion });

  throwsCode(() => parseClientMessage(clientRaw), 'unsupported_version');
  throwsCode(() => parseServerMessage(serverRaw, 'phone'), 'unsupported_version');
});

test('object-valued hello.ok roles never invoke attacker-controlled coercion', () => {
  const raw = JSON.stringify({
    ...object('hello.ok.json'),
    role: { toString: null, valueOf: null },
  });

  throwsCode(() => parseServerMessage(raw, 'phone'), 'message_not_allowed_for_role');
});

test('unknown types and fields are rejected', () => {
  throwsCode(() => parseClientMessage('{"type":"unknown","v":1}'), 'unknown_type');
  const hello = object('hello.phone.json');
  throwsCode(() => parseClientMessage(JSON.stringify({ ...hello, extra: true })), 'unknown_field');
});

test('prototype property names are unknown types at parse and encode boundaries', () => {
  for (const type of ['toString', 'constructor', '__proto__']) {
    const raw = JSON.stringify({ type, v: 1 });
    throwsCode(() => parseClientMessage(raw), 'unknown_type');
    throwsCode(() => parseServerMessage(raw, 'phone'), 'unknown_type');
    throwsCode(() => encodeMessage({ type, v: 1 }), 'unknown_type');
  }
});

function assertProxyRoleRejected(parse, raw) {
  let roleTraps = 0;
  const role = new Proxy({}, {
    get() {
      roleTraps += 1;
      throw new Error('role proxy must not be inspected');
    },
    getOwnPropertyDescriptor() {
      roleTraps += 1;
      throw new Error('role proxy must not be inspected');
    },
  });

  throwsCode(() => parse(raw, role), 'invalid_role');
  assert.equal(roleTraps, 0);
}

test('parseClientMessage rejects proxy-valued roles without invoking user code', () => {
  assertProxyRoleRejected(parseClientMessage, load('action.request.json'));
});

test('parseServerMessage rejects proxy-valued roles without invoking user code', () => {
  assertProxyRoleRejected(parseServerMessage, load('mac.state.json'));
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

    const messageType = descriptor.kind === 'message' ? descriptor.message?.type : null;
    const isPairingServer = descriptor.parser === 'server'
      && descriptor.role === 'phone'
      && ['pair.claimed.phone', 'pair.credential', 'pair.active', 'pair.failed'].includes(messageType);
    const parse = isPairingServer
      ? () => parsePairingFixture(raw)
      : descriptor.parser === 'server'
        ? () => parseServerMessage(raw, descriptor.role)
        : () => parseClientMessage(raw, descriptor.role);
    throwsCode(parse, descriptor.expectedError, name);
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

test('encodeMessage requires own data properties and snapshots descriptors once', () => {
  const cancel = object('pair.cancel.json');
  throwsCode(() => encodeMessage(Object.create(cancel)), 'missing_type');

  for (const key of Object.keys(cancel)) {
    let getterCalls = 0;
    const accessor = { ...cancel };
    Object.defineProperty(accessor, key, {
      enumerable: true,
      get() {
        getterCalls += 1;
        return cancel[key];
      },
    });
    assert.throws(() => encodeMessage(accessor), ProtocolError);
    assert.equal(getterCalls, 0, `${key} getter must not run`);
  }

  const descriptorReads = new Map();
  const proxy = new Proxy(cancel, {
    get() {
      throw new Error('message properties must not be read after capture');
    },
    getOwnPropertyDescriptor(target, key) {
      descriptorReads.set(key, (descriptorReads.get(key) ?? 0) + 1);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.equal(encodeMessage(proxy), JSON.stringify(cancel));
  assert.deepEqual(
    Object.fromEntries(descriptorReads),
    { type: 1, v: 1, requestId: 1 },
  );
});

test('encodeMessage rejects proxy-valued versions without invoking user code', () => {
  const cancel = object('pair.cancel.json');
  let versionReads = 0;
  const version = new Proxy({}, {
    get() {
      versionReads += 1;
      throw new Error('version proxy must not be inspected');
    },
  });

  throwsCode(() => encodeMessage({ ...cancel, v: version }), 'unsupported_version');
  assert.equal(versionReads, 0);
});
