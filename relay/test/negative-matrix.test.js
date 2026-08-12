import assert from 'node:assert/strict';
import test from 'node:test';

import { runNegativeMatrix } from '../scripts/run-negative-matrix.mjs';

function readObservations(observations) {
  return async ({ scenario, phase }) => observations[scenario]?.[phase] ?? null;
}

test('each Octo after observation is collected after its matching scenario action', async () => {
  const events = [];
  const harness = {
    async duplicate() { events.push('action:exact_duplicate'); return {
      exactCached: true, mouseDownIncrement: 3, mouseUpIncrement: 3 }; },
    async conflict() { events.push('action:id_conflict'); return {
      reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async expired() { events.push('action:expired'); return {
      reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async resultDrop() { events.push('action:result_drop'); return {
      lateDelivery: false, totalDownIncrement: 3, totalUpIncrement: 3 }; },
  };
  const observed = {
    exact_duplicate: { before: 10, after: 13 },
    id_conflict: { before: 13, after: 16 },
    expired: { before: 16, after: 16 },
    result_drop: { before: 16, after: 19 },
  };
  const readOctoCount = async ({ scenario, phase }) => {
    events.push(`observe:${scenario}:${phase}`);
    return observed[scenario][phase];
  };

  const report = await runNegativeMatrix({ harness, readOctoCount, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001' });

  assert.deepEqual(report.map((row) => row.outcome), ['pass', 'pass', 'pass', 'pass']);
  assert.deepEqual(events, [
    'observe:exact_duplicate:before', 'action:exact_duplicate', 'observe:exact_duplicate:after',
    'observe:id_conflict:before', 'action:id_conflict', 'observe:id_conflict:after',
    'observe:expired:before', 'action:expired', 'observe:expired:after',
    'observe:result_drop:before', 'action:result_drop', 'observe:result_drop:after',
  ]);
});

test('matrix proves duplicate, id conflict, expiry, and dropped-result non-replay', async () => {
  const calls = [];
  const harness = {
    async duplicate(request) { calls.push(['duplicate', request]); return {
      exactCached: true, mouseDownIncrement: 3, mouseUpIncrement: 3 }; },
    async conflict(original, changed) { calls.push(['conflict', original, changed]); return {
      reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async expired(request) { calls.push(['expired', request]); return {
      reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }; },
    async resultDrop(request) { calls.push(['drop', request]); return {
      lateDelivery: false, totalDownIncrement: 3, totalUpIncrement: 3 }; },
  };
  const octoObservations = {
    exact_duplicate: { before: 10, after: 13 }, id_conflict: { before: 13, after: 16 },
    expired: { before: 16, after: 16 }, result_drop: { before: 16, after: 19 },
  };
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000, idGenerator: (() => {
    let value = 0; return () => `018f63f5-6f3d-7d21-88bc-${String(++value).padStart(12, '0')}`;
  })(), readOctoCount: readObservations(octoObservations) });
  assert.deepEqual(report.map((row) => row.outcome), ['pass', 'pass', 'pass', 'pass']);
  assert.equal(calls.length, 4);
  assert.equal(calls[1][1].actionId, calls[1][2].actionId);
  assert.notEqual(calls[1][1].issuedAtUnixMs, calls[1][2].issuedAtUnixMs);
  assert.ok(calls[2][1].expiresAtUnixMs < 10_000);
  assert.deepEqual(report.map((row) => row.octoIncrement), [3, 3, 0, 3]);
});

test('no public negative row passes without explicit Octo observation and both post counters', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 3, mouseUpIncrement: 0 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 3, totalUpIncrement: 3 }),
  };
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001' });
  assert.deepEqual(report.map((row) => row.outcome), ['fail', 'fail', 'fail', 'fail']);
});

test('result drop fails when reconnect changes either post counter even without late delivery', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 3, mouseUpIncrement: 3 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 3, totalUpIncrement: 4 }),
  };
  const observations = Object.fromEntries(['exact_duplicate', 'id_conflict', 'expired', 'result_drop']
    .map((scenario) => [scenario, { before: 1,
      after: ['exact_duplicate', 'id_conflict', 'result_drop'].includes(scenario) ? 4 : 1 }]));
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001',
    readOctoCount: readObservations(observations) });
  assert.equal(report.find((row) => row.scenario === 'result_drop').outcome, 'fail');
});

test('result drop contract is one three-click execution across the entire disconnect window', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 3, mouseUpIncrement: 3 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 3, totalUpIncrement: 3 }),
  };
  const observations = Object.fromEntries(['exact_duplicate', 'id_conflict', 'expired', 'result_drop']
    .map((scenario) => [scenario, { before: 1,
      after: ['exact_duplicate', 'id_conflict', 'result_drop'].includes(scenario) ? 4 : 1 }]));
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001',
    readOctoCount: readObservations(observations) });
  assert.equal(report.find((row) => row.scenario === 'result_drop').outcome, 'pass');
});

test('a duplicate physical execution fails even when down and up counters match', async () => {
  const harness = {
    duplicate: async () => ({ exactCached: true, mouseDownIncrement: 6, mouseUpIncrement: 6 }),
    conflict: async () => ({ reason: 'id_conflict', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    expired: async () => ({ reason: 'expired', mouseDownIncrement: 0, mouseUpIncrement: 0 }),
    resultDrop: async () => ({ lateDelivery: false, totalDownIncrement: 6, totalUpIncrement: 6 }),
  };
  const observations = Object.fromEntries(['exact_duplicate', 'id_conflict', 'expired', 'result_drop']
    .map((scenario) => [scenario, { before: 1,
      after: ['exact_duplicate', 'result_drop'].includes(scenario) ? 7
        : scenario === 'id_conflict' ? 4 : 1 }]));
  const report = await runNegativeMatrix({ harness, nowUnixMs: () => 10_000,
    idGenerator: () => '018f63f5-6f3d-7d21-88bc-000000000001',
    readOctoCount: readObservations(observations) });
  assert.equal(report.find((row) => row.scenario === 'exact_duplicate').outcome, 'fail');
  assert.equal(report.find((row) => row.scenario === 'result_drop').outcome, 'fail');
});
