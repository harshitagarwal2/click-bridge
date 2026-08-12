import assert from 'node:assert/strict';
import test from 'node:test';

import { BenchmarkController } from '../public/benchmark-controller.js';
import { BenchmarkRunSequence } from '../public/benchmark-session.js';
import { FakeScheduler } from './pwa-test-helpers.js';

function harness({ refreshRejects = false, startRejects = false, pending = false } = {}) {
  const scheduler = new FakeScheduler(0);
  const calls = { start: 0, refresh: 0, excluded: 0, recorded: [], canceled: [], renders: 0 };
  const session = {
    async start() { calls.start += 1; if (startRejects) throw new Error('pending action'); },
    recordExcludedTerminal(value) { calls.excluded += 1; calls.lastExcluded = value; },
    recordTerminal(value) { calls.recorded.push(value); },
    recordLateResult() {},
    async refreshIfDue() { calls.refresh += 1; if (refreshRejects) throw new Error('sync failed'); },
    async finish() {}, exportCsv() { return {}; },
  };
  const requests = { cancelAll(reason) { calls.canceled.push(reason); } };
  const controller = new BenchmarkController({ session, requests, scheduler,
    monotonicNow: () => scheduler.now,
    createSequence: () => new BenchmarkRunSequence({ schedule: Array(100).fill(2),
      monotonicNow: () => scheduler.now }),
    isActionPending: () => typeof pending === 'function' ? pending() : pending,
    onRender: () => { calls.renders += 1; } });
  return { controller, scheduler, calls };
}

test('Start rejection leaves composition inactive and renders the cleared refresh state', async () => {
  const { controller, calls } = harness({ startRejects: true });
  await assert.rejects(() => controller.start({ runId: 'r', condition: 'c' }), /pending action/);
  assert.equal(controller.active, false);
  assert.equal(controller.refreshing, false);
  assert.equal(controller.canActivate, false);
  assert.equal(calls.renders, 2);
});

test('Start renders enabled first warmup then ten warmups lead to enforced first recorded gap', async () => {
  const { controller, calls } = harness();
  await controller.start({ runId: 'r', condition: 'c' });
  assert.equal(controller.canActivate, true);
  assert.ok(calls.renders >= 2);
  for (let index = 0; index < 10; index += 1) {
    controller.handleMetric(Object.freeze({ type: 'activation', actionId: `w${index}` }));
    await controller.handleMetric(Object.freeze({ type: 'terminal', actionId: `w${index}`, status: 'posted' }));
  }
  assert.equal(calls.excluded, 10);
  assert.equal(controller.current.recorded, true);
  assert.equal(controller.canActivate, false);
});

test('frozen activation draft is processed immutably at terminal', async () => {
  const { controller, calls } = harness();
  await controller.start({ runId: 'r', condition: 'c' });
  const activation = Object.freeze({ type: 'activation', actionId: 'a', pathsSent: 'oci' });
  controller.handleMetric(activation);
  await controller.handleMetric(Object.freeze({ type: 'terminal', actionId: 'a', status: 'posted' }));
  assert.equal(calls.excluded, 1);
  assert.equal(Object.isFrozen(activation), true);
});

test('backoff suspends schedule and reconnect refresh resumes only after success', async () => {
  const { controller, calls } = harness();
  await controller.start({ runId: 'r', condition: 'c' });
  controller.transportLost('backoff');
  assert.equal(controller.canActivate, false);
  assert.equal(controller.refreshRequired, true);
  assert.deepEqual(calls.canceled, ['backoff']);
  await controller.transportReady();
  assert.equal(calls.refresh, 1);
  assert.equal(controller.refreshRequired, false);
  assert.equal(controller.canActivate, true);
});

test('refresh rejection stays suspended and every transition renders', async () => {
  const { controller, calls } = harness({ refreshRejects: true });
  await controller.start({ runId: 'r', condition: 'c' });
  const before = calls.renders;
  controller.transportLost('disconnect');
  await assert.rejects(() => controller.transportReady(), /sync failed/);
  assert.equal(controller.canActivate, false);
  assert.equal(controller.refreshRequired, true);
  assert.ok(calls.renders >= before + 3);
});

test('periodic alignment rejection suspends the schedule until a later refresh succeeds', async () => {
  const { controller } = harness({ refreshRejects: true });
  await controller.start({ runId: 'r', condition: 'c' });
  controller.handleMetric({ type: 'activation', actionId: 'w0' });
  await assert.rejects(
    () => controller.handleMetric({ type: 'terminal', actionId: 'w0', status: 'posted' }),
    /sync failed/,
  );
  assert.equal(controller.sequence.suspended, true);
  assert.equal(controller.refreshRequired, true);
  assert.equal(controller.canActivate, false);
});

test('pending action defers reconnect refresh without resuming eligibility', async () => {
  const { controller, calls } = harness({ pending: true });
  await controller.start({ runId: 'r', condition: 'c' });
  controller.transportLost('backoff');
  assert.equal(await controller.transportReady(), false);
  assert.equal(calls.refresh, 0);
  assert.equal(controller.refreshRequired, true);
  assert.equal(controller.sequence.suspended, true);
});

test('terminal refresh yields to action settlement before requesting alignment', async () => {
  let pending = true;
  const { controller, calls } = harness({ pending: () => pending });
  await controller.start({ runId: 'r', condition: 'c' });
  controller.handleMetric({ type: 'activation', actionId: 'w0' });
  const terminal = controller.handleMetric({ type: 'terminal', actionId: 'w0', status: 'posted' });
  pending = false;
  await terminal;
  assert.equal(calls.refresh, 1);
  assert.equal(controller.sequence.suspended, false);
});

test('eligibility timer completion renders and enables the scheduled action', async () => {
  const { controller, scheduler, calls } = harness();
  await controller.start({ runId: 'r', condition: 'c' });
  for (let index = 0; index < 10; index += 1) {
    controller.handleMetric({ type: 'activation', actionId: `w${index}` });
    await controller.handleMetric({ type: 'terminal', actionId: `w${index}`, status: 'posted' });
  }
  const before = calls.renders;
  scheduler.advance(1_999);
  assert.equal(controller.canActivate, false);
  scheduler.advance(1);
  assert.equal(controller.canActivate, true);
  assert.ok(calls.renders > before);
  controller.handleMetric({ type: 'activation', actionId: 'm1' });
  await controller.handleMetric({ type: 'terminal', actionId: 'm1', status: 'posted' });
  assert.equal(calls.recorded.length, 1);
  assert.equal(calls.recorded[0].sampleIndex, 1);
});
