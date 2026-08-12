// The Swift client cannot import JavaScript, so PhoneWireProtocol.swift holds a
// hand-written copy of every cross-language timing value and close code. Message
// *shapes* are already protected — both sides decode the same
// contracts/fixtures corpus — but
// nothing protected the values, so changing a timeout here and forgetting Swift
// would silently leave one client on a different reconnect schedule.
//
// This file and its Swift counterpart (PhoneWireProtocolTests.testRuntimeConstantsMatchSharedFixture)
// both assert against contracts/config/runtime-constants.json, so a one-sided
// edit fails a build instead of drifting.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import * as runtime from '../public/runtime-constants.js';
import * as wire from '../public/wire-protocol.js';
import * as relayConstants from '../src/constants.js';

const CONFIG = join(dirname(fileURLToPath(import.meta.url)), '../../contracts/config');
const canonical = JSON.parse(readFileSync(join(CONFIG, 'runtime-constants.json'), 'utf8'));

const RUNTIME_KEYS = {
  heartbeatIntervalMs: 'HEARTBEAT_INTERVAL_MS',
  heartbeatTimeoutMs: 'HEARTBEAT_TIMEOUT_MS',
  clockSkewToleranceMs: 'CLOCK_SKEW_TOLERANCE_MS',
  clockHealthSamples: 'CLOCK_HEALTH_SAMPLES',
  clockHealthExchangeTimeoutMs: 'CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS',
  clockHealthRefreshMs: 'CLOCK_HEALTH_REFRESH_MS',
  phoneResultTimeoutMs: 'PHONE_RESULT_TIMEOUT_MS',
  phoneReconnectBaseMs: 'PHONE_RECONNECT_BASE_MS',
  phoneReconnectCapMs: 'PHONE_RECONNECT_CAP_MS',
};

const ALL_RELAY_RUNTIME_EXPORTS = [
  ...Object.values(RUNTIME_KEYS),
  'KEEPWARM_INTERVAL_MS',
];

const WIRE_KEYS = {
  actionLifetimeMs: 'ACTION_LIFETIME_MS',
  maxMessageBytes: 'MAX_MESSAGE_BYTES',
  protocolVersion: 'PROTOCOL_VERSION',
  pairingVersion: 'PAIRING_VERSION',
  pairingTtlMs: 'PAIRING_TTL_MS',
  phoneTakenOverCloseCode: 'PHONE_TAKEN_OVER_CLOSE_CODE',
  authenticationRejectedCloseCode: 'AUTHENTICATION_REJECTED_CLOSE_CODE',
  credentialReplacedCloseCode: 'CREDENTIAL_REPLACED_CLOSE_CODE',
};

test('the PWA runtime constants match the shared fixture', () => {
  for (const [fixtureKey, moduleKey] of Object.entries(RUNTIME_KEYS)) {
    assert.equal(runtime[moduleKey], canonical[fixtureKey],
      `${moduleKey} drifted from contracts/config/runtime-constants.json`);
  }
});

test('the wire protocol constants match the shared fixture', () => {
  for (const [fixtureKey, moduleKey] of Object.entries(WIRE_KEYS)) {
    assert.equal(wire[moduleKey], canonical[fixtureKey],
      `${moduleKey} drifted from contracts/config/runtime-constants.json`);
  }
});

test('the relay re-exports the shared values rather than redefining them', () => {
  // src/constants.js previously kept its own copy of all ten timing values while
  // claiming in its header to be the single source of truth for the PWA, which
  // imports the public module instead. Re-export identity is what prevents that
  // from coming back.
  for (const moduleKey of ALL_RELAY_RUNTIME_EXPORTS) {
    assert.equal(relayConstants[moduleKey], runtime[moduleKey],
      `${moduleKey} is redefined in src/constants.js instead of re-exported`);
  }
  for (const moduleKey of Object.values(WIRE_KEYS)) {
    assert.equal(relayConstants[moduleKey], wire[moduleKey],
      `${moduleKey} is redefined in src/constants.js instead of re-exported`);
  }
});

test('the fixture and explicit Swift mirror map cover the same values', () => {
  // The Swift test reads every fixture key asserted here. Keep this explicit
  // map and the reviewed fixture aligned when the cross-language mirror grows.
  const covered = new Set([...Object.keys(RUNTIME_KEYS), ...Object.keys(WIRE_KEYS)]);
  const declared = Object.keys(canonical).filter((k) => !k.startsWith('_'));
  assert.deepEqual(declared.slice().sort(), [...covered].sort(),
    'contracts/config/runtime-constants.json and this test disagree on coverage');
});

test('the two terminal close codes are distinct', () => {
  // Sharing 4004 made a reclaimable takeover indistinguishable from a dead
  // credential, so both clients offered a reclaim that could only fail auth.
  assert.notEqual(canonical.phoneTakenOverCloseCode, canonical.credentialReplacedCloseCode);
  assert.notEqual(canonical.credentialReplacedCloseCode, canonical.authenticationRejectedCloseCode);
});
