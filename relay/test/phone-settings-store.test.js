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

test('pending credentials are staged without replacing the active credential', () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 4 };
  const pending = { credential: 'b'.repeat(64), version: 5 };

  assert.equal(store.setActive(active), true);
  assert.equal(store.stage(pending), true);

  assert.deepEqual(store.getActive(), active);
  assert.deepEqual(store.getPending(), pending);
  assert.equal(store.getToken(), active.credential);
});

test('promoting pending atomically installs it as active and clears the pending slot', () => {
  const store = new MemorySettingsStore();
  const pending = { credential: 'b'.repeat(64), version: 5 };
  store.setActive({ credential: 'a'.repeat(64), version: 4 });
  store.stage(pending);

  assert.equal(store.promotePending(pending), true);
  assert.deepEqual(store.getActive(), pending);
  assert.equal(store.getPending(), null);
});

test('failed pending promotion leaves both credential slots unchanged', () => {
  let serialized = null;
  let failWrites = false;
  const storage = {
    getItem(key) { return key === 'clickbridge.phoneToken' ? serialized : null; },
    setItem(key, value) {
      if (failWrites) throw new Error('blocked');
      if (key === 'clickbridge.phoneToken') serialized = value;
    },
  };
  const store = new PhoneSettingsStore(storage);
  const active = { credential: 'a'.repeat(64), version: 4 };
  const pending = { credential: 'b'.repeat(64), version: 5 };
  assert.equal(store.setActive(active), true);
  assert.equal(store.stage(pending), true);
  failWrites = true;

  assert.equal(store.promotePending(pending), false);
  assert.deepEqual(store.getActive(), active);
  assert.deepEqual(store.getPending(), pending);
});

test('promotion rejects a same-version pending credential replaced after validation', () => {
  const store = new MemorySettingsStore();
  const expected = { credential: 'b'.repeat(64), version: 5 };
  const replacement = { credential: 'c'.repeat(64), version: 5 };
  store.setActive({ credential: 'a'.repeat(64), version: 4 });
  store.stage(expected);
  store.stage(replacement);

  assert.equal(store.promotePending(expected), false);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 4 });
  assert.deepEqual(store.getPending(), replacement);
});

test('promotion requires the exact credential and version in the pending slot', () => {
  const store = new MemorySettingsStore();
  const pending = { credential: 'b'.repeat(64), version: 5 };
  store.setActive({ credential: 'a'.repeat(64), version: 4 });
  store.stage(pending);

  assert.equal(store.promotePending({ ...pending, credential: 'c'.repeat(64) }), false);
  assert.equal(store.promotePending({ ...pending, version: 6 }), false);
  assert.deepEqual(store.getPending(), pending);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 4 });
});

test('discard and forget clear only their intended recoverable slots', () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 4 };
  store.setActive(active);
  store.stage({ credential: 'b'.repeat(64), version: 5 });

  assert.equal(store.discardPending(), true);
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
  assert.equal(store.forget(), true);
  assert.equal(store.getActive(), null);
  assert.equal(store.getPending(), null);
});

test('storage failures preserve the active credential and report no transition', () => {
  let serialized = null;
  let failWrites = false;
  const storage = {
    getItem(key) { return key === 'clickbridge.phoneToken' ? serialized : null; },
    setItem(key, value) {
      if (failWrites) throw new Error(`blocked ${value}`);
      if (key === 'clickbridge.phoneToken') serialized = value;
    },
    removeItem() {},
  };
  const store = new PhoneSettingsStore(storage);
  const active = { credential: 'a'.repeat(64), version: 4 };
  assert.equal(store.setActive(active), true);
  failWrites = true;

  assert.equal(store.stage({ credential: 'b'.repeat(64), version: 5 }), false);
  assert.equal(store.promotePending({ credential: 'b'.repeat(64), version: 5 }), false);
  assert.equal(store.forget(), false);
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
});

test('a failed read aborts staging instead of overwriting an unseen active credential', () => {
  const active = { credential: 'a'.repeat(64), version: 4 };
  let serialized = JSON.stringify({ active, pending: null });
  let failReads = true;
  const store = new PhoneSettingsStore({
    getItem(key) {
      if (failReads) throw new Error('temporarily blocked');
      return key === 'clickbridge.phoneToken' ? serialized : null;
    },
    setItem(key, value) {
      if (key === 'clickbridge.phoneToken') serialized = value;
    },
    removeItem() {},
  });

  assert.equal(store.stage({ credential: 'b'.repeat(64), version: 5 }), false);
  failReads = false;
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
});

test('forget overwrites legacy token storage so no shadow credential remains', () => {
  const legacy = 'a'.repeat(64);
  const values = new Map([['clickbridge.phoneToken', legacy]]);
  const store = new PhoneSettingsStore({
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  });

  assert.equal(store.getToken(), legacy);
  assert.equal(store.forget(), true);
  assert.equal([...values.values()].some((value) => value.includes(legacy)), false);
});

test('staging upgrades legacy token storage without losing the active credential', () => {
  const legacy = 'a'.repeat(64);
  const pending = { credential: 'b'.repeat(64), version: 1 };
  const values = new Map([['clickbridge.phoneToken', legacy]]);
  const store = new PhoneSettingsStore({
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
  });

  assert.equal(store.stage(pending), true);
  assert.deepEqual(JSON.parse(values.get('clickbridge.phoneToken')), {
    active: { credential: legacy, version: 0 },
    pending,
  });
});
