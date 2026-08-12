import assert from 'node:assert/strict';
import test from 'node:test';

import { nearestRank, summarizeRows } from '../scripts/summarize-latency.mjs';

test('nearest-rank uses ceil(p*n) without interpolation', () => {
  assert.equal(nearestRank([1, 2, 3, 4], 0.50), 2);
  assert.equal(nearestRank([1, 2, 3, 4], 0.95), 4);
});

test('only Posted rows enter percentiles while failures remain in totals', () => {
  const rows = [
    { condition: 'cellular-oci', scheduledIdleSeconds: '2', status: 'Posted', estimatedActuationMs: '1' },
    { condition: 'cellular-oci', scheduledIdleSeconds: '2', status: 'Rejected', reason: 'expired', estimatedActuationMs: '0.1' },
    { condition: 'cellular-oci', scheduledIdleSeconds: '15', status: 'Unknown', reason: 'result_drop', estimatedActuationMs: '9999' },
    { condition: 'cellular-oci', scheduledIdleSeconds: '60', status: 'Posted', estimatedActuationMs: '1000' },
  ];
  const summary = summarizeRows(rows);
  assert.deepEqual(summary.totals, { attempts: 4, posted: 2, rejected: 1, unknown: 1 });
  assert.equal(summary.conditions[0].p50, 1);
  assert.equal(summary.conditions[0].maximum, 1000);
  assert.equal(summary.conditions[0].p95, null);
  assert.deepEqual(summary.conditions[0].reasons, { expired: 1, result_drop: 1 });
});

test('p95 and p99 require at least 95 Posted rows and no outlier is removed', () => {
  const rows = Array.from({ length: 95 }, (_, index) => ({
    condition: 'wifi-oci', scheduledIdleSeconds: '2', status: 'Posted',
    estimatedActuationMs: String(index === 94 ? 10_000 : index + 1),
  }));
  const condition = summarizeRows(rows).conditions[0];
  assert.equal(condition.posted, 95);
  assert.equal(condition.p95, 91);
  assert.equal(condition.p99, 10_000);
  assert.equal(condition.maximum, 10_000);
  assert.deepEqual(Object.keys(condition.subgroups['2']).sort(), ['count', 'maximum', 'median', 'raw'].sort());
});

test('missing clock fields cannot produce an estimated actuation value', () => {
  const row = { activationUnixMs: '100', mouseDownPostedUnixMs: '120', clockOffsetMs: '' };
  const summary = summarizeRows([{ condition: 'x', status: 'Posted', scheduledIdleSeconds: '2', ...row }]);
  assert.equal(summary.conditions[0].posted, 1);
  assert.equal(summary.conditions[0].measuredPosted, 0);
  assert.equal(summary.conditions[0].p50, null);
});
