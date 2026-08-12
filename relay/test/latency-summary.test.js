import test from 'node:test';
import assert from 'node:assert/strict';

import {
  nearestRank, parseCSV, summarize, summarizeGroup, derivedActuation,
  REQUIRED_COLUMNS, PERCENTILE_MIN_SAMPLES,
} from '../scripts/summarize-latency.mjs';

const row = (o = {}) => ({
  runId: 'r1', condition: 'oci-cellular', blockIndex: '0', sampleIndex: '0',
  network: 'cellular', scheduledIdleSeconds: '2', actualIdleMs: '2010',
  keepWarm: 'false', normalHeartbeat: '20s', tailscaleRoute: '', pathsSent: 'oci',
  actionId: 'a', activationUnixMs: '1000', mouseDownPostedUnixMs: '1100',
  clockOffsetMs: '0', clockRttMs: '40', clockUncertaintyMs: '20',
  estimatedActuationMs: '100', ackMs: '40', confirmationMs: '100',
  relayProcessingUs: '140', macProcessingUs: '800',
  acceptedVia: 'oci', firstResultVia: 'oci', lateResultCount: '0',
  status: 'posted', reason: 'ok', mouseDownPosts: '1', mouseUpPosts: '1',
  ...o,
});

// ---------------------------------------------------------------------------

test('nearest-rank percentiles match the definition', () => {
  assert.equal(nearestRank([1, 2, 3, 4], 0.50), 2);
  assert.equal(nearestRank([1, 2, 3, 4], 0.95), 4);
  assert.equal(nearestRank([4, 3, 2, 1], 0.50), 2, 'input need not be sorted');
  assert.equal(nearestRank([5], 0.99), 5);
  assert.equal(nearestRank([], 0.5), null);
});

test('percentiles never index out of range', () => {
  const values = Array.from({ length: 7 }, (_, i) => i + 1);
  for (const p of [0.01, 0.5, 0.95, 0.99, 1]) {
    const v = nearestRank(values, p);
    assert.ok(v >= 1 && v <= 7, `p=${p} produced ${v}`);
  }
});

test('CSV parsing keeps every declared column', () => {
  const csv = `${REQUIRED_COLUMNS.join(',')}\n${REQUIRED_COLUMNS.map(() => 'x').join(',')}`;
  const { header, rows } = parseCSV(csv);
  assert.deepEqual(header, REQUIRED_COLUMNS);
  assert.equal(rows.length, 1);
});

test('only Posted rows enter latency statistics', () => {
  const rows = [
    row({ confirmationMs: '100' }),
    row({ status: 'rejected', reason: 'remote_disabled', confirmationMs: '5' }),
    row({ status: 'unknown', reason: 'timeout', confirmationMs: '4000' }),
  ];
  const s = summarizeGroup(rows);
  assert.equal(s.confirmationMs.count, 1, 'only the posted sample counted');
  assert.equal(s.confirmationMs.median, 100);
  assert.notEqual(s.confirmationMs.max, 4000, 'the unknown row must not inflate max');
});

test('rejected and unknown rows stay in the reliability totals', () => {
  const rows = [
    row(),
    row({ status: 'rejected', reason: 'expired' }),
    row({ status: 'unknown', reason: 'timeout' }),
  ];
  const s = summarizeGroup(rows);
  assert.equal(s.total, 3);
  assert.equal(s.postedCount, 1);
  assert.equal(s.rejectedCount, 1);
  assert.equal(s.unknownCount, 1);
  assert.equal(Math.round(s.postedRate * 100), 33);
  assert.deepEqual(s.reasons, { expired: 1, timeout: 1 });
});

test('no outlier is removed', () => {
  const rows = [
    ...Array.from({ length: 100 }, () => row({ confirmationMs: '100' })),
    row({ confirmationMs: '99999' }),
  ];
  const s = summarizeGroup(rows);
  assert.equal(s.confirmationMs.count, 101);
  assert.equal(s.confirmationMs.max, 99999, 'the outlier survives');
});

test('p95 and p99 are suppressed below the sample floor', () => {
  const small = summarizeGroup(Array.from({ length: 20 }, () => row()));
  assert.equal(small.confirmationMs.p95, null);
  assert.equal(small.confirmationMs.p99, null);
  assert.equal(small.confirmationMs.percentilesSuppressed, true);
  assert.equal(small.confirmationMs.median, 100, 'median is still reported');
  assert.ok(small.confirmationMs.max !== null);
});

test('p95 and p99 appear at the sample floor', () => {
  const big = summarizeGroup(
    Array.from({ length: PERCENTILE_MIN_SAMPLES }, () => row()));
  assert.equal(big.confirmationMs.percentilesSuppressed, false);
  assert.equal(big.confirmationMs.p95, 100);
});

test('a derived estimate needs every raw clock field', () => {
  assert.equal(derivedActuation(row()), 100);
  assert.equal(derivedActuation(row({ clockOffsetMs: '' })), null);
  assert.equal(derivedActuation(row({ mouseDownPostedUnixMs: '' })), null);
  assert.equal(derivedActuation(row({ activationUnixMs: '' })), null);
});

test('the clock offset is applied in the right direction', () => {
  // Mac clock 50 ms ahead: the raw post timestamp must be corrected DOWN.
  const r = row({ activationUnixMs: '1000', mouseDownPostedUnixMs: '1150', clockOffsetMs: '50' });
  assert.equal(derivedActuation(r), 100);
});

test('rows with missing clock fields do not poison the actuation stats', () => {
  const rows = [row(), row({ clockOffsetMs: '' }), row()];
  const s = summarizeGroup(rows);
  assert.equal(s.estimatedActuationMs.count, 2, 'the incomplete row is excluded');
  assert.equal(s.confirmationMs.count, 3, 'but it still counts elsewhere');
});

test('late results are tallied separately and never as latency', () => {
  const s = summarizeGroup([row({ lateResultCount: '2' }), row({ lateResultCount: '1' })]);
  assert.equal(s.lateResults, 3);
  assert.equal(s.confirmationMs.count, 2);
});

test('mac post counters are summed for the double-click gate', () => {
  const s = summarizeGroup([
    row({ mouseDownPosts: '1', mouseUpPosts: '1' }),
    row({ mouseDownPosts: '1', mouseUpPosts: '1' }),
  ]);
  assert.equal(s.mouseDownPosts, 2);
  assert.equal(s.mouseUpPosts, 2);
});

test('conditions and idle subgroups are reported separately', () => {
  const rows = [
    row({ condition: 'oci', scheduledIdleSeconds: '2' }),
    row({ condition: 'oci', scheduledIdleSeconds: '60', confirmationMs: '300' }),
    row({ condition: 'tailscale', scheduledIdleSeconds: '2', confirmationMs: '60' }),
  ];
  const s = summarize(rows);
  assert.deepEqual(Object.keys(s.conditions).sort(), ['oci', 'tailscale']);
  assert.equal(s.conditions.oci.total, 2);
  assert.deepEqual(Object.keys(s.conditions.oci.idleSubgroups).sort(), ['2s', '60s']);
  assert.equal(s.conditions.oci.idleSubgroups['60s'].confirmationMs.median, 300);
  assert.equal(
    s.conditions.oci.idleSubgroups['60s'].confirmationMs.percentilesSuppressed, true,
    'small idle subgroups never claim a p95');
});

test('a group with no posted rows reports no latency at all', () => {
  const s = summarizeGroup([row({ status: 'unknown', reason: 'timeout' })]);
  assert.equal(s.confirmationMs, null);
  assert.equal(s.estimatedActuationMs, null);
  assert.equal(s.unknownCount, 1);
});
