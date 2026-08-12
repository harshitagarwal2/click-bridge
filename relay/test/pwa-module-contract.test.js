import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

async function optionalImport(path) {
  try {
    return await import(path);
  } catch (error) {
    if (error?.code === 'ERR_MODULE_NOT_FOUND') return null;
    throw error;
  }
}

test('PWA responsibility owners have dedicated modules', async () => {
  const [clock, settings, lifecycle, pairingLink, relay, runtime, benchmark, controller] = await Promise.all([
    optionalImport('../public/clock-health-controller.js'),
    optionalImport('../public/phone-settings-store.js'),
    optionalImport('../public/credential-lifecycle-controller.js'),
    optionalImport('../public/pairing-link.js'),
    optionalImport('../public/relay-transport.js'),
    optionalImport('../public/runtime-scheduler.js'),
    optionalImport('../public/benchmark-session.js'),
    optionalImport('../public/benchmark-controller.js'),
  ]);

  assert.equal(typeof clock?.ClockHealthController, 'function');
  assert.equal(typeof settings?.PhoneSettingsStore, 'function');
  assert.equal(typeof settings?.MemorySettingsStore, 'function');
  assert.equal(typeof lifecycle?.CredentialLifecycleController, 'function');
  assert.equal(typeof pairingLink?.parseAndClearPairingFragment, 'function');
  assert.equal(typeof relay?.deriveRelayWebSocketUrl, 'function');
  assert.equal(typeof runtime?.createRuntimeScheduler, 'function');
  assert.equal(typeof benchmark?.BenchmarkSession, 'function');
  assert.equal(typeof benchmark?.BenchmarkRunSequence, 'function');
  assert.equal(typeof controller?.BenchmarkController, 'function');
});

test('every production reconnect entry delegates through credential lifecycle ownership', () => {
  const source = readFileSync(new URL('../public/app.js', import.meta.url), 'utf8');
  assert.equal(source.match(/oci\.connect\(\)/g)?.length, 1,
    'the controller injection is the only direct connect call');
  assert.match(source, /function goVisible\(\)[\s\S]*credentialLifecycle\.visible\(\)/);
  assert.match(source, /window\.addEventListener\('online',[\s\S]*credentialLifecycle\.online\(\)/);
  assert.match(source, /window\.addEventListener\('pagehide', goHidden\)/);
  assert.match(source, /function goHidden\(\)[\s\S]*oci\.close\('hidden'\)/);
});
