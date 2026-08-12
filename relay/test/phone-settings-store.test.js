import test from 'node:test';
import assert from 'node:assert/strict';

import { MemorySettingsStore, PhoneSettingsStore } from '../public/phone-settings-store.js';

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

test('keep-warm preference is persisted as a boolean', () => {
  const store = new MemorySettingsStore();
  store.setKeepWarm(true);
  assert.equal(store.getKeepWarm(), true);
  store.setKeepWarm(false);
  assert.equal(store.getKeepWarm(), false);
});
