import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';

import { PairingController } from '../public/pairing-controller.js';
import { MemorySettingsStore, PhoneSettingsStore } from '../public/phone-settings-store.js';
import { FakeSocket } from './pwa-test-helpers.js';

const REFERENCE = 'A'.repeat(43);
const CLAIM_ID = '018f63f5-6f3d-7d21-88bc-9ef561f030e2';
const CREDENTIAL = 'd'.repeat(64);
const REPLACEMENT = 'e'.repeat(64);

function deferred() {
  let resolve;
  const promise = new Promise((settle) => { resolve = settle; });
  return { promise, resolve };
}

async function settleAsyncWork() {
  await new Promise((resolve) => setImmediate(resolve));
}

function observeAck(socket) {
  const observed = deferred();
  const originalSend = socket.send.bind(socket);
  socket.send = (raw) => {
    originalSend(raw);
    if (socket.sent.at(-1).type === 'pair.credential.ack') observed.resolve();
  };
  return observed.promise;
}

function harness(overrides = {}) {
  const sockets = [];
  const states = [];
  const started = [];
  const settings = overrides.settings ?? new MemorySettingsStore();
  const controller = new PairingController({
    location: new URL('https://click.example/pair/web'),
    settings,
    createSocket(url) {
      const socket = new FakeSocket();
      socket.url = url;
      sockets.push(socket);
      return socket;
    },
    idGenerator: () => CLAIM_ID,
    randomBytes: () => Uint8Array.from({ length: 32 }, () => 0xbb),
    onState: (state) => states.push(state),
    startTransport: overrides.startTransport ?? ((active) => { started.push(active); return true; }),
    authenticateCredential: overrides.authenticateCredential ?? (async () => false),
    crypto: overrides.crypto ?? globalThis.crypto,
  });
  return { controller, settings, sockets, states, started };
}

test('claim lifecycle uses one same-origin claimant socket and keeps reference only in memory', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  assert.equal(h.sockets.length, 1);
  assert.equal(h.sockets[0].url, 'wss://click.example/ws');

  h.sockets[0].open();
  assert.deepEqual(h.sockets[0].sent, [{
    type: 'pair.claim',
    v: 1,
    reference: REFERENCE,
    claimId: CLAIM_ID,
    sessionNonce: 'bb'.repeat(32),
    pairingVersion: 1,
    clientKind: 'pwa',
  }]);
  assert.equal(JSON.stringify(h.states).includes(REFERENCE), false);
  assert.equal(JSON.stringify(h.settings).includes(REFERENCE), false);
});

test('credential is staged before an exact Web Crypto HMAC proof is acknowledged', async () => {
  const order = [];
  const signature = deferred();
  const ackSent = deferred();
  const settings = new MemorySettingsStore();
  const originalStage = settings.stage.bind(settings);
  settings.stage = (slot) => { order.push('stage'); return originalStage(slot); };
  const expectedProof = createHmac('sha256', Buffer.from(CREDENTIAL, 'hex'))
    .update(`clickbridge-pair-activate:v1:${CLAIM_ID}:7`, 'utf8').digest();
  const h = harness({
    settings,
    crypto: { subtle: {
      async importKey() { order.push('import'); return {}; },
      sign() { order.push('sign'); return signature.promise; },
    } },
  });
  h.controller.start(REFERENCE);
  const originalSend = h.sockets[0].send.bind(h.sockets[0]);
  h.sockets[0].send = (raw) => {
    originalSend(raw);
    if (h.sockets[0].sent.at(-1).type === 'pair.credential.ack') ackSent.resolve();
  };
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  assert.deepEqual(order, ['stage', 'import']);
  await Promise.resolve();
  assert.deepEqual(order, ['stage', 'import', 'sign']);
  signature.resolve(expectedProof);
  await ackSent.promise;

  assert.deepEqual(h.settings.getPending(), { credential: CREDENTIAL, version: 7 });
  assert.deepEqual(h.sockets[0].sent[1], {
    type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID,
    credentialVersion: 7, proof: expectedProof.toString('hex'),
  });
  assert.equal(h.started.length, 0);
});

test('activation promotes pending before starting the ordinary phone transport', async () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));

  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.started, [{ credential: CREDENTIAL, version: 7 }]);
});

test('a storage failure sends no credential acknowledgment and preserves active', async () => {
  const active = { credential: 'a'.repeat(64), version: 6 };
  const settings = {
    getActive: () => active,
    getPending: () => null,
    stage: () => false,
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await Promise.resolve();

  assert.equal(h.sockets[0].sent.length, 1);
  assert.deepEqual(settings.getActive(), active);
  assert.equal(h.states.at(-1).phase, 'failed');
  assert.equal(JSON.stringify(h.states).includes(CREDENTIAL), false);
});

test('startup recovery authenticates pending first and promotes it before transport', async () => {
  const h = harness({ authenticateCredential: async (slot) => slot.version === 7 });
  h.settings.setActive({ credential: 'a'.repeat(64), version: 6 });
  h.settings.stage({ credential: CREDENTIAL, version: 7 });

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.started, [{ credential: CREDENTIAL, version: 7 }]);
});

test('recovery discards rejected pending and falls back to the old active credential', async () => {
  const attempts = [];
  const h = harness({
    authenticateCredential: async (slot) => {
      attempts.push(slot.version);
      return slot.version === 6;
    },
  });
  const active = { credential: 'a'.repeat(64), version: 6 };
  h.settings.setActive(active);
  h.settings.stage({ credential: CREDENTIAL, version: 7 });

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(attempts, [7, 6]);
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.settings.getActive(), active);
  assert.deepEqual(h.started, [active]);
});

test('credential replacement is terminal until an explicit new pairing start', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].serverClose(4004, 'credential_replaced');

  assert.equal(h.states.at(-1).phase, 'replaced');
  assert.equal(h.sockets.length, 1);
});

test('recovery retries when pending changes during authentication, including same-version replacement', async () => {
  const firstAuthentication = deferred();
  const attempts = [];
  const h = harness({
    authenticateCredential: async (slot) => {
      attempts.push(slot.credential);
      if (attempts.length === 1) return firstAuthentication.promise;
      return slot.credential === REPLACEMENT;
    },
  });
  const active = { credential: 'a'.repeat(64), version: 6 };
  h.settings.setActive(active);
  h.settings.stage({ credential: CREDENTIAL, version: 7 });

  const recovery = h.controller.recover();
  h.settings.stage({ credential: REPLACEMENT, version: 7 });
  firstAuthentication.resolve(true);

  assert.equal(await recovery, true);
  assert.deepEqual(attempts, [CREDENTIAL, REPLACEMENT]);
  assert.deepEqual(h.settings.getActive(), { credential: REPLACEMENT, version: 7 });
  assert.deepEqual(h.started, [{ credential: REPLACEMENT, version: 7 }]);
});

test('pair.active cannot promote a pending credential different from the acknowledged slot', async () => {
  const active = { credential: 'a'.repeat(64), version: 6 };
  const h = harness();
  h.settings.setActive(active);
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.settings.stage({ credential: REPLACEMENT, version: 7 });
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.settings.getActive(), active);
  assert.deepEqual(h.settings.getPending(), { credential: REPLACEMENT, version: 7 });
  assert.deepEqual(h.started, []);
  assert.equal(h.states.at(-1).phase, 'failed');
});

test('recovery returns false and publishes failed when transport startup rejects activation', async () => {
  const phases = [];
  const h = harness({
    authenticateCredential: async () => true,
    startTransport: () => false,
  });
  h.controller.onState = (state) => phases.push(state.phase);
  h.settings.stage({ credential: CREDENTIAL, version: 7 });

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(phases, ['failed']);
  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
});

test('recovery reports a real promotion write failure and preserves old active without transport', async () => {
  const active = { credential: 'a'.repeat(64), version: 6 };
  const pending = { credential: CREDENTIAL, version: 7 };
  let serialized = JSON.stringify({ active, pending });
  const settings = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem() { throw new Error('blocked'); },
    removeItem() {},
  });
  const h = harness({ settings, authenticateCredential: async () => true });

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(settings.getActive(), active);
  assert.deepEqual(settings.getPending(), pending);
  assert.deepEqual(h.started, []);
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'storage_failed' });
});

test('activation uses the acknowledged slot after promotion without a fallible reread', async () => {
  const pending = { credential: CREDENTIAL, version: 7 };
  let promoted = false;
  const settings = {
    stage: () => true,
    getPending: () => pending,
    promotePending(expected) {
      promoted = expected.credential === pending.credential && expected.version === pending.version;
      return true;
    },
    getActive() { throw new Error('reread unavailable'); },
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await Promise.resolve();

  assert.equal(promoted, true);
  assert.deepEqual(h.started, [pending]);
  assert.equal(h.states.filter((state) => state.phase === 'active').length, 1);
});
