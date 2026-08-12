import test from 'node:test';
import assert from 'node:assert/strict';

import * as credentialLifecycleModule from '../public/credential-lifecycle-controller.js';

const { CredentialLifecycleController } = credentialLifecycleModule;

import {
  clearTokenChange,
  MemorySettingsStore,
  PhoneSettingsStore,
  reconcileSavedToken,
  saveTokenChange,
  tokenTransportCanResume,
} from '../public/phone-settings-store.js';

const immediateLocks = { request: (_name, _options, callback) => callback() };
const generation = (store) => store.getSnapshot().generation;
const fixedEpoch = '00000000-0000-4000-8000-000000000001';

class QueuedWebLocks {
  constructor() { this.tail = Promise.resolve(); }

  request(_name, _options, callback) {
    const result = this.tail.then(callback);
    this.tail = result.catch(() => {});
    return result;
  }
}

test('memory settings store defaults to no token and keep-warm off', () => {
  const store = new MemorySettingsStore();
  assert.equal(store.getToken(), null);
  assert.equal(store.getKeepWarm(), false);
});

test('settings store replaces and clears the token without exposing storage details', async () => {
  const store = new MemorySettingsStore();
  await store.setToken('a'.repeat(64));
  assert.equal(store.getToken(), 'a'.repeat(64));
  await store.clearToken();
  assert.equal(store.getToken(), null);
});

test('settings store rejects coercible non-string credentials', async () => {
  const store = new MemorySettingsStore();
  const token = 'a'.repeat(64);

  for (const hostile of [[token], new String(token), null]) {
    assert.equal(await store.setToken(hostile), false);
    assert.equal(await store.setActive({ credential: hostile, version: 1 }, 0), false);
    assert.equal(await store.stage({ credential: hostile, version: 1 }, 0), false);
  }

  assert.equal(store.getToken(), null);
  assert.equal(store.getActive(), null);
  assert.equal(store.getPending(), null);
});

test('settings store rejects non-record credential slot containers', async () => {
  const store = new MemorySettingsStore();
  const token = 'a'.repeat(64);
  const accessorSlot = { version: 1 };
  Object.defineProperty(accessorSlot, 'credential', { enumerable: true, get: () => token });
  const throwingSlot = new Proxy({}, { getPrototypeOf: () => { throw new Error('hostile'); } });
  const hostileSlots = [
    [], new String('slot'), new Date(0), Object.create({ decorated: true }), accessorSlot, throwingSlot,
  ];
  for (const slot of hostileSlots) {
    if (slot !== accessorSlot && slot !== throwingSlot) {
      slot.credential = token;
      slot.version = 1;
    }
    assert.equal(await store.setActive(slot, 0), false);
    assert.equal(await store.stage(slot, 0), false);
  }

  assert.equal(store.getActive(), null);
  assert.equal(store.getPending(), null);
});

test('settings store ignores serialized non-record slot containers', () => {
  const token = 'a'.repeat(64);
  for (const serialized of [
    JSON.stringify({ active: [token, 1], pending: null }),
    JSON.stringify({ active: null, pending: [token, 1] }),
  ]) {
    const store = new PhoneSettingsStore({ getItem: () => serialized }, immediateLocks);
    assert.equal(store.getActive(), null);
    assert.equal(store.getPending(), null);
  }
});

test('credential mutations preserve malformed structured storage instead of hiding a version fence', async () => {
  const malformedRecords = [
    JSON.stringify([{ credential: 'f'.repeat(64), version: 9 }]),
    JSON.stringify({
      active: ['f'.repeat(64), 9],
      pending: { credential: 'e'.repeat(64), version: 10 },
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 1 },
      pending: { credential: ['e'.repeat(64)], version: 10 },
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 1 }, pending: null, generation: -1,
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 1 }, pending: null,
      generation: Number.MAX_SAFE_INTEGER + 1,
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 1 }, pending: null,
      generation: 2, provenance: 'unknown',
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 0 }, pending: null,
      generation: 2, provenance: 'authoritative',
    }),
    JSON.stringify({
      active: { credential: 'a'.repeat(64), version: 1 },
      pending: { credential: 'b'.repeat(64), version: 3 },
      generation: 2, provenance: 'authoritative',
    }),
  ];

  for (const original of malformedRecords) {
    let serialized = original;
    const store = new PhoneSettingsStore({
      getItem: () => serialized,
      setItem: (_key, value) => { serialized = String(value); },
    }, immediateLocks);

    assert.equal(await store.setToken('b'.repeat(64)), false);
    assert.equal(await store.setActive({ credential: 'c'.repeat(64), version: 2 }, 0), false);
    assert.equal(serialized, original);
    assert.equal(store.getToken(), null);
  }
});

test('credential generation overflow fails closed without changing storage', async () => {
  const original = JSON.stringify({
    active: { credential: 'a'.repeat(64), version: 1 },
    pending: null,
    generation: Number.MAX_SAFE_INTEGER,
  });
  let serialized = original;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks);

  assert.equal(await store.setToken('b'.repeat(64)), false);
  assert.equal(serialized, original);
});

test('settings store never returns coercible non-string credentials from storage', () => {
  const token = 'a'.repeat(64);

  for (const serialized of [
    [token],
    new String(token),
    JSON.stringify({ active: { credential: [token], version: 1 }, pending: null }),
  ]) {
    const store = new PhoneSettingsStore({ getItem: () => serialized }, immediateLocks);
    assert.equal(store.getToken(), null);
    assert.equal(store.getActive(), null);
  }
});

test('localStorage failures degrade to safe defaults', async () => {
  const storage = {
    getItem() { throw new Error('blocked'); },
    setItem() { throw new Error('blocked'); },
    removeItem() { throw new Error('blocked'); },
  };
  const store = new PhoneSettingsStore(storage, immediateLocks);

  assert.equal(store.getToken(), null);
  assert.equal(store.getKeepWarm(), false);
  assert.equal(await store.setToken('a'.repeat(64)), false);
  assert.equal(store.setKeepWarm(true), false);
  assert.equal(await store.clearToken(), false);
});

test('credential mutations fail closed when cross-context locking is unavailable', async () => {
  let serialized = null;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = value; },
  }, null);

  assert.equal(await store.setToken('a'.repeat(64)), false);
  assert.equal(await store.setActive({ credential: 'b'.repeat(64), version: 1 }, 0), false);
  assert.equal(serialized, null);
});

test('credential mutations fail closed when lock discovery or acquisition fails', async () => {
  for (const locks of [
    Object.defineProperty({}, 'request', { get() { throw new Error('blocked'); } }),
    { request: () => Promise.reject(new Error('denied')) },
  ]) {
    let serialized = null;
    const store = new PhoneSettingsStore({
      getItem: () => serialized,
      setItem: (_key, value) => { serialized = String(value); },
    }, locks);

    assert.equal(await store.setToken('a'.repeat(64)), false);
    assert.equal(serialized, null);
  }
});

test('credential mutations preserve present unreadable non-string storage', async () => {
  const unreadable = ['a'.repeat(64)];
  let stored = unreadable;
  const store = new PhoneSettingsStore({
    getItem: () => stored,
    setItem: (_key, value) => { stored = value; },
  }, immediateLocks);

  assert.equal(await store.setToken('b'.repeat(64)), false);
  assert.equal(await store.setActive({ credential: 'c'.repeat(64), version: 1 }, 0), false);
  assert.equal(stored, unreadable);
});

test('failed token save leaves application state unchanged and gives a safe recovery message', async () => {
  const token = 'a'.repeat(64);
  const settings = { setToken: () => false };
  let stateToken = null;

  const outcome = await saveTokenChange(settings, token, () => { stateToken = token; });

  assert.equal(outcome.ok, false);
  assert.equal(stateToken, null);
  assert.match(outcome.message, /browser storage settings/i);
  assert.equal(outcome.message.includes(token), false);
});

test('failed token clear keeps application state paired and gives a safe recovery message', async () => {
  const settings = { clearToken: () => false };
  let stateToken = 'stored';

  const outcome = await clearTokenChange(settings, () => { stateToken = null; });

  assert.equal(outcome.ok, false);
  assert.equal(stateToken, 'stored');
  assert.match(outcome.message, /browser storage settings/i);
});

test('successful token changes commit application state after storage succeeds', async () => {
  const settings = new MemorySettingsStore();
  let stateToken = null;

  assert.deepEqual(
    await saveTokenChange(settings, 'b'.repeat(64), () => { stateToken = 'b'.repeat(64); }),
    { ok: true },
  );
  assert.equal(stateToken, 'b'.repeat(64));
  assert.deepEqual(await clearTokenChange(settings, () => { stateToken = null; }), { ok: true });
  assert.equal(stateToken, null);
});

test('durable token save suppresses a stale post-save callback', async () => {
  let release;
  let current = true;
  let callbacks = 0;
  const settings = {
    setToken: () => new Promise((resolve) => { release = resolve; }),
  };
  const saving = saveTokenChange(
    settings, 'a'.repeat(64), () => { callbacks += 1; }, () => current,
  );

  current = false;
  release(true);
  assert.deepEqual(await saving, { ok: true });
  assert.equal(callbacks, 0);
});

test('a save completing after hide and show reconciles the durable token exactly once', async () => {
  let release;
  let visible = true;
  let activeToken = 'f'.repeat(64);
  let applications = 0;
  const resumedTokens = [];
  let saveInFlight = true;
  const settings = new MemorySettingsStore();
  const durableSave = saveTokenChange({
    setToken: () => new Promise((resolve) => { release = async () => {
      await settings.setToken('a'.repeat(64));
      resolve(true);
    }; }),
  }, 'a'.repeat(64), (token) => { activeToken = token; applications += 1; }, () => false);

  visible = false;
  visible = true;
  for (const trigger of ['visible', 'online']) {
    if (tokenTransportCanResume(saveInFlight, activeToken, false)) resumedTokens.push([trigger, activeToken]);
  }
  await release();
  saveInFlight = false;
  assert.deepEqual(await durableSave, { ok: true });
  assert.equal(activeToken, 'f'.repeat(64));
  assert.equal(reconcileSavedToken(
    settings, (token) => { activeToken = token; applications += 1; }, () => visible,
  ), true);
  assert.equal(activeToken, 'a'.repeat(64));
  assert.equal(applications, 1);
  assert.deepEqual(resumedTokens, []);
  if (tokenTransportCanResume(saveInFlight, activeToken, false)) resumedTokens.push(['saved', activeToken]);
  assert.deepEqual(resumedTokens, [['saved', 'a'.repeat(64)]]);
});

function lifecycleHarness(initialToken = 'f'.repeat(64)) {
  let visible = true;
  let token = initialToken;
  let ready = false;
  const applied = [];
  const cleared = [];
  const connected = [];
  const errors = [];
  const durable = { token: initialToken, readable: true };
  const saves = [];
  const clears = [];
  const settings = {
    getToken: () => durable.token,
    getSnapshot: () => durable.readable
      ? { active: durable.active ?? (durable.token
        ? { credential: durable.token, version: 0 } : null), pending: null, generation: 'test' }
      : null,
    setToken(next) {
      return new Promise((resolve) => saves.push((success = true) => {
        if (success) durable.token = next;
        resolve(success);
      }));
    },
    clearToken() {
      return new Promise((resolve) => clears.push((success = true) => {
        if (success) durable.token = null;
        resolve(success);
      }));
    },
  };
  const controller = new CredentialLifecycleController({
    settings,
    isVisible: () => visible,
    currentToken: () => token,
    transportReady: () => ready,
    applyToken(next) { token = next; applied.push(next); ready = true; },
    clearToken() { token = null; cleared.push(true); ready = false; },
    connect() { connected.push(token); ready = true; },
    reportError: (message) => errors.push(message),
  });
  return { controller, durable, saves, clears, applied, cleared, connected, errors,
    token: () => token, visible: (next) => { visible = next; }, ready: (next) => { ready = next; } };
}

test('pairing activation publishes only after the promoted durable snapshot is verified', async () => {
  const harness = lifecycleHarness();
  const paired = { credential: 'a'.repeat(64), version: 1 };
  harness.durable.token = paired.credential;
  harness.durable.active = paired;

  assert.equal(await harness.controller.activatePairing(paired, new AbortController().signal), true);
  assert.deepEqual(harness.applied, [paired.credential]);
  assert.equal(harness.token(), paired.credential);
});

test('a newer claimant waits out an older Forget intent and exclusively owns publication', async () => {
  const harness = lifecycleHarness();
  const clearing = harness.controller.clear();
  const paired = { credential: 'a'.repeat(64), version: 1 };
  harness.durable.token = paired.credential;
  harness.durable.active = paired;
  const activating = harness.controller.activatePairing(paired, new AbortController().signal);

  assert.deepEqual(harness.applied, []);
  harness.clears.shift()(true);
  assert.equal(await clearing, true);
  assert.equal(await activating, true);
  assert.deepEqual(harness.cleared, []);
  assert.deepEqual(harness.applied, [paired.credential]);
});

test('an aborted pairing activation cannot publish or resume the ordinary transport', async () => {
  const harness = lifecycleHarness();
  const paired = { credential: 'a'.repeat(64), version: 1 };
  harness.durable.token = paired.credential;
  harness.durable.active = paired;
  const abort = new AbortController();
  abort.abort();

  assert.equal(await harness.controller.activatePairing(paired, abort.signal), false);
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);

  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);
});

test('production lifecycle blocks old-token visible and online reconnect until gated save applies', async () => {
  const harness = lifecycleHarness();
  const next = 'a'.repeat(64);
  const saving = harness.controller.save(next);
  harness.visible(false);
  harness.ready(false);
  harness.visible(true);
  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.connected, []);
  assert.deepEqual(harness.applied, []);

  harness.saves.shift()();
  assert.equal(await saving, true);
  assert.deepEqual(harness.applied, [next]);
  assert.deepEqual(harness.connected, []);
  assert.equal(harness.token(), next);
});

test('production lifecycle gives only the latest overlapping save ownership', async () => {
  const harness = lifecycleHarness();
  const tokenA = 'a'.repeat(64);
  const tokenB = 'b'.repeat(64);
  const savingA = harness.controller.save(tokenA);
  const savingB = harness.controller.save(tokenB);
  harness.saves.shift()();
  assert.equal(await savingA, true);
  assert.deepEqual(harness.applied, []);
  harness.saves.shift()();
  assert.equal(await savingB, true);
  assert.deepEqual(harness.applied, [tokenB]);
  assert.equal(harness.token(), tokenB);
});

test('production lifecycle gives clear intent ownership over an older save', async () => {
  const harness = lifecycleHarness();
  const saving = harness.controller.save('a'.repeat(64));
  const clearing = harness.controller.clear();
  harness.saves.shift()();
  assert.equal(await saving, true);
  assert.deepEqual(harness.applied, []);
  harness.clears.shift()();
  assert.equal(await clearing, true);
  assert.deepEqual(harness.cleared, [true]);
  assert.equal(harness.token(), null);
});

test('production lifecycle remains suspended while durable reconciliation is unreadable', async () => {
  const harness = lifecycleHarness();
  const saving = harness.controller.save('a'.repeat(64));
  harness.saves.shift()();
  harness.durable.readable = false;
  assert.equal(await saving, true);
  harness.ready(false);
  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);
});

test('failed durable reconciliation requires an explicit new credential intent', async () => {
  const harness = lifecycleHarness();
  const next = 'a'.repeat(64);
  const saving = harness.controller.save(next);
  harness.saves.shift()();
  harness.durable.readable = false;
  assert.equal(await saving, true);

  harness.durable.token = next;
  harness.durable.readable = true;
  harness.ready(false);
  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);

  const retrying = harness.controller.save(next);
  harness.saves.shift()();
  assert.equal(await retrying, true);
  assert.deepEqual(harness.applied, [next]);
});

test('stale save success then latest save failure reconciles durable truth without old reconnect', async () => {
  const harness = lifecycleHarness();
  const tokenA = 'a'.repeat(64);
  const savingA = harness.controller.save(tokenA);
  const savingB = harness.controller.save('b'.repeat(64));
  harness.saves.shift()(true);
  assert.equal(await savingA, true);
  harness.saves.shift()(false);
  assert.equal(await savingB, false);

  assert.deepEqual(harness.applied, [tokenA]);
  assert.deepEqual(harness.connected, []);
  assert.equal(harness.token(), tokenA);
});

test('stale clear success then latest save failure reconciles durable absence without old reconnect', async () => {
  const harness = lifecycleHarness();
  const clearing = harness.controller.clear();
  const saving = harness.controller.save('a'.repeat(64));
  harness.clears.shift()(true);
  assert.equal(await clearing, true);
  harness.saves.shift()(false);
  assert.equal(await saving, false);

  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);
  assert.deepEqual(harness.cleared, [true]);
  assert.equal(harness.token(), null);
});

test('stale save success then latest clear failure reconciles durable truth without old reconnect', async () => {
  const harness = lifecycleHarness();
  const tokenA = 'a'.repeat(64);
  const saving = harness.controller.save(tokenA);
  const clearing = harness.controller.clear();
  harness.saves.shift()(true);
  assert.equal(await saving, true);
  harness.clears.shift()(false);
  assert.equal(await clearing, false);

  assert.deepEqual(harness.applied, [tokenA]);
  assert.deepEqual(harness.connected, []);
  assert.equal(harness.token(), tokenA);
});

test('reconciliation waits for every outstanding operation and preserves latest expectation', async () => {
  const harness = lifecycleHarness();
  const tokenA = 'a'.repeat(64);
  const tokenB = 'b'.repeat(64);
  const savingA = harness.controller.save(tokenA);
  const savingB = harness.controller.save(tokenB);
  harness.visible(false);
  harness.ready(false);

  harness.saves.pop()(true);
  assert.equal(await savingB, true);
  harness.saves.shift()(true);
  assert.equal(await savingA, true);
  assert.equal(harness.durable.token, tokenA);

  harness.visible(true);
  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.connected, []);
  assert.equal(harness.token(), 'f'.repeat(64));
});

test('failed latest operation remains suspended when durable truth cannot be proven', async () => {
  const harness = lifecycleHarness();
  harness.durable.readable = false;
  harness.ready(false);
  const saving = harness.controller.save('a'.repeat(64));
  harness.saves.shift()(false);
  assert.equal(await saving, false);

  harness.controller.visible();
  harness.controller.online();
  assert.deepEqual(harness.applied, []);
  assert.deepEqual(harness.cleared, []);
  assert.deepEqual(harness.connected, []);
  assert.equal(harness.token(), 'f'.repeat(64));
});

test('keep-warm preference is persisted as a boolean', () => {
  const store = new MemorySettingsStore();
  store.setKeepWarm(true);
  assert.equal(store.getKeepWarm(), true);
  store.setKeepWarm(false);
  assert.equal(store.getKeepWarm(), false);
});

test('pending credentials are staged without replacing the active credential', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };

  assert.equal(await store.setActive(active, generation(store)), true);
  assert.equal(await store.stage(pending, generation(store)), true);

  assert.deepEqual(store.getActive(), active);
  assert.deepEqual(store.getPending(), pending);
  assert.equal(store.getToken(), active.credential);
});

test('promoting pending atomically installs it as active and clears the pending slot', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await store.setActive(active, generation(store));
  await store.stage(pending, generation(store));

  assert.equal(await store.promotePending(pending, generation(store)), true);
  assert.deepEqual(store.getActive(), pending);
  assert.equal(store.getPending(), null);
});

test('a newer active token invalidates pending so delayed promotion cannot overwrite it', async () => {
  const store = new MemorySettingsStore();
  const pending = { credential: 'b'.repeat(64), version: 2 };
  const replacement = 'c'.repeat(64);
  const active = { credential: 'a'.repeat(64), version: 1 };
  await store.setActive(active, generation(store));
  await store.stage(pending, generation(store));
  const stagedGeneration = generation(store);

  assert.equal(await store.setToken(replacement), true);
  assert.equal(store.getPending(), null);
  assert.equal(await store.promotePending(pending, stagedGeneration), false);
  assert.equal(store.getToken(), replacement);
});

test('a newer active token fences delayed work without fabricating the server version', async () => {
  const store = new MemorySettingsStore();
  const pending = { credential: 'b'.repeat(64), version: 2 };
  const replacement = 'c'.repeat(64);
  const active = { credential: 'a'.repeat(64), version: 1 };
  await store.setActive(active, generation(store));
  const activeGeneration = generation(store);
  await store.stage(pending, activeGeneration);
  const stagedGeneration = generation(store);

  assert.equal(await store.setToken(replacement), true);
  assert.equal(await store.stage(pending, activeGeneration), false);
  assert.equal(await store.promotePending(pending, stagedGeneration), false);
  assert.deepEqual(store.getActive(), { credential: replacement, version: 0 });
  assert.equal(store.getPending(), null);

  assert.equal(await store.stage(
    { credential: 'd'.repeat(64), version: 1 }, generation(store),
  ), false);
  const replacementActive = { credential: 'd'.repeat(64), version: 1 };
  assert.equal(await store.setActive(replacementActive, generation(store)), true);
  const next = { credential: 'e'.repeat(64), version: 2 };
  assert.equal(await store.stage(next, generation(store)), true);
  assert.deepEqual(store.getPending(), next);
});

test('setActive generation CAS rejects delayed rotation after a manual replacement', async () => {
  let tail = Promise.resolve();
  const locks = {
    request(_name, _options, callback) {
      const result = tail.then(callback);
      tail = result.catch(() => {});
      return result;
    },
  };
  let serialized = JSON.stringify({
    active: { credential: 'a'.repeat(64), version: 4 }, pending: null, generation: 8,
    provenance: 'authoritative',
  });
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const stale = new PhoneSettingsStore(storage, locks);
  const manual = new PhoneSettingsStore(storage, locks);

  assert.equal(await manual.setToken('c'.repeat(64)), true);
  assert.equal(await stale.setActive({ credential: 'b'.repeat(64), version: 5 }, 8), false);
  assert.deepEqual(stale.getActive(), { credential: 'c'.repeat(64), version: 0 });
});

test('a same-token manual save still advances the local fence for delayed work', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await store.setActive(active, generation(store));
  const activeGeneration = generation(store);
  await store.stage(pending, activeGeneration);
  const stagedGeneration = generation(store);

  assert.equal(await store.setToken(active.credential), true);
  assert.equal(await store.stage(pending, activeGeneration), false);
  assert.equal(await store.promotePending(pending, stagedGeneration), false);
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
});

test('cross-context credential mutations serialize so a concurrent manual save wins', async () => {
  let tail = Promise.resolve();
  const locks = {
    request(_name, _options, callback) {
      const result = tail.then(callback);
      tail = result.catch(() => {});
      return result;
    },
  };
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  const replacement = 'c'.repeat(64);
  let serialized = JSON.stringify({ active, pending, provenance: 'authoritative' });
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const manual = new PhoneSettingsStore(storage, locks);
  let manualSave;
  let interleave = true;
  const promotion = new PhoneSettingsStore({
    getItem: storage.getItem,
    setItem(key, value) {
      if (interleave) {
        interleave = false;
        manualSave = manual.setToken(replacement);
      }
      storage.setItem(key, value);
    },
  }, locks);

  await promotion.promotePending(pending, 0);
  assert.equal(await manualSave, true);
  assert.deepEqual(manual.getActive(), { credential: replacement, version: 0 });
  assert.equal(manual.getPending(), null);
});

test('cancel before stage advances generation and fences delayed staging', async () => {
  let tail = Promise.resolve();
  const locks = {
    request(_name, _options, callback) {
      const result = tail.then(callback);
      tail = result.catch(() => {});
      return result;
    },
  };
  let serialized = JSON.stringify({
    active: { credential: 'a'.repeat(64), version: 1 },
    pending: { credential: 'b'.repeat(64), version: 2 },
    generation: 4, provenance: 'authoritative',
  });
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const canceling = new PhoneSettingsStore(storage, locks);
  const staging = new PhoneSettingsStore(storage, locks);
  const expectedGeneration = generation(staging);

  assert.equal(await canceling.discardPending(
    canceling.getPending(), canceling.getSnapshot().generation,
  ), true);
  assert.equal(await staging.stage(
    { credential: 'b'.repeat(64), version: 2 }, expectedGeneration,
  ), false);
  assert.equal(staging.getPending(), null);
});

test('delayed discard cannot clear a newer pending credential from another store', async () => {
  let serialized = null;
  const locks = { request: (_name, _options, callback) => callback() };
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const stale = new PhoneSettingsStore(storage, locks);
  const current = new PhoneSettingsStore(storage, locks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  const older = { credential: 'b'.repeat(64), version: 2 };
  const newer = { credential: 'c'.repeat(64), version: 2 };
  await current.setActive(active, current.getSnapshot().generation);
  await current.stage(older, current.getSnapshot().generation);
  const staleGeneration = stale.getSnapshot().generation;
  await current.discardPending(older, current.getSnapshot().generation);
  await current.stage(newer, current.getSnapshot().generation);

  assert.equal(await stale.discardPending(older, staleGeneration), false);
  assert.deepEqual(current.getPending(), newer);
});

test('two stores under one Web Lock require the exact pending identity even at the current generation', async () => {
  const locks = new QueuedWebLocks();
  let serialized = null;
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const stale = new PhoneSettingsStore(storage, locks);
  const current = new PhoneSettingsStore(storage, locks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  const older = { credential: 'b'.repeat(64), version: 2 };
  const newer = { credential: 'c'.repeat(64), version: 2 };
  await current.setActive(active, generation(current));
  await current.stage(older, generation(current));
  await current.discardPending(older, generation(current));
  await current.stage(newer, generation(current));

  assert.equal(await stale.discardPending(older, generation(stale)), false);
  assert.deepEqual(current.getPending(), newer);
});

test('two stores under one Web Lock require the captured generation even when pending identity returns', async () => {
  const locks = new QueuedWebLocks();
  let serialized = null;
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const stale = new PhoneSettingsStore(storage, locks);
  const current = new PhoneSettingsStore(storage, locks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await current.setActive(active, generation(current));
  await current.stage(pending, generation(current));
  const capturedGeneration = generation(stale);
  await current.discardPending(pending, generation(current));
  await current.stage(pending, generation(current));

  assert.equal(await stale.discardPending(pending, capturedGeneration), false);
  assert.deepEqual(current.getPending(), pending);
});

test('initially hidden recovery fences visible and online resume until deferred authentication clears', async () => {
  const RecoveryGate = credentialLifecycleModule.PairingRecoveryGate;
  assert.equal(typeof RecoveryGate, 'function');
  const authentication = (() => {
    let resolve;
    const promise = new Promise((next) => { resolve = next; });
    return { promise, resolve };
  })();
  let visible = false;
  const ordinary = [];
  const starts = [];
  const gate = new RecoveryGate({
    needed: true,
    isVisible: () => visible,
    startRecovery: () => starts.push('recovery'),
    recover: () => authentication.promise,
    visible: () => ordinary.push('visible'),
    online: () => ordinary.push('online'),
  });

  gate.visible();
  visible = true;
  gate.visible();
  gate.online();
  assert.deepEqual(starts, ['recovery']);
  assert.deepEqual(ordinary, []);

  authentication.resolve(true);
  await new Promise((resolve) => setImmediate(resolve));
  gate.online();
  assert.deepEqual(ordinary, ['online']);
});

test('credential probe clears its deadline after transport authentication settles', async () => {
  const authenticate = credentialLifecycleModule.authenticateCredentialProbe;
  assert.equal(typeof authenticate, 'function');
  const scheduler = new (await import('./pwa-test-helpers.js')).FakeScheduler();
  let status;
  const probe = { close() {}, connect() {} };
  const result = authenticate(
    { credential: 'a'.repeat(64), version: 1 }, new AbortController().signal,
    {
      location: new URL('https://click.example/'), scheduler,
      createTransport: (options) => { status = options.onStatus; return probe; },
    },
  );

  status({ state: 'ready' });
  assert.equal(await result, true);
  assert.equal(scheduler.tasks.size, 0);
});

test('page hide abort closes the real credential probe transport', async () => {
  const authenticate = credentialLifecycleModule.authenticateCredentialProbe;
  assert.equal(typeof authenticate, 'function');
  const scheduler = new (await import('./pwa-test-helpers.js')).FakeScheduler();
  const lifecycleTarget = new EventTarget();
  const abort = new AbortController();
  const closes = [];
  const probe = { close: (reason) => closes.push(reason), connect() {} };
  const result = authenticate(
    { credential: 'a'.repeat(64), version: 1 }, abort.signal,
    {
      location: new URL('https://click.example/'), scheduler,
      createTransport: () => probe,
    },
  );
  lifecycleTarget.addEventListener('pagehide', () => abort.abort());

  lifecycleTarget.dispatchEvent(new Event('pagehide'));
  await assert.rejects(result, /pairing_probe_cancelled/);
  assert.deepEqual(closes, ['pairing_probe_complete']);
});

test('versioned mutations reject lower and equal versions without changing stored slots', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await store.setActive(active, generation(store));
  await store.stage(pending, generation(store));

  for (const version of [4, 5]) {
    assert.equal(await store.stage({ credential: 'c'.repeat(64), version }, generation(store)), false);
    assert.equal(await store.setActive(
      { credential: 'd'.repeat(64), version }, generation(store),
    ), false);
  }

  assert.deepEqual(store.getActive(), active);
  assert.deepEqual(store.getPending(), pending);
});

test('relay-authoritative mutations require exactly the next positive version', async () => {
  const store = new MemorySettingsStore();

  assert.equal(await store.setActive({ credential: 'a'.repeat(64), version: 0 }, 0), false);
  assert.equal(await store.setActive({ credential: 'a'.repeat(64), version: 2 }, 0), false);
  assert.equal(await store.setActive({ credential: 'a'.repeat(64), version: 1 }, 0), true);
  assert.equal(await store.stage(
    { credential: 'b'.repeat(64), version: 3 }, generation(store),
  ), false);
  assert.equal(await store.stage(
    { credential: 'b'.repeat(64), version: 2 }, generation(store),
  ), true);
  assert.equal(await store.promotePending(
    { credential: 'b'.repeat(64), version: 2 }, generation(store),
  ), true);
  assert.deepEqual(store.getActive(), { credential: 'b'.repeat(64), version: 2 });
});

test('manual legacy enrollment requires explicit authoritative replacement', async () => {
  const store = new MemorySettingsStore();
  assert.equal(await store.setToken('a'.repeat(64)), true);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 0 });

  assert.equal(await store.stage(
    { credential: 'b'.repeat(64), version: 2 }, generation(store),
  ), false);
  assert.equal(await store.stage(
    { credential: 'b'.repeat(64), version: 1 }, generation(store),
  ), false);
  assert.equal(await store.setActive(
    { credential: 'b'.repeat(64), version: 1 }, generation(store),
  ), true);
});

test('promotion rejects pending credentials that are not newer than the active version', async () => {
  const active = { credential: 'a'.repeat(64), version: 2 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  let serialized = JSON.stringify({ active, pending });
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = value; },
  }, immediateLocks);

  assert.equal(await store.promotePending(pending, 0), false);
  assert.equal(store.getActive(), null);
  assert.equal(store.getPending(), null);
  assert.equal(serialized, JSON.stringify({ active, pending }));
});

test('failed pending promotion leaves both credential slots unchanged', async () => {
  let serialized = null;
  let failWrites = false;
  const storage = {
    getItem(key) { return key === 'clickbridge.phoneToken' ? serialized : null; },
    setItem(key, value) {
      if (failWrites) throw new Error('blocked');
      if (key === 'clickbridge.phoneToken') serialized = value;
    },
  };
  const store = new PhoneSettingsStore(storage, immediateLocks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  assert.equal(await store.setActive(active, generation(store)), true);
  assert.equal(await store.stage(pending, generation(store)), true);
  failWrites = true;

  assert.equal(await store.promotePending(pending, generation(store)), false);
  assert.deepEqual(store.getActive(), active);
  assert.deepEqual(store.getPending(), pending);
});

test('staging rejects a same-version replacement without disturbing the pending credential', async () => {
  const store = new MemorySettingsStore();
  const expected = { credential: 'b'.repeat(64), version: 2 };
  const replacement = { credential: 'c'.repeat(64), version: 2 };
  const active = { credential: 'a'.repeat(64), version: 1 };
  await store.setActive(active, generation(store));
  assert.equal(await store.stage(expected, generation(store)), true);

  assert.equal(await store.stage(replacement, generation(store)), false);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 1 });
  assert.deepEqual(store.getPending(), expected);
});

test('promotion requires the exact credential and version in the pending slot', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await store.setActive(active, generation(store));
  await store.stage(pending, generation(store));

  assert.equal(await store.promotePending(
    { ...pending, credential: 'c'.repeat(64) }, generation(store),
  ), false);
  assert.equal(await store.promotePending({ ...pending, version: 6 }, generation(store)), false);
  assert.deepEqual(store.getPending(), pending);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 1 });
});

test('discard and forget clear only their intended recoverable slots', async () => {
  const store = new MemorySettingsStore();
  const active = { credential: 'a'.repeat(64), version: 1 };
  await store.setActive(active, generation(store));
  const pending = { credential: 'b'.repeat(64), version: 2 };
  await store.stage(pending, generation(store));

  assert.equal(await store.discardPending(pending, generation(store)), true);
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
  assert.equal(await store.forget(), true);
  assert.equal(store.getActive(), null);
  assert.equal(store.getPending(), null);
});

test('storage failures preserve the active credential and report no transition', async () => {
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
  const store = new PhoneSettingsStore(storage, immediateLocks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  assert.equal(await store.setActive(active, generation(store)), true);
  failWrites = true;

  assert.equal(await store.stage(
    { credential: 'b'.repeat(64), version: 2 }, generation(store),
  ), false);
  assert.equal(await store.promotePending(
    { credential: 'b'.repeat(64), version: 2 }, generation(store),
  ), false);
  assert.equal(await store.forget(), false);
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
});

test('every credential mutator is atomic when its single record write fails', async () => {
  const active = { credential: 'a'.repeat(64), version: 1 };
  const pending = { credential: 'b'.repeat(64), version: 2 };
  const cases = [
    ['setToken', { active, pending: null, generation: 7, provenance: 'authoritative' },
      (store) => store.setToken('c'.repeat(64))],
    ['setActive', { active, pending: null, generation: 7, provenance: 'authoritative' },
      (store) => store.setActive({ credential: 'c'.repeat(64), version: 2 }, 7)],
    ['stage', { active, pending: null, generation: 7, provenance: 'authoritative' },
      (store) => store.stage(pending, 7)],
    ['promotePending', { active, pending, generation: 7, provenance: 'authoritative' },
      (store) => store.promotePending(pending, 7)],
    ['discardPending', { active, pending, generation: 7, provenance: 'authoritative' },
      (store) => store.discardPending(pending, 7)],
    ['forget', { active, pending, generation: 7, provenance: 'authoritative' },
      (store) => store.forget()],
  ];

  for (const [name, record, mutate] of cases) {
    const original = JSON.stringify(record);
    let serialized = original;
    const store = new PhoneSettingsStore({
      getItem: () => serialized,
      setItem: () => { throw new Error(`blocked ${name}`); },
    }, immediateLocks, () => fixedEpoch);
    assert.equal(await mutate(store), false, name);
    assert.equal(serialized, original, name);
    assert.deepEqual(store.getSnapshot(), record, name);
  }
});

test('a present malformed embedded epoch fails closed across mutators', async () => {
  const token = 'a'.repeat(64);
  const original = JSON.stringify({
    active: { credential: token, version: 1 }, pending: null,
    generation: token, provenance: 'authoritative',
  });
  let serialized = original;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks, () => fixedEpoch);
  const next = { credential: 'b'.repeat(64), version: 2 };

  assert.equal(store.getSnapshot(), null);
  for (const mutate of [
    () => store.setToken('c'.repeat(64)),
    () => store.setActive(next, token),
    () => store.stage(next, token),
    () => store.promotePending(next, token),
    () => store.discardPending(next, token),
  ]) {
    assert.equal(await mutate(), false);
    assert.equal(serialized, original);
  }
  assert.equal(await store.forget(), true);
  assert.deepEqual(JSON.parse(serialized), {
    active: null, pending: null, generation: fixedEpoch, provenance: 'unknown',
  });
});

test('a failed read aborts staging instead of overwriting an unseen active credential', async () => {
  const active = { credential: 'a'.repeat(64), version: 1 };
  let serialized = JSON.stringify({ active, pending: null, provenance: 'authoritative' });
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
  }, immediateLocks);

  assert.equal(await store.stage({ credential: 'b'.repeat(64), version: 2 }, 0), false);
  failReads = false;
  assert.deepEqual(store.getActive(), active);
  assert.equal(store.getPending(), null);
});

test('forget overwrites legacy token storage so no shadow credential remains', async () => {
  const legacy = 'a'.repeat(64);
  const values = new Map([['clickbridge.phoneToken', legacy]]);
  const store = new PhoneSettingsStore({
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  }, immediateLocks);

  assert.equal(store.getToken(), legacy);
  assert.equal(await store.forget(), true);
  assert.equal([...values.values()].some((value) => value.includes(legacy)), false);
});

test('forget recovers corrupt storage under the credential lock', async () => {
  const corrupt = '{not-json';
  let serialized = corrupt;
  let lockCalls = 0;
  const locks = {
    request(_name, _options, callback) {
      lockCalls += 1;
      return callback();
    },
  };
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const clearing = new PhoneSettingsStore(storage, locks, () => fixedEpoch);
  const observing = new PhoneSettingsStore(storage, locks);

  assert.equal(await clearing.forget(), true);
  assert.equal(lockCalls, 1);
  assert.equal(observing.getToken(), null);
  assert.deepEqual(JSON.parse(serialized), {
    active: null, pending: null, generation: fixedEpoch, provenance: 'unknown',
  });
});

test('corrupt forget recovery cannot reuse a generation captured by stale work', async () => {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
  };
  const stale = new PhoneSettingsStore(storage, immediateLocks);
  const clearing = new PhoneSettingsStore(storage, immediateLocks);
  assert.equal(await stale.setActive({ credential: 'a'.repeat(64), version: 1 }, 0), true);
  const capturedGeneration = generation(stale);

  let release;
  const queued = new Promise((resolve) => { release = resolve; }).then(() => stale.setActive(
    { credential: 'b'.repeat(64), version: 2 }, capturedGeneration,
  ));
  values.set('clickbridge.phoneToken', '{corrupt');
  assert.equal(await clearing.forget(), true);
  release();

  assert.equal(await queued, false);
  assert.equal(clearing.getToken(), null);
  assert.notEqual(clearing.getSnapshot().generation, capturedGeneration);
});

test('corrupt forget retries a colliding valid generation and fences queued stale work', async () => {
  const generationG = '00000000-0000-4000-8000-00000000000a';
  const generationFresh = '00000000-0000-4000-8000-00000000000b';
  let serialized = JSON.stringify({
    active: { credential: ['a'.repeat(64)], version: 4 }, pending: null,
    generation: generationG, provenance: 'authoritative',
  });
  const storage = {
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  };
  const epochs = [generationG, generationFresh];
  const clearing = new PhoneSettingsStore(storage, immediateLocks, () => epochs.shift());
  const stale = new PhoneSettingsStore(storage, immediateLocks);
  let release;
  const queued = new Promise((resolve) => { release = resolve; }).then(() => stale.setActive(
    { credential: 'b'.repeat(64), version: 5 }, generationG,
  ));

  assert.equal(await clearing.forget(), true);
  assert.equal(JSON.parse(serialized).generation, generationFresh);
  release();
  assert.equal(await queued, false);
  assert.equal(stale.getToken(), null);
});

test('corrupt forget derives its generation fence from one locked storage snapshot', async () => {
  const generationG = '00000000-0000-4000-8000-00000000000a';
  const generationFresh = '00000000-0000-4000-8000-00000000000b';
  const corrupt = JSON.stringify({
    active: { credential: ['a'.repeat(64)], version: 4 }, pending: null,
    generation: generationG, provenance: 'authoritative',
  });
  let serialized = corrupt;
  let reads = 0;
  const store = new PhoneSettingsStore({
    getItem() {
      reads += 1;
      if (reads > 1) return JSON.stringify({
        active: null, pending: null, generation: generationFresh, provenance: 'unknown',
      });
      return serialized;
    },
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks, () => generationG);

  assert.equal(await store.forget(), false);
  assert.equal(reads, 1);
  assert.equal(serialized, corrupt);
});

test('provenance-less versioned credentials are never inferred authoritative', async () => {
  const original = JSON.stringify({
    active: { credential: 'a'.repeat(64), version: 5 }, pending: null, generation: 9,
  });
  let serialized = original;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks);

  assert.deepEqual(store.getSnapshot(), {
    active: { credential: 'a'.repeat(64), version: 0 }, pending: null,
    generation: 9, provenance: 'unknown',
  });
  assert.equal(await store.stage({ credential: 'b'.repeat(64), version: 6 }, 9), false);
  assert.equal(serialized, original);
  assert.equal(await store.setActive({ credential: 'b'.repeat(64), version: 1 }, 9), true);
  assert.deepEqual(store.getActive(), { credential: 'b'.repeat(64), version: 1 });
});

test('credential slots are persisted as fresh canonical records', async () => {
  const credential = 'a'.repeat(64);
  const slot = {};
  Object.defineProperties(slot, {
    credential: { value: credential, enumerable: false },
    version: { value: 1, enumerable: false },
  });
  let serialized = null;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks, () => fixedEpoch);

  assert.equal(await store.setActive(slot, 0), true);
  assert.deepEqual(JSON.parse(serialized), {
    active: { credential, version: 1 }, pending: null, generation: fixedEpoch,
    provenance: 'authoritative',
  });
});

test('stateful slot descriptors cannot change after canonical validation', async () => {
  const original = JSON.stringify({
    active: null, pending: null, generation: 0, provenance: 'unknown',
  });
  let serialized = original;
  const statefulSlot = (credential, version) => {
    let reads = 0;
    return {
      slot: new Proxy({}, {
        getOwnPropertyDescriptor(_target, property) {
          if (property === 'credential') {
            reads += 1;
            return { configurable: true, enumerable: true, writable: true,
              value: reads === 1 ? credential : [credential] };
          }
          if (property === 'version') {
            return { configurable: true, enumerable: true, writable: true, value: version };
          }
          return undefined;
        },
      }),
      reads: () => reads,
    };
  };
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, immediateLocks);

  const active = statefulSlot('a'.repeat(64), 1);
  assert.equal(await store.setActive(active.slot, 0), true);
  assert.equal(active.reads(), 1);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 1 });
  const pending = statefulSlot('b'.repeat(64), 2);
  assert.equal(await store.stage(pending.slot, generation(store)), true);
  assert.equal(pending.reads(), 1);
  const promoted = statefulSlot('b'.repeat(64), 2);
  assert.equal(await store.promotePending(promoted.slot, generation(store)), true);
  assert.equal(promoted.reads(), 1);
  assert.deepEqual(store.getActive(), { credential: 'b'.repeat(64), version: 2 });
});

test('caller slot mutation while waiting for the lock cannot change the committed snapshot', async () => {
  let release;
  const locks = {
    request(_name, _options, callback) {
      return new Promise((resolve) => { release = () => resolve(callback()); });
    },
  };
  let serialized = null;
  const store = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem: (_key, value) => { serialized = String(value); },
  }, locks);
  const active = { credential: 'a'.repeat(64), version: 1 };
  const setting = store.setActive(active, 0);
  active.credential = 'f'.repeat(64);
  active.version = 99;
  release();

  assert.equal(await setting, true);
  assert.deepEqual(store.getActive(), { credential: 'a'.repeat(64), version: 1 });

  const pending = { credential: 'b'.repeat(64), version: 2 };
  const staging = store.stage(pending, generation(store));
  pending.credential = 'e'.repeat(64);
  pending.version = 88;
  release();

  assert.equal(await staging, true);
  assert.deepEqual(store.getPending(), { credential: 'b'.repeat(64), version: 2 });
});

test('legacy token requires explicit authoritative replacement before staging', async () => {
  const legacy = 'a'.repeat(64);
  const pending = { credential: 'b'.repeat(64), version: 1 };
  const values = new Map([['clickbridge.phoneToken', legacy]]);
  const store = new PhoneSettingsStore({
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
  }, immediateLocks, () => fixedEpoch);

  assert.equal(await store.stage(pending, 0), false);
  assert.equal(await store.setActive(pending, 0), true);
  assert.deepEqual(JSON.parse(values.get('clickbridge.phoneToken')), {
    active: pending,
    pending: null,
    generation: fixedEpoch,
    provenance: 'authoritative',
  });
});
