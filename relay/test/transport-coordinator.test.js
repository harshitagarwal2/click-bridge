import test from 'node:test';
import assert from 'node:assert/strict';

import { initialState, phaseOf, PHASE, reduce } from '../public/state.js';
import * as coordinatorModule from '../public/transport-coordinator.js';
import { FakeScheduler, ID, VALID_TOKEN } from './pwa-test-helpers.js';

const OTHER = '018f63f5-6f3d-7d21-88bc-9ef561f030ff';
const { createActionRequest, TransportCoordinator } = coordinatorModule;

function readyState() {
  return [
    { type: 'token.set', token: VALID_TOKEN },
    { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'ready' },
    { type: 'clock.health', healthy: true, offsetMs: 10, uncertaintyMs: 5, measuredAtUnixMs: 900 },
  ].reduce(reduce, initialState());
}

function harness(onMetric = () => {}) {
  const scheduler = new FakeScheduler(1000);
  let state = readyState();
  const sent = [];
  const port = Object.freeze({
    name: 'oci', generation: 3, ready: true, send: (message) => { sent.push(message); return true; },
  });
  const coordinator = new TransportCoordinator({
    getState: () => state,
    dispatch: (event) => { state = reduce(state, event); },
    transports: () => [port],
    selectTransports: (ports) => ports.filter((candidate) => candidate.name === 'oci').slice(0, 1),
    clock: { now: () => scheduler.now, monotonicNow: () => scheduler.now,
      epochMonotonicNow: () => scheduler.now + 10_000 },
    scheduler,
    idGenerator: () => ID,
    getClockDiagnostics: () => ({ offsetMs: 10, uncertaintyMs: 5, sampleAgeMs: 100 }),
    onMetric,
  });
  return { coordinator, scheduler, sent, getState: () => state };
}

test('metrics expose activation, ack, terminal timing, and late results without changing state', () => {
  const metrics = [];
  const { coordinator, scheduler, getState } = harness((event) => metrics.push(event));
  coordinator.activate();
  scheduler.advance(5);
  coordinator.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: ID, status: 'forwarded', reason: 'ok', relayProcessingUs: 4,
  });
  scheduler.advance(7);
  coordinator.handleMessage('oci', {
    type: 'action.result', v: 1, actionId: ID, status: 'posted', reason: 'ok',
    acceptedVia: 'oci', macProcessingUs: 8, mouseDownPostedUnixMs: 1011,
  });
  coordinator.handleMessage('oci', {
    type: 'action.result', v: 1, actionId: ID, status: 'posted', reason: 'ok',
    acceptedVia: 'oci', macProcessingUs: 8, mouseDownPostedUnixMs: 1011,
  });
  assert.deepEqual(metrics.map((event) => event.type), ['activation', 'ack', 'terminal', 'late-result']);
  assert.equal(metrics.every(Object.isFrozen), true);
  assert.equal(metrics[1].ackMs, 5);
  assert.equal(metrics[0].activationUnixMs, 11_000);
  assert.equal(metrics[2].confirmationMs, 12);
  assert.equal(phaseOf(getState()), PHASE.POSTED);
});

test('createActionRequest returns one immutable request with a two-second expiry', () => {
  const request = createActionRequest({ nowUnixMs: 1000, actionId: ID });
  assert.deepEqual(request, {
    type: 'action.request', v: 1, actionId: ID, action: 'click',
    issuedAtUnixMs: 1000, expiresAtUnixMs: 3000,
  });
  assert.equal(Object.isFrozen(request), true);
});

test('Milestone 1 sends one logical action over OCI and never regenerates it', () => {
  const { coordinator, sent, getState } = harness();
  assert.equal(coordinator.activate(), 'sent');
  assert.equal(coordinator.activate(), 'ignored');
  assert.equal(sent.length, 1);
  assert.equal(sent[0].actionId, ID);
  assert.equal(getState().action.id, ID);
});

test('normal path without benchmark observer adds no send or timer ownership', () => {
  const { coordinator, sent, scheduler } = harness();
  coordinator.onMetric = () => {};
  coordinator.activate();
  assert.equal(sent.length, 1);
  assert.equal(scheduler.tasks.size, 1);
});

test('relay acknowledgement cannot produce Posted', () => {
  const { coordinator, getState } = harness();
  coordinator.activate();
  coordinator.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: ID, status: 'forwarded', reason: 'ok', relayProcessingUs: 4,
  });
  assert.equal(phaseOf(getState()), PHASE.FORWARDED);
});

test('terminal relay rejection keeps the wire reason and current clock diagnostics', () => {
  const { coordinator, getState } = harness();
  coordinator.activate();
  coordinator.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: ID, status: 'rejected', reason: 'expired', relayProcessingUs: 4,
  });
  assert.equal(phaseOf(getState()), PHASE.REJECTED);
  assert.equal(getState().last.reason, 'expired');
  assert.equal(getState().last.clockDiagnostics.sampleAgeMs, 100);
});

test('terminal relay rejection emits one terminal metric before releasing socket ownership', () => {
  const metrics = [];
  const { coordinator } = harness((event) => metrics.push(event));
  coordinator.activate();
  coordinator.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: ID, status: 'rejected', reason: 'expired', relayProcessingUs: 4,
  });
  assert.deepEqual(metrics.map((event) => event.type), ['activation', 'ack', 'terminal']);
  assert.equal(coordinator.busy, false);
});

test('result timeout becomes Unknown and a late result cannot replace it', () => {
  const { coordinator, scheduler, getState } = harness();
  coordinator.activate();
  scheduler.advance(3999);
  assert.equal(phaseOf(getState()), PHASE.SENDING);
  scheduler.advance(1);
  assert.equal(phaseOf(getState()), PHASE.UNKNOWN);
  coordinator.handleMessage('oci', {
    type: 'action.result', v: 1, actionId: ID, status: 'posted', reason: 'ok',
    acceptedVia: 'oci', macProcessingUs: 1, mouseDownPostedUnixMs: 4000,
  });
  assert.equal(phaseOf(getState()), PHASE.UNKNOWN);
});

test('a result for another action cannot settle the pending action', () => {
  const { coordinator, getState } = harness();
  coordinator.activate();
  coordinator.handleMessage('oci', {
    type: 'action.result', v: 1, actionId: OTHER, status: 'posted', reason: 'ok',
    acceptedVia: 'oci', macProcessingUs: 1, mouseDownPostedUnixMs: 1001,
  });
  assert.equal(getState().action.id, ID);
});
