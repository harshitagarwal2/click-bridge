import test from 'node:test';
import assert from 'node:assert/strict';

import { TransportController } from '../public/transport-controller.js';
import { FakeScheduler, FakeSocket, VALID_TOKEN } from './pwa-test-helpers.js';

const helloOk = JSON.stringify({ type: 'hello.ok', v: 1, role: 'phone' });
const heartbeatAck = (sequence) => JSON.stringify({ type: 'heartbeat.ack', v: 1, sequence });
const stateFrame = JSON.stringify({
  type: 'state', v: 1, macOnline: true, remoteEnabled: true, permission: 'ready',
});

function harness() {
  const scheduler = new FakeScheduler();
  const sockets = [];
  const messages = [];
  const statuses = [];
  const controller = new TransportController({
    url: 'wss://click.example/ws',
    token: () => VALID_TOKEN,
    role: 'phone',
    createSocket: () => { const socket = new FakeSocket(); sockets.push(socket); return socket; },
    clock: { now: () => scheduler.now },
    scheduler,
    random: () => 1,
    onMessage: (message) => messages.push(message),
    onStatus: (status) => statuses.push(status),
  });
  const authenticate = () => {
    controller.connect();
    sockets.at(-1).open();
    sockets.at(-1).message(helloOk);
  };
  return { controller, scheduler, sockets, messages, statuses, authenticate };
}

test('hello authenticates in the frame and never in the URL', () => {
  const { controller, sockets } = harness();
  controller.connect();
  assert.equal(sockets.length, 1);
  sockets[0].open();
  assert.equal(sockets[0].sent[0].type, 'hello');
  assert.equal(sockets[0].sent[0].token, VALID_TOKEN);
  assert.equal(controller.ready, false);
  sockets[0].message(helloOk);
  assert.equal(controller.ready, true);
});

test('normal heartbeat remains active when keep-warm is off', () => {
  const { controller, scheduler, sockets, authenticate } = harness();
  authenticate();
  scheduler.advance(19_999);
  assert.equal(sockets[0].sent.filter((m) => m.type === 'heartbeat.request').length, 0);
  scheduler.advance(1);
  assert.equal(sockets[0].sent.filter((m) => m.type === 'heartbeat.request').length, 1);
  assert.equal(controller.ready, true);
});

test('keep-warm uses the same heartbeat manager and one liveness deadline', () => {
  const { controller, scheduler, sockets, authenticate } = harness();
  authenticate();
  controller.setKeepWarm(true);
  scheduler.advance(5_000);
  assert.deepEqual(sockets[0].sent.filter((m) => m.type === 'heartbeat.request').map((m) => m.sequence), [1]);
  assert.equal(scheduler.tasks.size, 2, 'one cadence timer plus one ack deadline');
  scheduler.advance(5_000);
  assert.deepEqual(sockets[0].sent.filter((m) => m.type === 'heartbeat.request').map((m) => m.sequence), [1, 2]);
  assert.equal(scheduler.tasks.size, 2, 'no second liveness deadline');
  sockets[0].message(heartbeatAck(2));
  assert.equal(scheduler.tasks.size, 1, 'ack clears the shared deadline');
});

test('intentional hidden close cannot schedule a reconnect', () => {
  const { controller, scheduler, sockets, authenticate } = harness();
  authenticate();
  controller.close('hidden');
  sockets[0].onclose?.({ code: 1000 });
  scheduler.advance(60_000);
  assert.equal(sockets.length, 1);
  assert.equal(controller.state, 'suspended');
});

test('a displaced phone stays terminal until an explicit takeover action', () => {
  const { controller, scheduler, sockets, statuses, authenticate } = harness();
  authenticate();

  sockets[0].serverClose(4004, 'another phone took over');

  assert.equal(controller.ready, false);
  assert.equal(controller.state, 'taken_over');
  assert.equal(statuses.at(-1).reason, 'another_phone_took_over');
  scheduler.advance(60_000);
  assert.equal(sockets.length, 1, 'terminal takeover never auto-reconnects');

  controller.connect();
  assert.equal(sockets.length, 1, 'automatic lifecycle connect cannot restart takeover');

  controller.resume();
  assert.equal(sockets.length, 2, 'explicit user action may take control again');
});

test('the close frame owns takeover semantics even when an error event arrives first', () => {
  const { controller, scheduler, sockets, authenticate } = harness();
  authenticate();

  sockets[0].onerror?.(new Event('error'));
  sockets[0].serverClose(4004, 'another phone took over');

  assert.equal(controller.state, 'taken_over');
  scheduler.advance(60_000);
  assert.equal(sockets.length, 1);
});

test('the dedicated unauthenticated close is an exact terminal authentication rejection', () => {
  const { controller, scheduler, sockets, statuses } = harness();
  controller.connect();
  sockets[0].open();

  sockets[0].serverClose(4005, 'bad token');

  assert.equal(controller.state, 'auth_rejected');
  assert.equal(statuses.at(-1).reason, 'server_rejected_credentials');
  scheduler.advance(60_000);
  assert.equal(sockets.length, 1);
});

test('unauthenticated generic 4003 remains a transient protocol failure', () => {
  const { controller, scheduler, sockets } = harness();
  controller.connect();
  sockets[0].open();

  sockets[0].serverClose(4003, 'bad initial message');

  assert.equal(controller.state, 'backoff');
  scheduler.advance(250);
  assert.equal(sockets.length, 2);
});

test('authenticated server 4003 remains a transient protocol failure', () => {
  const { controller, scheduler, sockets, authenticate } = harness();
  authenticate();

  sockets[0].serverClose(4003, 'bad message');

  assert.equal(controller.state, 'backoff');
  scheduler.advance(250);
  assert.equal(sockets.length, 2);
});

for (const [name, frame] of [
  ['binary', new Uint8Array([1, 2])],
  ['oversized', 'x'.repeat(4097)],
  ['unknown-field', JSON.stringify({ type: 'state', v: 1, macOnline: true, remoteEnabled: true, permission: 'ready', extra: 1 })],
  ['wrong-version', JSON.stringify({ type: 'state', v: 2, macOnline: true, remoteEnabled: true, permission: 'ready' })],
  ['wrong-role', JSON.stringify({ type: 'action.request', v: 1, actionId: '018f63f5-6f3d-7d21-88bc-9ef561f030de', action: 'click', issuedAtUnixMs: 1, expiresAtUnixMs: 2001 })],
]) {
  test(`${name} inbound frame closes into normal backoff with no side effect`, () => {
    const { controller, scheduler, sockets, messages, authenticate } = harness();
    authenticate();
    sockets[0].message(frame);
    assert.equal(messages.length, 0);
    assert.equal(controller.state, 'backoff');
    assert.equal(sockets[0].closed.length, 1);
    scheduler.advance(250);
    assert.equal(sockets.length, 2, 'normal reconnect occurs');
  });
}

test('callbacks from a stale socket generation are ignored', () => {
  const { controller, sockets, messages, authenticate } = harness();
  authenticate();
  const staleMessage = sockets[0].onmessage;
  controller.close('replace');
  controller.connect();
  sockets[1].open();
  sockets[1].message(helloOk);
  staleMessage({ data: stateFrame });
  assert.equal(messages.length, 0);
});
