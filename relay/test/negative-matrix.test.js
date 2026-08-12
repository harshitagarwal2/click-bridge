import assert from 'node:assert/strict';
import test from 'node:test';

import { runNegativeMatrix } from '../scripts/run-negative-matrix.mjs';

test('matrix proves duplicate, id conflict, expiry, and dropped-result non-replay', async () => {
  const calls = [];
  const harness = {
    async duplicate(request) { calls.push(['duplicate', request]); return {
      exactCached: true, mouseDownIncrement: 1, mouseUpIncrement: 1 }; },
    async conflict(original, changed) { calls.push(['conflict', original, changed]); return {
      reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async expired(request) { calls.push(['expired', request]); return {
      reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async resultDrop(request) { calls.push(['drop', request]); return {
      lateDelivery: false, totalDownIncrement: 1, totalUpIncrement: 1 }; },
  };
  const octoObservations = {
    exact_duplicate: { before: 10, after: 11 }, id_conflict: { before: 11, after: 11 },
    expired: { before: 11, after: 11 }, result_drop: { before: 12, after: 13 },
  };
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000, idGenerator: (() => {
    let value = 0; return () => `018f63f5-6f3d-7d21-88bc-${String(++value).padStart(12, '0')}`;
  })(), octoObservations });
  assert.deepEqual(report.map((row) => row.outcome), ['pass', 'pass', 'pass', 'pass']);
  assert.equal(calls.length, 4);
  assert.equal(calls[1][1].actionId, calls[1][2].actionId);
  assert.notEqual(calls[1][1].issuedAtUnixMs, calls[1][2].issuedAtUnixMs);
  assert.ok(calls[2][1].expiresAtUnixMs < 10_000);
  assert.deepEqual(report.map((row) => row.octoIncrement), [1, 0, 0, 1]);
});

test('no public negative row passes without explicit Octo observation and both post counters', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 1, mouseUpIncrement: 0 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 1, totalUpIncrement: 1 }),
  };
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001', octoObservations: {} });
  assert.deepEqual(report.map((row) => row.outcome), ['fail', 'fail', 'fail', 'fail']);
});

test('result drop fails when reconnect changes either post counter even without late delivery', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 1, mouseUpIncrement: 1 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 1, totalUpIncrement: 2 }),
  };
  const observations = Object.fromEntries(['exact_duplicate', 'id_conflict', 'expired', 'result_drop']
    .map((scenario) => [scenario, { before: 1,
      after: ['exact_duplicate', 'result_drop'].includes(scenario) ? 2 : 1 }]));
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001', octoObservations: observations });
  assert.equal(report.find((row) => row.scenario === 'result_drop').outcome, 'fail');
});

test('result drop contract is one total original post across the entire disconnect window', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 1, mouseUpIncrement: 1 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 1, totalUpIncrement: 1 }),
  };
  const observations = Object.fromEntries(['exact_duplicate', 'id_conflict', 'expired', 'result_drop']
    .map((scenario) => [scenario, { before: 1,
      after: ['exact_duplicate', 'result_drop'].includes(scenario) ? 2 : 1 }]));
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001', octoObservations: observations });
  assert.equal(report.find((row) => row.scenario === 'result_drop').outcome, 'pass');
});
