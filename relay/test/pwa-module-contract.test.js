import test from 'node:test';
import assert from 'node:assert/strict';

async function optionalImport(path) {
  try {
    return await import(path);
  } catch (error) {
    if (error?.code === 'ERR_MODULE_NOT_FOUND') return null;
    throw error;
  }
}

test('PWA responsibility owners have dedicated modules', async () => {
  const [clock, settings, relay, runtime, benchmark, controller] = await Promise.all([
    optionalImport('../public/clock-health-controller.js'),
    optionalImport('../public/phone-settings-store.js'),
    optionalImport('../public/relay-transport.js'),
    optionalImport('../public/runtime-scheduler.js'),
    optionalImport('../public/benchmark-session.js'),
    optionalImport('../public/benchmark-controller.js'),
  ]);

  assert.equal(typeof clock?.ClockHealthController, 'function');
  assert.equal(typeof settings?.PhoneSettingsStore, 'function');
  assert.equal(typeof settings?.MemorySettingsStore, 'function');
  assert.equal(typeof relay?.deriveRelayWebSocketUrl, 'function');
  assert.equal(typeof runtime?.createRuntimeScheduler, 'function');
  assert.equal(typeof benchmark?.BenchmarkSession, 'function');
  assert.equal(typeof benchmark?.BenchmarkRunSequence, 'function');
  assert.equal(typeof controller?.BenchmarkController, 'function');
});
