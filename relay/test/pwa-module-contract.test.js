import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

async function optionalImport(path) {
  try {
    return await import(path);
  } catch (error) {
    if (error?.code === 'ERR_MODULE_NOT_FOUND') return null;
    throw error;
  }
}

test('PWA responsibility owners have dedicated modules', async () => {
  const [clock, settings, relay, runtime, benchmark] = await Promise.all([
    optionalImport('../public/clock-health-controller.js'),
    optionalImport('../public/phone-settings-store.js'),
    optionalImport('../public/relay-transport.js'),
    optionalImport('../public/runtime-scheduler.js'),
    optionalImport('../public/benchmark-session.js'),
  ]);

  assert.equal(typeof clock?.ClockHealthController, 'function');
  assert.equal(typeof settings?.PhoneSettingsStore, 'function');
  assert.equal(typeof settings?.MemorySettingsStore, 'function');
  assert.equal(typeof relay?.deriveRelayWebSocketUrl, 'function');
  assert.equal(typeof runtime?.createRuntimeScheduler, 'function');
  assert.equal(typeof benchmark?.BenchmarkSession, 'function');
  assert.equal(typeof benchmark?.BenchmarkRunSequence, 'function');
});

test('PWA lifecycle cancels generation-owned benchmark requests and suspends idle eligibility', async () => {
  const app = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
  assert.match(app, /benchmarkRequests\?\.cancelAll\(status\.reason\)/);
  assert.match(app, /benchmarkRequests\.cancelAll\('hidden'\)/);
  assert.match(app, /benchmarkSequence\.suspend\(\)/);
  assert.match(app, /!benchmarkSequence\.current\(\)\.eligible/);
});
