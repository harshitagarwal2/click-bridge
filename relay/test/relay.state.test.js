// RelayState logic, exercised with fake connections.
// Requires no third-party dependency, so it runs before `npm install`.

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { RelayState } from '../src/relay.js';
import {
  PROTOCOL_VERSION,
  ACTION_LIFETIME_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  CLOSE_ROLE_REPLACED,
} from '../src/constants.js';

function fakeConn(name) {
  return {
    name, sent: [], closed: false, closeCode: null,
    send(s) { this.sent.push(JSON.parse(s)); },
    close(code = null) { this.closed = true; this.closeCode = code; },
  };
}

const req = (overrides = {}) => {
  const issued = Date.now();
  return {
    type: 'action.request', v: PROTOCOL_VERSION,
    actionId: randomUUID(), action: 'click',
    issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS,
    ...overrides,
  };
};

const result = (actionId, overrides = {}) => ({
  type: 'action.result', v: PROTOCOL_VERSION, actionId,
  status: 'posted', reason: 'ok', acceptedVia: 'oci',
  macProcessingUs: 800, mouseDownPostedUnixMs: Date.now(),
  ...overrides,
});

const macState = (remoteEnabled, permission) => ({
  type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled, permission,
});

// ---------------------------------------------------------------------------

test('old socket close cannot clear its replacement', () => {
  const s = new RelayState();
  const first = fakeConn('first');
  const second = fakeConn('second');

  s.replaceRole('phone', first);
  s.replaceRole('phone', second);
  assert.equal(first.closed, true, 'displaced socket is closed');

  // The displaced socket's close callback arrives late.
  assert.equal(s.detachIfCurrent('phone', first), false, 'must not detach');
  assert.equal(s.phone, second, 'replacement survives');

  assert.equal(s.detachIfCurrent('phone', second), true);
  assert.equal(s.phone, null);

  s.dispose();
});

test('a displaced socket is closed with a distinct application code', () => {
  // A bare close() reaches the browser as 1005, which is indistinguishable
  // from a network drop — so the displaced client reconnects, displaces its
  // replacement, and the two ping-pong forever. The code is the whole fix.
  for (const role of ['phone', 'mac']) {
    const s = new RelayState();
    const first = fakeConn('first');
    s.replaceRole(role, first);
    s.replaceRole(role, fakeConn('second'));

    assert.equal(first.closed, true, `${role}: displaced socket closed`);
    assert.equal(first.closeCode, CLOSE_ROLE_REPLACED, `${role}: wrong close code`);
    s.dispose();
  }
});

test('re-installing the same connection does not close it', () => {
  const s = new RelayState();
  const only = fakeConn('only');
  s.replaceRole('phone', only);
  s.replaceRole('phone', only);
  assert.equal(only.closed, false, 'a socket must not evict itself');
  s.dispose();
});

test("a result is never delivered to a replaced phone's replacement", () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phoneA = fakeConn('A');
  const phoneB = fakeConn('B');

  s.replaceRole('mac', mac);
  s.replaceRole('phone', phoneA);

  const r = req();
  s.handleMessage('phone', phoneA, JSON.stringify(r));
  assert.equal(s.pending.size, 1);

  s.replaceRole('phone', phoneB);           // B takes over mid-flight
  const outcome = s.handleMessage('mac', mac, JSON.stringify(result(r.actionId)));

  assert.equal(outcome, 'ignored');
  assert.equal(phoneB.sent.filter((m) => m.type === 'action.result').length, 0);
  s.dispose();
});

test('a frame from an already-replaced socket is ignored', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phoneA = fakeConn('A');
  const phoneB = fakeConn('B');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phoneA);
  s.replaceRole('phone', phoneB);

  assert.equal(s.handleMessage('phone', phoneA, JSON.stringify(req())), 'ignored');
  assert.equal(s.pending.size, 0);
  s.dispose();
});

test('expired requests are rejected and never routed', () => {
  const issued = Date.now() - (ACTION_LIFETIME_MS + CLOCK_SKEW_TOLERANCE_MS + 500);
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);

  s.handleMessage('phone', phone, JSON.stringify(
    req({ issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS })));

  assert.equal(phone.sent.find((m) => m.type === 'relay.ack').status, 'rejected');
  assert.equal(s.pending.size, 0, 'no route created');
  assert.equal(mac.sent.length, 0, 'nothing forwarded');
  s.dispose();
});

test('a request inside the skew tolerance is still forwarded', () => {
  const issued = Date.now() - (ACTION_LIFETIME_MS + CLOCK_SKEW_TOLERANCE_MS - 300);
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);

  s.handleMessage('phone', phone, JSON.stringify(
    req({ issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS })));

  assert.equal(phone.sent.find((m) => m.type === 'relay.ack').status, 'forwarded');
  s.dispose();
});

test('mac_offline is acknowledged without a route', () => {
  const s = new RelayState();
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  s.handleMessage('phone', phone, JSON.stringify(req()));
  assert.equal(phone.sent.find((m) => m.type === 'relay.ack').status, 'mac_offline');
  assert.equal(s.pending.size, 0);
  s.dispose();
});

test('pending routes expire on the injected clock', () => {
  const timers = new Map();
  let seq = 0;
  const s = new RelayState({
    setTimeout: (fn) => { timers.set(++seq, fn); return seq; },
    clearTimeout: (id) => timers.delete(id),
    pendingTtlMs: 3000,
  });
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);

  const r = req();
  s.handleMessage('phone', phone, JSON.stringify(r));
  assert.equal(s.pending.size, 1);

  for (const fn of [...timers.values()]) fn();     // fire the TTL
  assert.equal(s.pending.size, 0, 'route expired');

  assert.equal(s.handleMessage('mac', mac, JSON.stringify(result(r.actionId))), 'ignored');
  s.dispose();
});

test('a late result with no route is ignored', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);
  assert.equal(
    s.handleMessage('mac', mac, JSON.stringify(result(randomUUID()))), 'ignored');
  assert.equal(phone.sent.filter((m) => m.type === 'action.result').length, 0);
  s.dispose();
});

test('mac state propagates to the phone', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  s.replaceRole('mac', mac);
  s.handleMessage('mac', mac, JSON.stringify(macState(true, 'ready')));

  const last = phone.sent.at(-1);
  assert.equal(last.type, 'state');
  assert.deepEqual(
    { macOnline: last.macOnline, remoteEnabled: last.remoteEnabled, permission: last.permission },
    { macOnline: true, remoteEnabled: true, permission: 'ready' });
  s.dispose();
});

test('mac disconnect publishes macOnline false and clears stale state', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  s.replaceRole('mac', mac);
  s.handleMessage('mac', mac, JSON.stringify(macState(true, 'ready')));
  assert.equal(phone.sent.at(-1).macOnline, true);

  s.detachIfCurrent('mac', mac);
  const last = phone.sent.at(-1);
  assert.equal(last.macOnline, false);
  assert.equal(last.remoteEnabled, false, 'stale mac state is cleared');
  assert.equal(last.permission, 'unknown');
  s.dispose();
});

test('a fresh Mac does not inherit the previous Mac state', () => {
  const s = new RelayState();
  const phone = fakeConn('phone');
  const macA = fakeConn('macA');
  const macB = fakeConn('macB');
  s.replaceRole('phone', phone);
  s.replaceRole('mac', macA);
  s.handleMessage('mac', macA, JSON.stringify(macState(true, 'ready')));

  s.replaceRole('mac', macB);
  s.publishState();
  const last = phone.sent.at(-1);
  assert.equal(last.remoteEnabled, false);
  assert.equal(last.permission, 'unknown');
  s.dispose();
});

test('invalid frames after authentication are ignored, not fatal', () => {
  const s = new RelayState();
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  for (const bad of ['{not json', '{"type":"nope","v":1}', '{"type":"hello","v":1}', '[]']) {
    assert.equal(s.handleMessage('phone', phone, bad), 'ignored');
  }
  assert.equal(phone.closed, false, 'socket stays open');
  s.dispose();
});

test('a phone may not send mac-only messages', () => {
  const s = new RelayState();
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  assert.equal(
    s.handleMessage('phone', phone, JSON.stringify(macState(true, 'ready'))), 'ignored');
  s.dispose();
});

test('duplicate in-flight actionId is rejected and forwarded once', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);
  const r = req();
  s.handleMessage('phone', phone, JSON.stringify(r));
  s.handleMessage('phone', phone, JSON.stringify(r));

  const acks = phone.sent.filter((m) => m.type === 'relay.ack');
  assert.equal(acks[0].status, 'forwarded');
  assert.equal(acks[1].status, 'rejected');
  assert.equal(mac.sent.filter((m) => m.type === 'action.request').length, 1);
  s.dispose();
});

test('heartbeat is acknowledged with the same sequence', () => {
  const s = new RelayState();
  const phone = fakeConn('phone');
  s.replaceRole('phone', phone);
  s.handleMessage('phone', phone, JSON.stringify(
    { type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 42 }));
  const ack = phone.sent.at(-1);
  assert.equal(ack.type, 'heartbeat.ack');
  assert.equal(ack.sequence, 42);
  s.dispose();
});

test('time sync is forwarded and routed back to the originating phone', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);

  const syncId = randomUUID();
  const t0 = Date.now();
  s.handleMessage('phone', phone, JSON.stringify(
    { type: 'time.sync.request', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs: t0 }));
  assert.equal(mac.sent.at(-1).type, 'time.sync.request');
  assert.equal(s.syncPending.size, 1);

  s.handleMessage('mac', mac, JSON.stringify({
    type: 'time.sync.response', v: PROTOCOL_VERSION, syncId,
    phoneSendUnixMs: t0, macReceiveUnixMs: t0 + 30, macSendUnixMs: t0 + 31,
  }));
  assert.equal(phone.sent.at(-1).type, 'time.sync.response');
  assert.equal(s.syncPending.size, 0, 'route consumed');
  s.dispose();
});

test('phone disconnect drops its routes', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);
  s.handleMessage('phone', phone, JSON.stringify(req()));
  assert.equal(s.pending.size, 1);

  s.detachIfCurrent('phone', phone);
  assert.equal(s.pending.size, 0, 'routes cleared on disconnect');
  s.dispose();
});

test('relay never retains a request body', () => {
  const s = new RelayState();
  const mac = fakeConn('mac');
  const phone = fakeConn('phone');
  s.replaceRole('mac', mac);
  s.replaceRole('phone', phone);
  const r = req();
  s.handleMessage('phone', phone, JSON.stringify(r));

  const entry = s.pending.get(r.actionId);
  assert.deepEqual(Object.keys(entry).sort(), ['phone', 'timer'],
    'route holds only a socket reference and a timer');
  s.dispose();
});
