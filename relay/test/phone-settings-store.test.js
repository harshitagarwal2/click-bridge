import test from 'node:test';
import assert from 'node:assert/strict';

import {
  clearTokenChange,
  MemorySettingsStore,
  PhoneSettingsStore,
  saveTokenChange,
} from '../public/phone-settings-store.js';

test('memory settings store defaults to no token and keep-warm off', () => {
  const store = new MemorySettingsStore();
  assert.equal(store.getToken(), null);
  assert.equal(store.getKeepWarm(), false);
});

test('settings store replaces and clears the token without exposing storage details', () => {
  const store = new MemorySettingsStore();
  store.setToken('a'.repeat(64));
  assert.equal(store.getToken(), 'a'.repeat(64));
  store.clearToken();
  assert.equal(store.getToken(), null);
});

test('localStorage failures degrade to safe defaults', () => {
  const storage = {
    getItem() { throw new Error('blocked'); },
    setItem() { throw new Error('blocked'); },
    removeItem() { throw new Error('blocked'); },
  };
  const store = new PhoneSettingsStore(storage);

  assert.equal(store.getToken(), null);
  assert.equal(store.getKeepWarm(), false);
  assert.equal(store.setToken('a'.repeat(64)), false);
  assert.equal(store.setKeepWarm(true), false);
  assert.equal(store.clearToken(), false);
});

test('failed token save leaves application state unchanged and gives a safe recovery message', () => {
  const token = 'a'.repeat(64);
  const settings = { setToken: () => false };
  let stateToken = null;

  const outcome = saveTokenChange(settings, token, () => { stateToken = token; });

  assert.equal(outcome.ok, false);
  assert.equal(stateToken, null);
  assert.match(outcome.message, /browser storage settings/i);
  assert.equal(outcome.message.includes(token), false);
});

test('failed token clear keeps application state paired and gives a safe recovery message', () => {
  const settings = { clearToken: () => false };
  let stateToken = 'stored';

  const outcome = clearTokenChange(settings, () => { stateToken = null; });

  assert.equal(outcome.ok, false);
  assert.equal(stateToken, 'stored');
  assert.match(outcome.message, /browser storage settings/i);
});

test('successful token changes commit application state after storage succeeds', () => {
  const settings = new MemorySettingsStore();
  let stateToken = null;

  assert.deepEqual(
    saveTokenChange(settings, 'b'.repeat(64), () => { stateToken = 'b'.repeat(64); }),
    { ok: true },
  );
  assert.equal(stateToken, 'b'.repeat(64));
  assert.deepEqual(clearTokenChange(settings, () => { stateToken = null; }), { ok: true });
  assert.equal(stateToken, null);
});

test('keep-warm preference is persisted as a boolean', () => {
  const store = new MemorySettingsStore();
  store.setKeepWarm(true);
  assert.equal(store.getKeepWarm(), true);
  store.setKeepWarm(false);
  assert.equal(store.getKeepWarm(), false);
});
