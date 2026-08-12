// TransportController owns one socket generation, one reconnect timer, and one
// heartbeat. The subtle parts — stale-generation isolation and the
// suspend-before-close gate — are exactly where a reconnect storm or a phantom
// socket would come from, so they are tested directly.

import test from 'node:test';
import assert from 'node:assert/strict';

import { TransportController } from '../public/transport-controller.js';
import {
  PROTOCOL_VERSION, HEARTBEAT_INTERVAL_MS, HEARTBEAT_TIMEOUT_MS,
  PHONE_RECONNECT_CAP_MS, CLOSE_ROLE_REPLACED,
} from '../public/constants-lite.js';

const TOKEN = '1'.repeat(64);

function fakeSocket() {
  return {
    readyState: 0,
    sent: [],
    closed: false,
    onopen: null, onmessage: null, onclose: null, onerror: null,
    send(s) { this.sent.push(JSON.parse(s)); },
    close() { this.closed = true; },
    // helpers
    open() { this.readyState = 1; this.onopen?.(); },
    deliver(obj) { this.onmessage?.({ data: JSON.stringify(obj) }); },
    deliverRaw(data) { this.onmessage?.({ data }); },
    drop() { this.readyState = 3; this.onclose?.(); },
    dropWith(code) { this.readyState = 3; this.onclose?.({ code }); },
  };
}

function harness({ token = TOKEN } = {}) {
  const sockets = [];
  const timers = new Map();
  let seq = 0;
  const statuses = [];
  const messages = [];

  const c = new TransportController({
    name: 'oci',
    url: () => 'ws://test/ws',
    token: () => token,
    onStatus: (s) => statuses.push(s),
    onMessage: (m) => messages.push(m),
    createSocket: () => { const s = fakeSocket(); sockets.push(s); return s; },
    setTimeout: (fn, ms) => { timers.set(++seq, { fn, ms }); return seq; },
    clearTimeout: (id) => timers.delete(id),
    random: () => 0.5,
  });

  return {
    c, sockets, statuses, messages, timers,
    fire(ms) {
      for (const [id, t] of [...timers]) {
        if (t.ms === ms) { timers.delete(id); t.fn(); }
      }
    },
    fireAll() {
      for (const [id, t] of [...timers]) { timers.delete(id); t.fn(); }
    },
    pending: () => [...timers.values()].map((t) => t.ms),
  };
}

/** Bring a controller to the authenticated state. */
function authenticate(h) {
  h.c.connect();
  const s = h.sockets.at(-1);
  s.open();
  s.deliver({ type: 'hello.ok', v: PROTOCOL_VERSION, role: 'phone' });
  return s;
}

// ---------------------------------------------------------------------------

test('connect authenticates with hello in the first frame', () => {
  const h = harness();
  h.c.connect();
  const s = h.sockets[0];
  s.open();

  assert.equal(s.sent.length, 1);
  assert.deepEqual(s.sent[0], {
    type: 'hello', v: PROTOCOL_VERSION, role: 'phone', token: TOKEN,
  });
});

test('the token never appears in the URL', () => {
  const h = harness();
  h.c.connect();
  assert.equal(h.c.getUrl().includes(TOKEN), false);
  assert.equal(/token=/.test(h.c.getUrl()), false);
});

test('not ready until hello.ok arrives', () => {
  const h = harness();
  h.c.connect();
  const s = h.sockets[0];
  s.open();
  assert.equal(h.c.ready, false, 'open is not authenticated');

  s.deliver({ type: 'hello.ok', v: PROTOCOL_VERSION, role: 'phone' });
  assert.equal(h.c.ready, true);
  assert.deepEqual(h.statuses, ['open']);
});

test('no socket is created without a token', () => {
  const h = harness({ token: null });
  h.c.connect();
  assert.equal(h.sockets.length, 0);
});

test('application messages are forwarded only after authentication', () => {
  const h = harness();
  h.c.connect();
  const s = h.sockets[0];
  s.open();

  s.deliver({ type: 'state', v: PROTOCOL_VERSION, macOnline: true, remoteEnabled: true, permission: 'ready' });
  assert.equal(h.messages.length, 0, 'pre-auth traffic is dropped');

  s.deliver({ type: 'hello.ok', v: PROTOCOL_VERSION, role: 'phone' });
  s.deliver({ type: 'state', v: PROTOCOL_VERSION, macOnline: true, remoteEnabled: true, permission: 'ready' });
  assert.equal(h.messages.length, 1);
  assert.equal(h.messages[0].type, 'state');
});

test('invalid frames produce no side effect at all', () => {
  const h = harness();
  const s = authenticate(h);
  const before = h.messages.length;

  s.deliverRaw('{not json');
  s.deliverRaw('{"type":"nope","v":1}');
  s.deliverRaw('{"type":"state","v":2}');            // wrong version
  s.deliverRaw('{"type":"state","v":1,"extra":1}');  // unknown field
  s.onmessage?.({ data: new Uint8Array([1, 2, 3]) }); // binary

  assert.equal(h.messages.length, before, 'nothing reached the app');
  assert.equal(h.c.ready, true, 'socket stays usable');
});

test('a phone-originated type is refused by the client validator', () => {
  const h = harness();
  const s = authenticate(h);
  // The phone must never accept a frame only it is allowed to send.
  s.deliverRaw(JSON.stringify({
    type: 'action.request', v: PROTOCOL_VERSION,
    actionId: '00000000-0000-4000-8000-000000000001',
    action: 'click', issuedAtUnixMs: 1, expiresAtUnixMs: 2001,
  }));
  assert.equal(h.messages.length, 0);
});

// -- generation isolation ----------------------------------------------------

test('a stale socket cannot deliver messages after reconnect', () => {
  const h = harness();
  const first = authenticate(h);

  h.c.reconnect();
  const second = h.sockets.at(-1);
  assert.notEqual(first, second, 'a new socket was created');

  const before = h.messages.length;
  first.deliver({ type: 'state', v: PROTOCOL_VERSION, macOnline: true, remoteEnabled: true, permission: 'ready' });
  assert.equal(h.messages.length, before, 'the old generation is inert');
});

test('a stale socket closing does not schedule a reconnect', () => {
  const h = harness();
  const first = authenticate(h);
  h.c.reconnect();
  h.timers.clear();

  first.drop();                       // the displaced socket finally closes
  assert.deepEqual(h.pending(), [], 'no reconnect scheduled by a dead generation');
});

test('reconnect creates exactly one socket and one reconnect loop', () => {
  const h = harness();
  authenticate(h);
  const countBefore = h.sockets.length;

  h.c.reconnect();
  assert.equal(h.sockets.length, countBefore + 1, 'exactly one new socket');

  const reconnectTimers = h.pending().filter((ms) => ms <= PHONE_RECONNECT_CAP_MS && ms !== HEARTBEAT_INTERVAL_MS);
  assert.ok(reconnectTimers.length <= 1, `expected at most one reconnect timer, saw ${reconnectTimers.length}`);
});

// -- the suspend gate --------------------------------------------------------

test('suspend prevents any callback from reviving the socket', () => {
  const h = harness();
  const s = authenticate(h);

  h.c.suspend();
  assert.equal(h.c.suspended, true);
  assert.equal(s.closed, true);

  h.timers.clear();
  s.drop();                            // the close callback arrives afterwards
  h.fireAll();

  assert.equal(h.sockets.length, 1, 'no reconnect happened');
  assert.equal(h.c.ready, false);
});

test('suspend then connect resumes cleanly', () => {
  const h = harness();
  authenticate(h);
  h.c.suspend();
  h.c.connect();

  assert.equal(h.c.suspended, false);
  assert.equal(h.sockets.length, 2);
});

test('a dropped socket schedules a jittered reconnect within the cap', () => {
  const h = harness();
  const s = authenticate(h);
  h.timers.clear();

  s.drop();
  assert.deepEqual(h.statuses.at(-1), 'closed');

  const delays = h.pending();
  assert.equal(delays.length, 1, 'exactly one reconnect scheduled');
  assert.ok(delays[0] >= 0 && delays[0] <= PHONE_RECONNECT_CAP_MS,
    `delay ${delays[0]} outside [0, ${PHONE_RECONNECT_CAP_MS}]`);
});

test('backoff grows but never exceeds the cap', () => {
  const h = harness();
  h.c.connect();
  const seen = [];

  for (let i = 0; i < 12; i++) {
    const s = h.sockets.at(-1);
    s.open();
    s.drop();
    const delay = h.pending().at(-1);
    seen.push(delay);
    h.fireAll();
  }

  assert.ok(Math.max(...seen) <= PHONE_RECONNECT_CAP_MS,
    `saw ${Math.max(...seen)} > cap ${PHONE_RECONNECT_CAP_MS}`);
  assert.ok(seen.at(-1) >= seen[0], 'backoff grows');
});

// -- displacement ------------------------------------------------------------
// Two phones sharing a token evict each other. If the evicted one retries, the
// pair ping-pongs forever and neither works, so 4004 must be terminal.

test('a 4004 close does not reconnect', () => {
  const h = harness();
  const s = authenticate(h);
  h.timers.clear();
  const socketsBefore = h.sockets.length;

  s.dropWith(CLOSE_ROLE_REPLACED);

  assert.deepEqual(h.pending(), [], 'no reconnect scheduled');
  h.fireAll();
  assert.equal(h.sockets.length, socketsBefore, 'no new socket opened');
  assert.equal(h.c.suspended, true, 'the gate is set');
  assert.equal(h.c.ready, false);
});

test('a 4004 close reports "replaced", not "closed"', () => {
  const h = harness();
  const s = authenticate(h);
  s.dropWith(CLOSE_ROLE_REPLACED);
  assert.equal(h.statuses.at(-1), 'replaced');
  assert.equal(h.statuses.includes('closed'), false, 'must not look like a drop');
});

test('any other close code still reconnects', () => {
  for (const code of [1000, 1001, 1005, 1006, 4001]) {
    const h = harness();
    const s = authenticate(h);
    h.timers.clear();

    s.dropWith(code);
    assert.equal(h.statuses.at(-1), 'closed', `code ${code} should be a plain drop`);
    assert.equal(h.pending().length, 1, `code ${code} should schedule a reconnect`);
  }
});

test('a replaced transport resumes only on an explicit connect', () => {
  const h = harness();
  const s = authenticate(h);
  s.dropWith(CLOSE_ROLE_REPLACED);

  // reconnect() honours the gate: a network blip must not restart the war.
  h.c.reconnect();
  assert.equal(h.sockets.length, 1, 'reconnect is inert while replaced');

  h.c.connect();                       // the deliberate user act
  assert.equal(h.sockets.length, 2);
  assert.equal(h.c.suspended, false);
});

// -- heartbeat ---------------------------------------------------------------

test('heartbeat sends on the interval and is satisfied by an ack', () => {
  const h = harness();
  const s = authenticate(h);
  const before = s.sent.length;

  h.fire(HEARTBEAT_INTERVAL_MS);
  const beat = s.sent.at(-1);
  assert.equal(s.sent.length, before + 1);
  assert.equal(beat.type, 'heartbeat.request');

  s.deliver({ type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: beat.sequence });
  assert.equal(h.c.heartbeatDeadline, null, 'deadline cleared');
});

test('a missed heartbeat ack cycles the socket', () => {
  const h = harness();
  authenticate(h);
  const socketsBefore = h.sockets.length;

  h.fire(HEARTBEAT_INTERVAL_MS);       // send the beat
  h.fire(HEARTBEAT_TIMEOUT_MS);        // no ack within the deadline

  assert.ok(h.sockets.length > socketsBefore, 'a fresh socket was opened');
});

test('the heartbeat stops once suspended', () => {
  const h = harness();
  const s = authenticate(h);
  h.c.suspend();
  const before = s.sent.length;

  h.fire(HEARTBEAT_INTERVAL_MS);
  assert.equal(s.sent.length, before, 'no beat on a suspended transport');
});

test('an ack for a stale sequence does not clear the current deadline', () => {
  const h = harness();
  const s = authenticate(h);
  h.fire(HEARTBEAT_INTERVAL_MS);
  const current = s.sent.at(-1).sequence;

  s.deliver({ type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: current + 99 });
  assert.notEqual(h.c.heartbeatDeadline, null, 'wrong sequence must not satisfy it');
});

// -- send --------------------------------------------------------------------

test('send is refused when the socket is not open', () => {
  const h = harness();
  h.c.connect();
  assert.equal(h.c.send({ type: 'x' }), false, 'not open yet');

  const s = h.sockets[0];
  s.open();
  assert.equal(h.c.send({ type: 'heartbeat.request', v: 1, sequence: 1 }), true);

  s.drop();
  assert.equal(h.c.send({ type: 'x' }), false, 'closed again');
});
