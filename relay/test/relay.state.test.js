import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { RelayState } from '../src/relay.js';
import {
  ACTION_LIFETIME_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  PROTOCOL_VERSION,
} from '../src/constants.js';

function harness({ start = 1_800_000_000_000, authorizePhone = () => true } = {}) {
  let wallNow = start;
  let monotonicUs = 100;
  let nextTimer = 0;
  const timers = new Map();
  const events = [];
  const logs = [];
  const state = new RelayState({
    now: () => wallNow,
    monotonicNowUs: () => monotonicUs,
    schedule: (fn, ms) => {
      const id = ++nextTimer;
      timers.set(id, { fn, ms });
      return id;
    },
    cancel: (id) => timers.delete(id),
    emit: (connection, event) => {
      events.push({ connection, event });
      return true;
    },
    authorizePhone,
    log: (event, detail = {}) => logs.push({ event, detail }),
  });
  const connection = (id) => Object.freeze({ id });
  const messages = (conn, type) => events
    .filter((entry) => entry.connection === conn
      && entry.event.kind === 'message'
      && (!type || entry.event.message.type === type))
    .map((entry) => entry.event.message);
  return {
    state,
    events,
    logs,
    timers,
    connection,
    messages,
    advanceWall(ms) { wallNow += ms; },
    advanceMonotonic(us) { monotonicUs += us; },
    fireAllTimers() {
      const pending = [...timers.values()];
      timers.clear();
      for (const { fn } of pending) fn();
    },
  };
}

const action = (now, overrides = {}) => ({
  type: 'action.request',
  v: PROTOCOL_VERSION,
  actionId: randomUUID(),
  action: 'click',
  issuedAtUnixMs: now,
  expiresAtUnixMs: now + ACTION_LIFETIME_MS,
  ...overrides,
});

const posted = (actionId, now) => ({
  type: 'action.result',
  v: PROTOCOL_VERSION,
  actionId,
  status: 'posted',
  reason: 'ok',
  acceptedVia: 'oci',
  macProcessingUs: 800,
  mouseDownPostedUnixMs: now,
});

test('a displaced phone receives the terminal takeover close without clearing its replacement', () => {
  const h = harness();
  const first = h.connection('phone-a');
  const replacement = h.connection('phone-b');

  h.state.replaceRole('phone', first);
  h.state.replaceRole('phone', replacement);

  assert.deepEqual(h.events.at(-1), {
    connection: first,
    event: { kind: 'close', code: 4004, reason: 'another phone took over' },
  });
  assert.equal(h.state.detachIfCurrent('phone', first), false);
  assert.equal(h.state.phone, replacement);
  assert.equal(h.state.detachIfCurrent('phone', replacement), true);
  assert.equal(h.state.phone, null);
});

test('Mac replacement retains the existing reconnectable close contract', () => {
  const h = harness();
  const first = h.connection('mac-a');
  const replacement = h.connection('mac-b');

  h.state.replaceRole('mac', first);
  h.state.replaceRole('mac', replacement);

  assert.deepEqual(h.events.at(-1), {
    connection: first,
    event: { kind: 'close', code: 4000, reason: 'replaced' },
  });
});

test('Mac state propagation and disconnect reset are transport independent', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  h.state.handleMacMessage(mac, {
    type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready',
  });
  assert.deepEqual(h.messages(phone, 'state').at(-1), {
    type: 'state', v: PROTOCOL_VERSION, macOnline: true,
    remoteEnabled: true, permission: 'ready',
  });

  assert.equal(h.state.detachIfCurrent('mac', mac), true);
  assert.deepEqual(h.messages(phone, 'state').at(-1), {
    type: 'state', v: PROTOCOL_VERSION, macOnline: false,
    remoteEnabled: false, permission: 'unknown',
  });
});

test('unexpired action is forwarded once and ack remains distinct from result', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = action(1_800_000_000_000);

  h.state.handlePhoneMessage(phone, request);
  const forwarded = h.messages(mac, 'action.request');
  const acks = h.messages(phone, 'relay.ack');
  assert.equal(forwarded.length, 1);
  assert.equal(acks.length, 1);
  assert.deepEqual(
    { actionId: acks[0].actionId, status: acks[0].status, reason: acks[0].reason },
    { actionId: request.actionId, status: 'forwarded', reason: 'ok' },
  );
  assert.equal(h.state.pendingActions.size, 1);

  h.state.handleMacMessage(mac, posted(request.actionId, 1_800_000_000_050));
  assert.equal(h.messages(phone, 'action.result').length, 1);
  assert.equal(h.messages(phone, 'relay.ack').length, 1, 'result never mutates the ack');
  assert.equal(h.state.pendingActions.size, 0);
});

test('a phone that lost credential authorization cannot forward actions', () => {
  let authorized = true;
  const h = harness({ authorizePhone: () => authorized });
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);

  authorized = false;
  const outcome = h.state.handlePhoneMessage(phone, action(1_800_000_000_000));

  assert.equal(outcome, 'ignored');
  assert.equal(h.messages(mac, 'action.request').length, 0);
  assert.deepEqual(h.logs.at(-1), {
    event: 'stale_phone_credential',
    detail: { type: 'action.request' },
  });
});

test('mac_offline acknowledgement is terminal and creates no route', () => {
  const h = harness();
  const phone = h.connection('phone');
  h.state.replaceRole('phone', phone);
  const request = action(1_800_000_000_000);
  h.state.handlePhoneMessage(phone, request);
  assert.deepEqual(
    h.messages(phone, 'relay.ack').map(({ status, reason }) => ({ status, reason })),
    [{ status: 'mac_offline', reason: 'mac_offline' }],
  );
  assert.equal(h.state.pendingActions.size, 0);
});

test('expired action is rejected before forwarding and creates no route', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const issued = 1_800_000_000_000 - ACTION_LIFETIME_MS - CLOCK_SKEW_TOLERANCE_MS - 1;
  const request = action(issued);
  h.state.handlePhoneMessage(phone, request);
  assert.equal(h.messages(mac, 'action.request').length, 0);
  assert.deepEqual(
    h.messages(phone, 'relay.ack').map(({ status, reason }) => ({ status, reason })),
    [{ status: 'rejected', reason: 'expired' }],
  );
  assert.equal(h.state.pendingActions.size, 0);
});

test('future-issued action is accepted at clock skew tolerance and rejected one millisecond beyond it', () => {
  const now = 1_800_000_000_000;
  const h = harness({ start: now });
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);

  const boundary = action(now + CLOCK_SKEW_TOLERANCE_MS);
  h.state.handlePhoneMessage(phone, boundary);
  assert.equal(h.messages(mac, 'action.request').length, 1);
  assert.equal(h.state.pendingActions.size, 1);
  h.state.handleMacMessage(mac, posted(boundary.actionId, now));

  const future = action(now + CLOCK_SKEW_TOLERANCE_MS + 1);
  h.state.handlePhoneMessage(phone, future);
  assert.equal(h.messages(mac, 'action.request').length, 1);
  assert.deepEqual(
    h.messages(phone, 'relay.ack').map(({ actionId, status, reason }) => ({ actionId, status, reason })).at(-1),
    { actionId: future.actionId, status: 'rejected', reason: 'invalid_request' },
  );
  assert.equal(h.state.pendingActions.size, 0);
});

test('duplicate in-flight action is rejected and never forwarded twice', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = action(1_800_000_000_000);
  h.state.handlePhoneMessage(phone, request);
  h.state.handlePhoneMessage(phone, request);
  assert.equal(h.messages(mac, 'action.request').length, 1);
  assert.deepEqual(
    h.messages(phone, 'relay.ack').map(({ status, reason }) => ({ status, reason })),
    [
      { status: 'forwarded', reason: 'ok' },
      { status: 'rejected', reason: 'invalid_request' },
    ],
  );
});

test('result route belongs to the originating current phone, not its replacement', () => {
  const h = harness();
  const first = h.connection('phone-a');
  const replacement = h.connection('phone-b');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', first);
  h.state.replaceRole('mac', mac);
  const request = action(1_800_000_000_000);
  h.state.handlePhoneMessage(first, request);
  h.state.replaceRole('phone', replacement);

  assert.equal(h.state.handleMacMessage(mac, posted(request.actionId, 1_800_000_000_050)), 'ignored');
  assert.equal(h.messages(replacement, 'action.result').length, 0);
  assert.equal(h.state.pendingActions.size, 0);
});

test('pending action route expiry cancels delivery', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = action(1_800_000_000_000);
  h.state.handlePhoneMessage(phone, request);
  assert.equal(h.timers.size, 1);
  h.fireAllTimers();
  assert.equal(h.state.pendingActions.size, 0);
  assert.equal(h.state.handleMacMessage(mac, posted(request.actionId, 1_800_000_000_050)), 'ignored');
  assert.equal(h.messages(phone, 'action.result').length, 0);
});

test('time-sync forwarding, response routing, and expiry', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = {
    type: 'time.sync.request', v: PROTOCOL_VERSION,
    syncId: randomUUID(), phoneSendUnixMs: 1_800_000_000_000,
  };
  h.state.handlePhoneMessage(phone, request);
  assert.deepEqual(h.messages(mac, 'time.sync.request'), [request]);
  h.state.handleMacMessage(mac, {
    type: 'time.sync.response', v: PROTOCOL_VERSION, syncId: request.syncId,
    phoneSendUnixMs: request.phoneSendUnixMs,
    macReceiveUnixMs: request.phoneSendUnixMs + 10,
    macSendUnixMs: request.phoneSendUnixMs + 11,
  });
  assert.equal(h.messages(phone, 'time.sync.response').length, 1);
  assert.equal(h.state.pendingSync.size, 0);

  const expiring = { ...request, syncId: randomUUID() };
  h.state.handlePhoneMessage(phone, expiring);
  h.fireAllTimers();
  assert.equal(h.state.pendingSync.size, 0);
  assert.equal(h.state.handleMacMessage(mac, {
    type: 'time.sync.response', v: PROTOCOL_VERSION, syncId: expiring.syncId,
    phoneSendUnixMs: expiring.phoneSendUnixMs,
    macReceiveUnixMs: expiring.phoneSendUnixMs + 10,
    macSendUnixMs: expiring.phoneSendUnixMs + 11,
  }), 'ignored');
});

test('diagnostic forwarding, counter routing, and expiry', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = {
    type: 'diagnostics.request', v: PROTOCOL_VERSION, requestId: randomUUID(),
  };
  h.state.handlePhoneMessage(phone, request);
  assert.deepEqual(h.messages(mac, 'diagnostics.request'), [request]);
  h.state.handleMacMessage(mac, {
    type: 'diagnostics.counters', v: PROTOCOL_VERSION, requestId: request.requestId,
    mouseDownPostCount: 1, mouseUpPostCount: 1,
  });
  assert.equal(h.messages(phone, 'diagnostics.counters').length, 1);
  assert.equal(h.state.pendingDiagnostics.size, 0);

  h.state.handlePhoneMessage(phone, { ...request, requestId: randomUUID() });
  h.fireAllTimers();
  assert.equal(h.state.pendingDiagnostics.size, 0);
});

test('heartbeat works for either role and stale sockets have no side effects', () => {
  const h = harness();
  const phoneA = h.connection('phone-a');
  const phoneB = h.connection('phone-b');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phoneA);
  h.state.replaceRole('phone', phoneB);
  h.state.replaceRole('mac', mac);
  assert.equal(h.state.handlePhoneMessage(phoneA, {
    type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 1,
  }), 'ignored');
  h.state.handlePhoneMessage(phoneB, {
    type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 2,
  });
  h.state.handleMacMessage(mac, {
    type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 3,
  });
  assert.deepEqual(h.messages(phoneB, 'heartbeat.ack').map((m) => m.sequence), [2]);
  assert.deepEqual(h.messages(mac, 'heartbeat.ack').map((m) => m.sequence), [3]);
});

test('phone disconnect drops every route it owns and dispose cancels timers', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  h.state.handlePhoneMessage(phone, action(1_800_000_000_000));
  h.state.handlePhoneMessage(phone, {
    type: 'time.sync.request', v: PROTOCOL_VERSION,
    syncId: randomUUID(), phoneSendUnixMs: 1_800_000_000_000,
  });
  h.state.handlePhoneMessage(phone, {
    type: 'diagnostics.request', v: PROTOCOL_VERSION, requestId: randomUUID(),
  });
  assert.equal(h.timers.size, 3);
  h.state.detachIfCurrent('phone', phone);
  assert.equal(h.state.pendingActions.size, 0);
  assert.equal(h.state.pendingSync.size, 0);
  assert.equal(h.state.pendingDiagnostics.size, 0);
  assert.equal(h.timers.size, 0);

  h.state.replaceRole('phone', phone);
  h.state.handlePhoneMessage(phone, action(1_800_000_000_000));
  h.state.dispose();
  assert.equal(h.timers.size, 0);
});

test('routes retain only owner and timer metadata, never request bodies', () => {
  const h = harness();
  const phone = h.connection('phone');
  const mac = h.connection('mac');
  h.state.replaceRole('phone', phone);
  h.state.replaceRole('mac', mac);
  const request = action(1_800_000_000_000);
  h.state.handlePhoneMessage(phone, request);
  assert.deepEqual(Object.keys(h.state.pendingActions.get(request.actionId)).sort(), ['owner', 'timer']);
});
