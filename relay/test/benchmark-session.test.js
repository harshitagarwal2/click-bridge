import assert from 'node:assert/strict';
import test from 'node:test';

import {
  BenchmarkSession,
  BenchmarkRunSequence,
  BenchmarkRequestRouter,
  CounterSnapshotRequester,
  createIdleSchedule,
  counterDelta,
  MEASUREMENT_COLUMNS,
  RUN_EVIDENCE_COLUMNS,
  rowsToCsv,
} from '../public/benchmark-session.js';

const sync = (rtt, offset = 4) => ({
  t0: 100, t1: 100 + rtt / 2 + offset, t2: 101 + rtt / 2 + offset, t3: 101 + rtt,
});

test('counter deltas prove exact down/up posts independently of wire results', () => {
  assert.deepEqual(counterDelta(
    { mouseDownPostCount: 10, mouseUpPostCount: 11 },
    { mouseDownPostCount: 13, mouseUpPostCount: 14 },
  ), { mouseDownPostCount: 3, mouseUpPostCount: 3 });
  assert.throws(() => counterDelta(
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 9, mouseUpPostCount: 10 },
  ), /counter regression/);
});

test('run sequence excludes ten warm-ups before exactly 100 recorded gaps', () => {
  let now = 1_000;
  const sequence = new BenchmarkRunSequence({ schedule: Array(100).fill(2), monotonicNow: () => now });
  for (let index = 0; index < 10; index += 1) {
    assert.equal(sequence.current().recorded, false);
    sequence.terminal();
  }
  assert.deepEqual(sequence.current(), { recorded: true, sampleIndex: 1,
    blockIndex: 1, scheduledIdleSeconds: 2, eligible: false, remainingMs: 2_000 });
  now += 1_999;
  assert.equal(sequence.current().eligible, false);
  now += 1;
  assert.equal(sequence.current().eligible, true);
  for (let index = 0; index < 100; index += 1) sequence.terminal();
  assert.equal(sequence.complete, true);
});

test('visibility suspension stops eligibility and resume restarts the full locked gap', () => {
  let now = 0;
  const sequence = new BenchmarkRunSequence({ schedule: Array(100).fill(2), warmups: 0,
    monotonicNow: () => now, blockIndex: 3 });
  assert.equal(sequence.current().eligible, false);
  now = 1_000;
  sequence.suspend();
  now = 5_000;
  assert.equal(sequence.current().eligible, false);
  sequence.resume();
  assert.deepEqual(sequence.current(), { recorded: true, sampleIndex: 1, blockIndex: 3,
    scheduledIdleSeconds: 2, eligible: false, remainingMs: 2_000 });
});

test('one frozen randomized schedule is reusable across identified blocks', () => {
  const schedule = createIdleSchedule({ random: () => 0.25 });
  const first = new BenchmarkRunSequence({ schedule, warmups: 0, monotonicNow: () => 2_000,
    blockIndex: 1 });
  const second = new BenchmarkRunSequence({ schedule, warmups: 0, monotonicNow: () => 2_000,
    blockIndex: 2 });
  assert.equal(Object.isFrozen(schedule), true);
  assert.equal(first.current().scheduledIdleSeconds, second.current().scheduledIdleSeconds);
  assert.notEqual(first.current().blockIndex, second.current().blockIndex);
});

test('generation-scoped requests reject on disconnect and ignore replacement responses', async () => {
  const scheduler = { setTimeout: () => 1, clearTimeout: () => {} };
  let generation = 4;
  const sent = [];
  const router = new BenchmarkRequestRouter({
    send: (message) => { sent.push(message); return true; },
    getGeneration: () => generation,
    scheduler,
    epochNow: () => 100,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001',
  });
  const pending = router.exchangeTimeSync();
  router.cancelGeneration(4, 'hidden');
  await assert.rejects(pending, /hidden/);
  generation = 5;
  assert.equal(router.handle({ type: 'time.sync.response', syncId: sent[0].syncId,
    phoneSendUnixMs: 100, macReceiveUnixMs: 101, macSendUnixMs: 102 }, 5), false);
  const counters = router.requestCounters();
  const counterMessage = { type: 'diagnostics.counters', requestId: sent[1].requestId,
    mouseDownPostCount: 7, mouseUpPostCount: 7 };
  assert.equal(router.handle(counterMessage, 4), false);
  assert.equal(router.pendingCount, 1);
  assert.equal(router.handle(counterMessage, 5), true);
  assert.equal((await counters).mouseDownPostCount, 7);
  assert.equal(router.pendingCount, 0);
});

test('request router times out and cancelAll leaves no pending ownership', async () => {
  const tasks = new Map();
  let next = 0;
  const scheduler = {
    setTimeout: (callback) => { const id = ++next; tasks.set(id, callback); return id; },
    clearTimeout: (id) => tasks.delete(id),
  };
  const router = new BenchmarkRequestRouter({ send: () => true, getGeneration: () => 1,
    scheduler, epochNow: () => 1, idGenerator: () => `id-${next}` });
  const timedOut = router.requestCounters();
  tasks.values().next().value();
  await assert.rejects(timedOut, /timed out/);
  const canceled = router.requestCounters();
  router.cancelAll('disconnect');
  await assert.rejects(canceled, /disconnect/);
  assert.equal(router.pendingCount, 0);
});

test('counter requester owns snapshots and rejects non-exact post evidence', async () => {
  const snapshots = [
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 12, mouseUpPostCount: 12 },
  ];
  const requester = new CounterSnapshotRequester({ request: async () => snapshots.shift() });
  const start = await requester.capture();
  const end = await requester.capture();
  assert.deepEqual(requester.validateExactRun({ start, end, expectedPhysicalClickCount: 2,
    octoCounterStart: 5, octoCounterEnd: 7 }), { mouseDownPostCount: 2, mouseUpPostCount: 2 });
  assert.throws(() => requester.validateExactRun({ start, end, expectedPhysicalClickCount: 1,
    octoCounterStart: 5, octoCounterEnd: 7 }), /exact post evidence/);
});

test('predeclared schedule contains exactly 70 two, 20 fifteen, and 10 sixty second gaps', () => {
  const schedule = createIdleSchedule({ random: () => 0.5 });
  assert.equal(schedule.length, 100);
  assert.equal(schedule.filter((value) => value === 2).length, 70);
  assert.equal(schedule.filter((value) => value === 15).length, 20);
  assert.equal(schedule.filter((value) => value === 60).length, 10);
});

test('alignment collects 20 samples, selects minimum non-negative RTT, and refreshes after 25 actions', async () => {
  let calls = 0;
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => sync(++calls === 7 ? 2 : 10),
    counterSnapshots: new CounterSnapshotRequester({
      request: async () => ({ mouseDownPostCount: 1, mouseUpPostCount: 1 }),
    }),
  });
  await subject.start({ runId: 'run', condition: 'cellular-oci' });
  assert.equal(calls, 20);
  assert.equal(subject.alignment.rttMs, 2);
  for (let index = 0; index < 10; index += 1) subject.recordExcludedTerminal({ status: 'posted' });
  for (let index = 0; index < 15; index += 1) subject.recordTerminal({ status: 'Unknown' });
  await subject.refreshIfDue();
  assert.equal(calls, 40);
});

test('benchmark start refuses a pending normal action before sync, counters, timers, or sends', async () => {
  let syncCalls = 0;
  let counterCalls = 0;
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => { syncCalls += 1; return sync(2); },
    counterSnapshots: new CounterSnapshotRequester({ request: async () => {
      counterCalls += 1; return { mouseDownPostCount: 0, mouseUpPostCount: 0 };
    } }),
    isActionPending: () => true,
  });
  await assert.rejects(() => subject.start({ runId: 'r', condition: 'c' }), /pending action/);
  assert.equal(syncCalls, 0);
  assert.equal(counterCalls, 0);
});

test('impossible alignment is rejected and benchmark never retries an action', async () => {
  let sends = 0;
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => ({ t0: 10, t1: 20, t2: 19, t3: 11 }),
    counterSnapshots: new CounterSnapshotRequester({
      request: async () => ({ mouseDownPostCount: 0, mouseUpPostCount: 0 }),
    }),
    sendAction: async () => { sends += 1; return { status: 'Unknown' }; },
  });
  await assert.rejects(() => subject.start({ runId: 'r', condition: 'c' }), /alignment/);
  assert.equal(sends, 0);
});

test('CSV exports exact public columns and counter evidence without secrets', async () => {
  const snapshots = [
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 16, mouseUpPostCount: 16 },
  ];
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => sync(2),
    counterSnapshots: new CounterSnapshotRequester({ request: async () => snapshots.shift() }),
    expectedRecordedActions: 2,
  });
  await subject.start({ runId: 'r', condition: 'c' });
  subject.recordTerminal({ actionId: 'a', status: 'Posted', activationUnixMs: 100,
    mouseDownPostedUnixMs: 120, scheduledIdleSeconds: 2 });
  subject.recordTerminal({ actionId: 'b', status: 'Posted', activationUnixMs: 101,
    mouseDownPostedUnixMs: 121, scheduledIdleSeconds: 2 });
  const original = subject.rows[0];
  subject.recordLateResult('a');
  assert.notEqual(subject.rows[0], original);
  assert.equal(original.lateResultCount, 0);
  assert.equal(subject.rows[0].lateResultCount, 1);
  assert.equal(Object.isFrozen(subject.rows[0]), true);
  await subject.finish({ octoCounterStart: 5, octoCounterEnd: 11, logicalActionCount: 2 });
  const exported = subject.exportCsv();
  assert.equal(exported.measurements.split('\n')[0], MEASUREMENT_COLUMNS.join(','));
  assert.equal(exported.evidence.split('\n')[0], RUN_EVIDENCE_COLUMNS.join(','));
  assert.doesNotMatch(exported.measurements + exported.evidence, /token|password|146\./i);
  assert.match(exported.evidence, /r,10,10,16,16,5,11,2/);
  assert.equal(rowsToCsv([], MEASUREMENT_COLUMNS), `${MEASUREMENT_COLUMNS.join(',')}\n`);
  assert.equal(Object.isFrozen(subject.rows[0]), true);
});

test('finish rejects mismatched counters without accepting or exporting run evidence', async () => {
  const snapshots = [
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 11, mouseUpPostCount: 11 },
  ];
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => sync(2),
    counterSnapshots: new CounterSnapshotRequester({ request: async () => snapshots.shift() }),
    expectedRecordedActions: 2,
  });
  await subject.start({ runId: 'r', condition: 'c' });
  subject.recordTerminal({ actionId: 'a', status: 'Posted' });
  subject.recordTerminal({ actionId: 'b', status: 'Posted' });
  await assert.rejects(() => subject.finish({ octoCounterStart: 5, octoCounterEnd: 6,
    logicalActionCount: 2 }), /exact post evidence/);
  assert.equal(subject.evidence.length, 0);
  assert.equal(subject.run.runId, 'r');
});

test('finish refuses an incomplete recorded block even when its current counters match', async () => {
  const requester = new CounterSnapshotRequester({ request: async () => ({
    mouseDownPostCount: 0, mouseUpPostCount: 0,
  }) });
  const subject = new BenchmarkSession({ exchangeTimeSync: async () => sync(2),
    counterSnapshots: requester, expectedRecordedActions: 2 });
  await subject.start({ runId: 'r', condition: 'c' });
  subject.recordTerminal({ actionId: 'a', status: 'Unknown' });
  await assert.rejects(() => subject.finish({ octoCounterStart: 0, octoCounterEnd: 0,
    logicalActionCount: 1 }), /requires 2 recorded actions/);
});

test('excluded warm-up posts remain part of exact counter and Octo evidence', async () => {
  const snapshots = [
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 19, mouseUpPostCount: 19 },
  ];
  const subject = new BenchmarkSession({ exchangeTimeSync: async () => sync(2),
    counterSnapshots: new CounterSnapshotRequester({ request: async () => snapshots.shift() }),
    expectedRecordedActions: 2 });
  await subject.start({ runId: 'r', condition: 'c' });
  subject.recordExcludedTerminal({ status: 'posted' });
  subject.recordTerminal({ actionId: 'a', status: 'Posted' });
  subject.recordTerminal({ actionId: 'b', status: 'Posted' });
  await subject.finish({ octoCounterStart: 5, octoCounterEnd: 14, logicalActionCount: 3 });
  assert.equal(subject.evidence[0].logicalActionCount, 3);
});

test('counter requester independently rejects down, up, and Octo mismatches', () => {
  const requester = new CounterSnapshotRequester({ request: async () => null });
  const start = { mouseDownPostCount: 10, mouseUpPostCount: 10 };
  assert.throws(() => requester.validateExactRun({ start,
    end: { mouseDownPostCount: 12, mouseUpPostCount: 13 }, expectedPhysicalClickCount: 3,
    octoCounterStart: 5, octoCounterEnd: 8 }), /exact post evidence/);
  assert.throws(() => requester.validateExactRun({ start,
    end: { mouseDownPostCount: 13, mouseUpPostCount: 12 }, expectedPhysicalClickCount: 3,
    octoCounterStart: 5, octoCounterEnd: 8 }), /exact post evidence/);
  assert.throws(() => requester.validateExactRun({ start,
    end: { mouseDownPostCount: 13, mouseUpPostCount: 13 }, expectedPhysicalClickCount: 3,
    octoCounterStart: 5, octoCounterEnd: 7 }), /exact post evidence/);
});
