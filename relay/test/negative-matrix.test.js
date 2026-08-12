import assert from 'node:assert/strict';
import test from 'node:test';

import { runNegativeMatrix } from '../scripts/run-negative-matrix.mjs';

test('matrix proves duplicate, id conflict, expiry, and dropped-result non-replay', async () => {
  const calls = [];
  const harness = {
    async duplicate(request) { calls.push(['duplicate', request]); return { exactCached: true, increment: 1 }; },
    async conflict(original, changed) { calls.push(['conflict', original, changed]); return { reason: 'id_conflict', increment: 0 }; },
    async expired(request) { calls.push(['expired', request]); return { reason: 'expired', increment: 0 }; },
    async resultDrop(request) { calls.push(['drop', request]); return { lateDelivery: false, replay: false }; },
  };
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000, idGenerator: (() => {
    let value = 0; return () => `018f63f5-6f3d-7d21-88bc-${String(++value).padStart(12, '0')}`;
  })() });
  assert.deepEqual(report.map((row) => row.outcome), ['pass', 'pass', 'pass', 'pass']);
  assert.equal(calls.length, 4);
  assert.equal(calls[1][1].actionId, calls[1][2].actionId);
  assert.notEqual(calls[1][1].issuedAtUnixMs, calls[1][2].issuedAtUnixMs);
  assert.ok(calls[2][1].expiresAtUnixMs < 10_000);
});
