import test from 'node:test';
import assert from 'node:assert/strict';

import { ClockHealthController } from '../public/clock-health-controller.js';
import { initialState, phaseOf, PHASE, reduce } from '../public/state.js';
import { FakeScheduler } from './pwa-test-helpers.js';

function baseState() {
  return [
    { type: 'token.set', token: 'a'.repeat(64) },
    { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'ready' },
  ].reduce(reduce, initialState());
}

function harness() {
  const scheduler = new FakeScheduler(10_000);
  let generation = 4;
  let busy = false;
  let state = baseState();
  const sent = [];
  let nextId = 0;
  const controller = new ClockHealthController({
    sendSync: (message) => { sent.push(message); return true; },
    getGeneration: () => generation,
    clock: { now: () => scheduler.now },
    scheduler,
    idGenerator: () => `018f63f5-6f3d-7d21-88bc-${String(++nextId).padStart(12, '0')}`,
    dispatch: (event) => { state = reduce(state, event); },
    isActionBusy: () => busy,
  });
  return {
    controller, scheduler, sent,
    getState: () => state,
    setGeneration: (value) => { generation = value; },
    setBusy: (value) => { busy = value; controller.actionStateChanged(value); },
  };
}

function answer(controller, scheduler, request, { offsetMs, rttMs }) {
  const oneWay = rttMs / 2;
  scheduler.now = request.phoneSendUnixMs + rttMs;
  controller.handleMessage({
    type: 'time.sync.response', v: 1, syncId: request.syncId,
    phoneSendUnixMs: request.phoneSendUnixMs,
    macReceiveUnixMs: request.phoneSendUnixMs + oneWay + offsetMs,
    macSendUnixMs: request.phoneSendUnixMs + oneWay + offsetMs,
  });
}

function completeBatch(h, samples = [
  { offsetMs: 100, rttMs: 90 },
  { offsetMs: 200, rttMs: 30 },
  { offsetMs: 300, rttMs: 70 },
  { offsetMs: 400, rttMs: 60 },
  { offsetMs: 500, rttMs: 50 },
]) {
  for (const sample of samples) {
    const request = h.sent.at(-1);
    answer(h.controller, h.scheduler, request, sample);
  }
}

test('five exchanges are sequential and the minimum-RTT sample gates Ready', () => {
  const h = harness();
  h.controller.start();
  assert.equal(h.sent.length, 1, 'only one sync may be outstanding');
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_CHECKING);
  completeBatch(h);
  assert.equal(h.sent.length, 5);
  assert.equal(phaseOf(h.getState()), PHASE.READY);
  assert.equal(h.getState().clock.offsetMs, 200, 'minimum RTT sample wins');
  assert.equal(h.getState().clock.uncertaintyMs, 15);
});

test('missing response stays Checking until the exact timeout then becomes unavailable', () => {
  const h = harness();
  h.controller.start();
  h.scheduler.advance(3_499);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_CHECKING);
  h.scheduler.advance(1);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_UNAVAILABLE);
  assert.equal(h.sent.length, 1);
});

test('retry starts a fresh batch and a late response cannot satisfy it', () => {
  const h = harness();
  h.controller.start();
  const old = h.sent[0];
  h.scheduler.advance(3_500);
  h.controller.retry();
  assert.equal(h.sent.length, 2);
  answer(h.controller, h.scheduler, old, { offsetMs: 0, rttMs: 20 });
  assert.equal(h.sent.length, 2, 'late response did not advance the retry');
  completeBatch(h, Array.from({ length: 5 }, () => ({ offsetMs: 0, rttMs: 20 })));
  assert.equal(phaseOf(h.getState()), PHASE.READY);
});

test('a response from a superseded transport generation is ignored', () => {
  const h = harness();
  h.controller.start();
  const stale = h.sent[0];
  h.setGeneration(5);
  answer(h.controller, h.scheduler, stale, { offsetMs: 0, rttMs: 20 });
  assert.equal(h.sent.length, 1);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_CHECKING);
});

test('idle five-minute refresh requires five new responses', () => {
  const h = harness();
  h.controller.start();
  completeBatch(h, Array.from({ length: 5 }, () => ({ offsetMs: 0, rttMs: 20 })));
  h.scheduler.advance(299_999);
  assert.equal(phaseOf(h.getState()), PHASE.READY);
  h.scheduler.advance(1);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_CHECKING);
  assert.equal(h.sent.length, 6);
  completeBatch(h, Array.from({ length: 5 }, () => ({ offsetMs: 0, rttMs: 20 })));
  assert.equal(phaseOf(h.getState()), PHASE.READY);
});

test('refresh due during an action waits until the action settles', () => {
  const h = harness();
  h.controller.start();
  completeBatch(h, Array.from({ length: 5 }, () => ({ offsetMs: 0, rttMs: 20 })));
  h.setBusy(true);
  h.scheduler.advance(300_000);
  assert.equal(phaseOf(h.getState()), PHASE.READY);
  assert.equal(h.sent.length, 5);
  h.setBusy(false);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_CHECKING);
  assert.equal(h.sent.length, 6);
});

test('latest diagnostics expose offset, uncertainty, and sample age', () => {
  const h = harness();
  h.controller.start();
  completeBatch(h, Array.from({ length: 5 }, () => ({ offsetMs: 25, rttMs: 40 })));
  h.scheduler.advance(250);
  assert.deepEqual(h.controller.diagnostics, {
    offsetMs: 25, uncertaintyMs: 20, sampleAgeMs: 250,
  });
});

test('Mac not-ready supersedes unavailable copy and cancels the batch', () => {
  const h = harness();
  h.controller.start();
  h.scheduler.advance(3_500);
  assert.equal(phaseOf(h.getState()), PHASE.CLOCK_UNAVAILABLE);
  h.controller.macNotReady();
  assert.equal(h.getState().clock.unavailable, false);
  assert.equal(h.getState().clock.checked, false);
});
