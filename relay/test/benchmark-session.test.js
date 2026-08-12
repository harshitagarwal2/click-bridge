import assert from 'node:assert/strict';
import test from 'node:test';

import {
  BenchmarkSession,
  BenchmarkRunSequence,
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
  const sequence = new BenchmarkRunSequence({ schedule: Array(100).fill(2) });
  for (let index = 0; index < 10; index += 1) {
    assert.equal(sequence.current().recorded, false);
    sequence.terminal();
  }
  assert.deepEqual(sequence.current(), { recorded: true, sampleIndex: 1, scheduledIdleSeconds: 2 });
  for (let index = 0; index < 100; index += 1) sequence.terminal();
  assert.equal(sequence.complete, true);
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
    requestCounters: async () => ({ mouseDownPostCount: 1, mouseUpPostCount: 1 }),
  });
  await subject.start({ runId: 'run', condition: 'cellular-oci' });
  assert.equal(calls, 20);
  assert.equal(subject.alignment.rttMs, 2);
  for (let index = 0; index < 10; index += 1) subject.recordExcludedTerminal();
  for (let index = 0; index < 15; index += 1) subject.recordTerminal({ status: 'Unknown' });
  await subject.refreshIfDue();
  assert.equal(calls, 40);
});

test('impossible alignment is rejected and benchmark never retries an action', async () => {
  let sends = 0;
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => ({ t0: 10, t1: 20, t2: 19, t3: 11 }),
    requestCounters: async () => ({ mouseDownPostCount: 0, mouseUpPostCount: 0 }),
    sendAction: async () => { sends += 1; return { status: 'Unknown' }; },
  });
  await assert.rejects(() => subject.start({ runId: 'r', condition: 'c' }), /alignment/);
  assert.equal(sends, 0);
});

test('CSV exports exact public columns and counter evidence without secrets', async () => {
  const snapshots = [
    { mouseDownPostCount: 10, mouseUpPostCount: 10 },
    { mouseDownPostCount: 12, mouseUpPostCount: 12 },
  ];
  const subject = new BenchmarkSession({
    exchangeTimeSync: async () => sync(2),
    requestCounters: async () => snapshots.shift(),
  });
  await subject.start({ runId: 'r', condition: 'c' });
  subject.recordTerminal({ actionId: 'a', status: 'Posted', activationUnixMs: 100,
    mouseDownPostedUnixMs: 120, scheduledIdleSeconds: 2 });
  await subject.finish({ octoCounterStart: 5, octoCounterEnd: 7, logicalActionCount: 2 });
  const exported = subject.exportCsv();
  assert.equal(exported.measurements.split('\n')[0], MEASUREMENT_COLUMNS.join(','));
  assert.equal(exported.evidence.split('\n')[0], RUN_EVIDENCE_COLUMNS.join(','));
  assert.doesNotMatch(exported.measurements + exported.evidence, /token|password|146\./i);
  assert.match(exported.evidence, /r,10,10,12,12,5,7,2/);
  assert.equal(rowsToCsv([], MEASUREMENT_COLUMNS), `${MEASUREMENT_COLUMNS.join(',')}\n`);
});
