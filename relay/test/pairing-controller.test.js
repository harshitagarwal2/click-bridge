import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';

import { CREDENTIAL_REPLACED_CLOSE_CODE } from '../public/wire-protocol.js';
import { PairingController } from '../public/pairing-controller.js';
import { MemorySettingsStore, PhoneSettingsStore } from '../public/phone-settings-store.js';
import { FakeScheduler, FakeSocket } from './pwa-test-helpers.js';

const REFERENCE = 'A'.repeat(43);
const CLAIM_ID = '018f63f5-6f3d-7d21-88bc-9ef561f030e2';
const CREDENTIAL = 'd'.repeat(64);
const REPLACEMENT = 'e'.repeat(64);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((settle, fail) => { resolve = settle; reject = fail; });
  return { promise, resolve, reject };
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

function acceptClaim(socket, claimId = CLAIM_ID) {
  socket.message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId,
    confirmationCode: '123 456', expiresAtUnixMs: Date.now() + 60_000,
  }));
}

function seedAuthoritative(store, version = 6) {
  for (let next = 1; next <= version; next += 1) {
    void store.setActive(
      { credential: 'a'.repeat(64), version: next }, store.getSnapshot().generation,
    );
  }
}

function harness(overrides = {}) {
  const sockets = [];
  const states = [];
  const started = [];
  const settings = overrides.settings ?? new MemorySettingsStore();
  if (overrides.seedAuthoritative !== false
    && settings instanceof MemorySettingsStore && settings.getActive() === null) {
    seedAuthoritative(settings);
  }
  const controller = new PairingController({
    location: new URL('https://click.example/pair/web'),
    settings,
    createSocket(url) {
      const socket = new FakeSocket();
      socket.url = url;
      sockets.push(socket);
      return socket;
    },
    idGenerator: overrides.idGenerator ?? (() => CLAIM_ID),
    randomBytes: () => Uint8Array.from({ length: 32 }, () => 0xbb),
    onState: (state) => states.push(state),
    startTransport: overrides.startTransport ?? ((active) => { started.push(active); return true; }),
    authenticateCredential: overrides.authenticateCredential ?? (async () => false),
    crypto: overrides.crypto ?? globalThis.crypto,
    scheduler: overrides.scheduler ?? new FakeScheduler(),
    deadlines: overrides.deadlines,
    now: overrides.now,
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
  const ackSent = deferred();
  const settings = new MemorySettingsStore();
  const originalStage = settings.stage.bind(settings);
  settings.stage = (slot, expectedGeneration) => {
    order.push('stage');
    return originalStage(slot, expectedGeneration);
  };
  const expectedProof = createHmac('sha256', Buffer.from(CREDENTIAL, 'hex'))
    .update(`clickbridge-pair-activate:v1:${CLAIM_ID}:7`, 'utf8').digest();
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  const originalSend = h.sockets[0].send.bind(h.sockets[0]);
  h.sockets[0].send = (raw) => {
    originalSend(raw);
    if (h.sockets[0].sent.at(-1).type === 'pair.credential.ack') ackSent.resolve();
  };
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent.promise;

  assert.deepEqual(order, ['stage']);
  assert.deepEqual(h.settings.getPending(), { credential: CREDENTIAL, version: 7 });
  assert.deepEqual(h.sockets[0].sent[1], {
    type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID,
    credentialVersion: 7, proof: expectedProof.toString('hex'),
  });
  assert.equal(h.started.length, 0);
});

test('credential acknowledgment waits for the durable async stage and uses its generation fence', async () => {
  const staged = deferred();
  const active = { credential: 'a'.repeat(64), version: 6 };
  const pending = { credential: CREDENTIAL, version: 7 };
  let snapshot = { active, pending: null, generation: 'before', provenance: 'authoritative' };
  const stageCalls = [];
  const settings = {
    getSnapshot: () => snapshot,
    getActive: () => snapshot.active,
    getPending: () => snapshot.pending,
    async stage(slot, expectedGeneration) {
      stageCalls.push({ slot, expectedGeneration });
      await staged.promise;
      snapshot = { active, pending: slot, generation: 'after', provenance: 'authoritative' };
      return true;
    },
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  assert.deepEqual(h.states.at(-1), {
    phase: 'awaiting_approval', reason: null,
    confirmationCode: '123 456', expiresAtUnixMs: h.states.at(-1).expiresAtUnixMs,
  });
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(stageCalls, [{ slot: pending, expectedGeneration: 'before' }]);
  assert.equal(h.sockets[0].sent.some(({ type }) => type === 'pair.credential.ack'), false);

  staged.resolve();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(h.states.at(-1).phase, 'activating');
  assert.equal(h.sockets[0].sent.some(({ type }) => type === 'pair.credential.ack'), true);
});

test('first enrollment is durable provisional pending until pair.active promotes it', async () => {
  const settings = new MemorySettingsStore();
  const h = harness({ settings, seedAuthoritative: false });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 1,
  }));
  await ackSent;

  assert.equal(settings.getActive(), null);
  assert.deepEqual(settings.getPending(), { credential: CREDENTIAL, version: 1 });
  assert.deepEqual(h.started, []);

  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 1,
  }));
  await settleAsyncWork();
  assert.deepEqual(settings.getActive(), { credential: CREDENTIAL, version: 1 });
  assert.equal(settings.getPending(), null);
  assert.deepEqual(h.started, [{ credential: CREDENTIAL, version: 1 }]);
});

test('an interrupted first enrollment can be replaced by a fresh version-one invite', async () => {
  const settings = new MemorySettingsStore();
  const h = harness({ settings, seedAuthoritative: false });
  h.controller.start(REFERENCE);
  let ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 1,
  }));
  await ackSent;
  h.sockets[0].serverClose(1006, 'connection interrupted');

  h.controller.start(REFERENCE);
  ackSent = observeAck(h.sockets[1]);
  h.sockets[1].open();
  acceptClaim(h.sockets[1]);
  h.sockets[1].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: REPLACEMENT, credentialVersion: 1,
  }));
  await ackSent;

  assert.notEqual(h.states.at(-1).reason, 'storage_failed');
  assert.equal(settings.getActive(), null);
  assert.deepEqual(settings.getPending(), { credential: REPLACEMENT, version: 1 });
});

test('a fresh invite cannot overwrite an interrupted authoritative replacement', async () => {
  const h = harness();
  const oldActive = h.settings.getActive();
  const originalPending = { credential: CREDENTIAL, version: 7 };
  h.controller.start(REFERENCE);
  let ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].serverClose(1006, 'connection interrupted');

  h.controller.start(REFERENCE);
  h.sockets[1].open();
  acceptClaim(h.sockets[1]);
  h.sockets[1].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: REPLACEMENT, credentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.settings.getActive(), oldActive);
  assert.deepEqual(h.settings.getPending(), originalPending);
  assert.equal(h.sockets[1].sent.some(({ type }) => type === 'pair.credential.ack'), false);
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'storage_failed' });
});

test('cancelling during durable staging prevents a late acknowledgment', async () => {
  const staged = deferred();
  const active = { credential: 'a'.repeat(64), version: 6 };
  let snapshot = { active, pending: null, generation: 'before', provenance: 'authoritative' };
  const settings = {
    getSnapshot: () => snapshot,
    getActive: () => snapshot.active,
    getPending: () => snapshot.pending,
    async stage(slot) {
      await staged.promise;
      snapshot = { active, pending: slot, generation: 'after', provenance: 'authoritative' };
      return true;
    },
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await settleAsyncWork();
  h.controller.cancel();
  staged.resolve();
  await settleAsyncWork();

  assert.equal(h.sockets[0].sent.some(({ type }) => type === 'pair.credential.ack'), false);
  assert.equal(h.states.at(-1).phase, 'cancelled');
});

test('activation promotes pending before starting the ordinary phone transport', async () => {
  const h = harness();
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.started, [{ credential: CREDENTIAL, version: 7 }]);
});

test('ordinary transport waits for durable async promotion and revalidates the promoted snapshot', async () => {
  const promoted = deferred();
  const active = { credential: 'a'.repeat(64), version: 6 };
  const pending = { credential: CREDENTIAL, version: 7 };
  let snapshot = { active, pending: null, generation: 'before-stage', provenance: 'authoritative' };
  const settings = {
    getSnapshot: () => snapshot,
    getActive: () => snapshot.active,
    getPending: () => snapshot.pending,
    async stage(slot, expectedGeneration) {
      assert.equal(expectedGeneration, 'before-stage');
      snapshot = { active, pending: slot, generation: 'after-stage', provenance: 'authoritative' };
      return true;
    },
    async promotePending(slot, expectedGeneration) {
      assert.deepEqual(slot, pending);
      assert.equal(expectedGeneration, 'after-stage');
      await promoted.promise;
      snapshot = { active: slot, pending: null, generation: 'after-promote', provenance: 'authoritative' };
      return true;
    },
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();
  assert.deepEqual(h.started, []);

  promoted.resolve();
  await settleAsyncWork();
  assert.deepEqual(h.started, [pending]);
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
  acceptClaim(h.sockets[0]);
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
  await h.settings.stage(
    { credential: CREDENTIAL, version: 7 }, h.settings.getSnapshot().generation,
  );

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.started, [{ credential: CREDENTIAL, version: 7 }]);
});

test('startup recovery authenticates and promotes a provisional first enrollment', async () => {
  const settings = new MemorySettingsStore();
  const pending = { credential: CREDENTIAL, version: 1 };
  await settings.stage(pending, settings.getSnapshot().generation);
  const h = harness({
    settings,
    seedAuthoritative: false,
    authenticateCredential: async (slot) => slot.credential === CREDENTIAL,
  });

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(settings.getActive(), pending);
  assert.equal(settings.getPending(), null);
  assert.deepEqual(h.started, [pending]);
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
  await h.settings.stage(
    { credential: CREDENTIAL, version: 7 }, h.settings.getSnapshot().generation,
  );

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(attempts, [7, 6]);
  assert.equal(h.settings.getPending(), null);
  assert.deepEqual(h.settings.getActive(), active);
  assert.deepEqual(h.started, [active]);
});

test('transient pending authentication failure preserves pending and old active', async () => {
  const h = harness({ authenticateCredential: async () => { throw new Error('network'); } });
  const active = h.settings.getActive();
  const pending = { credential: CREDENTIAL, version: 7 };
  await h.settings.stage(pending, h.settings.getSnapshot().generation);

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(h.settings.getActive(), active);
  assert.deepEqual(h.settings.getPending(), pending);
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'authentication_failed' });
});

test('credential replacement is terminal until an explicit new pairing start', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].serverClose(CREDENTIAL_REPLACED_CLOSE_CODE, 'credential_replaced');

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
  await h.settings.stage(
    { credential: CREDENTIAL, version: 7 }, h.settings.getSnapshot().generation,
  );

  const recovery = h.controller.recover();
  await h.settings.setToken(REPLACEMENT);
  await h.settings.setActive(
    { credential: REPLACEMENT, version: 1 }, h.settings.getSnapshot().generation,
  );
  firstAuthentication.resolve(true);

  assert.equal(await recovery, true);
  assert.deepEqual(attempts, [CREDENTIAL, REPLACEMENT]);
  assert.deepEqual(h.settings.getActive(), { credential: REPLACEMENT, version: 1 });
  assert.deepEqual(h.started, [{ credential: REPLACEMENT, version: 1 }]);
});

test('pair.active cannot promote a pending credential different from the acknowledged slot', async () => {
  const active = { credential: 'a'.repeat(64), version: 6 };
  const h = harness();
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  await h.settings.setToken(REPLACEMENT);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.settings.getActive(), { credential: REPLACEMENT, version: 0 });
  assert.equal(h.settings.getPending(), null);
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
  await h.settings.stage(
    { credential: CREDENTIAL, version: 7 }, h.settings.getSnapshot().generation,
  );

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(phases, ['failed']);
  assert.deepEqual(h.settings.getActive(), { credential: CREDENTIAL, version: 7 });
});

test('recovery reports a real promotion write failure and preserves old active without transport', async () => {
  const active = { credential: 'a'.repeat(64), version: 6 };
  const pending = { credential: CREDENTIAL, version: 7 };
  let serialized = JSON.stringify({
    active, pending, generation: 8, provenance: 'authoritative',
  });
  const settings = new PhoneSettingsStore({
    getItem: () => serialized,
    setItem() { throw new Error('blocked'); },
    removeItem() {},
  }, { request: (_name, _options, callback) => callback() });
  const h = harness({ settings, authenticateCredential: async () => true });

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(settings.getActive(), active);
  assert.deepEqual(settings.getPending(), pending);
  assert.deepEqual(h.started, []);
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'storage_failed' });
});

test('activation uses the acknowledged slot after a verified promoted snapshot', async () => {
  const pending = { credential: CREDENTIAL, version: 7 };
  let promoted = false;
  let snapshot = {
    active: { credential: 'a'.repeat(64), version: 6 }, pending: null,
    generation: 1, provenance: 'authoritative',
  };
  const settings = {
    getSnapshot: () => snapshot,
    async stage(slot, expectedGeneration) {
      if (expectedGeneration !== snapshot.generation) return false;
      snapshot = { ...snapshot, pending: slot, generation: 2 };
      return true;
    },
    async promotePending(expected, expectedGeneration) {
      promoted = expected.credential === pending.credential && expected.version === pending.version;
      if (!promoted || expectedGeneration !== snapshot.generation) return false;
      snapshot = { ...snapshot, active: pending, pending: null, generation: 3 };
      return true;
    },
  };
  const h = harness({ settings });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  await settleAsyncWork();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.equal(promoted, true);
  assert.deepEqual(h.started, [pending]);
  assert.equal(h.states.filter((state) => state.phase === 'active').length, 1);
});

test('a throwing claim send fails terminally and retires its socket', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].send = () => { throw new Error('send failed'); };

  assert.doesNotThrow(() => h.sockets[0].open());
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'connection_failed' });
  assert.equal(h.sockets[0].closed.length, 1);
});

test('cancel cleanup completes even when cancellation send throws', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].send = () => { throw new Error('send failed'); };

  assert.doesNotThrow(() => h.controller.cancel());
  assert.deepEqual(h.states.at(-1), { phase: 'cancelled', reason: null });
  assert.equal(h.sockets[0].closed.length, 1);
});

test('a throwing credential acknowledgment preserves pending and fails terminally', async () => {
  const h = harness({
    crypto: { subtle: {
      importKey: async () => ({}),
      sign: async () => new Uint8Array(32).buffer,
    } },
  });
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].send = () => { throw new Error('send failed'); };
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.settings.getPending(), { credential: CREDENTIAL, version: 7 });
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'activation_failed' });
  assert.equal(h.sockets[0].closed.length, 1);
});

test('a new start during old activation cannot publish active or retire the new socket', async () => {
  const activation = deferred();
  const activationStarted = deferred();
  let activationSignal;
  const claimIds = [CLAIM_ID, '018f63f5-6f3d-7d21-88bc-9ef561f030e3'];
  const h = harness({
    idGenerator: () => claimIds.shift(),
    startTransport: (_slot, signal) => {
      activationSignal = signal;
      activationStarted.resolve();
      return activation.promise;
    },
  });
  h.controller.start(REFERENCE);
  const oldSocket = h.sockets[0];
  const ackSent = observeAck(oldSocket);
  oldSocket.open();
  acceptClaim(oldSocket);
  oldSocket.message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  oldSocket.message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await activationStarted.promise;

  h.controller.start(REFERENCE);
  const newSocket = h.sockets[1];
  assert.equal(activationSignal.aborted, true);
  activation.resolve(true);
  await settleAsyncWork();

  assert.equal(h.states.some((state) => state.phase === 'active'), false);
  assert.equal(newSocket.closed.length, 0);
  assert.deepEqual(h.states.at(-1), { phase: 'connecting', reason: null });
});

test('cancel during activation remains terminal after the old activation resolves', async () => {
  const activation = deferred();
  const h = harness({ startTransport: () => activation.promise });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await Promise.resolve();

  h.controller.cancel();
  activation.resolve(true);
  await settleAsyncWork();

  assert.deepEqual(h.states.at(-1), { phase: 'cancelled', reason: null });
  assert.equal(h.states.some((state) => state.phase === 'active'), false);
});

test('silent claimant retirement makes late frames inert without publishing an unpaired state', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  const socket = h.sockets[0];
  socket.open();
  const publishedBeforeRetirement = h.states.length;

  assert.equal(typeof h.controller.retire, 'function');
  h.controller.retire();
  socket.message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: Date.now() + 60_000,
  }));

  assert.equal(h.states.length, publishedBeforeRetirement);
  assert.equal(h.states.some(({ phase }) => phase === 'cancelled'), false);
  assert.equal(socket.closed.length, 1);
});

test('cancel aborts delayed transport startup before its external side effect', async () => {
  const activationStarted = deferred();
  const activationReleased = deferred();
  const effects = [];
  const h = harness({
    startTransport: async (slot, signal) => {
      activationStarted.resolve(signal);
      await activationReleased.promise;
      if (!signal.aborted) effects.push(slot);
      return !signal.aborted;
    },
  });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));

  const signal = await activationStarted.promise;
  h.controller.cancel();
  activationReleased.resolve();
  await settleAsyncWork();

  assert.equal(signal instanceof AbortSignal, true);
  assert.equal(signal.aborted, true);
  assert.deepEqual(effects, []);
  assert.deepEqual(h.states.at(-1), { phase: 'cancelled', reason: null });
});

test('an abort listener that cancels cannot duplicate cancellation work', async () => {
  const activationStarted = deferred();
  const activationReleased = deferred();
  let h;
  h = harness({
    startTransport: async (_slot, signal) => {
      signal.addEventListener('abort', () => h.controller.cancel());
      activationStarted.resolve();
      await activationReleased.promise;
      return false;
    },
  });
  h.controller.start(REFERENCE);
  const pairingSocket = h.sockets[0];
  const ackSent = observeAck(pairingSocket);
  pairingSocket.open();
  acceptClaim(pairingSocket);
  pairingSocket.message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  pairingSocket.message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await activationStarted.promise;

  h.controller.cancel();
  activationReleased.resolve();
  await settleAsyncWork();

  assert.equal(pairingSocket.sent.filter(({ type }) => type === 'pair.cancel.claim').length, 1);
  assert.equal(h.states.filter(({ phase }) => phase === 'cancelled').length, 1);
  assert.deepEqual(h.states.at(-1), { phase: 'cancelled', reason: null });
});

test('an abort listener that starts pairing owns the controller over the interrupted start', async () => {
  const activationStarted = deferred();
  const activationReleased = deferred();
  const interruptedReference = `${'B'.repeat(42)}A`;
  const reentrantReference = `${'C'.repeat(42)}A`;
  const claimIds = [CLAIM_ID, '018f63f5-6f3d-7d21-88bc-9ef561f030e3'];
  let h;
  h = harness({
    idGenerator: () => claimIds.shift(),
    startTransport: async (_slot, signal) => {
      signal.addEventListener('abort', () => h.controller.start(reentrantReference));
      activationStarted.resolve();
      await activationReleased.promise;
      return false;
    },
  });
  h.controller.start(REFERENCE);
  const pairingSocket = h.sockets[0];
  const ackSent = observeAck(pairingSocket);
  pairingSocket.open();
  acceptClaim(pairingSocket);
  pairingSocket.message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  pairingSocket.message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await activationStarted.promise;

  h.controller.start(interruptedReference);
  activationReleased.resolve();
  await settleAsyncWork();

  assert.equal(h.sockets.length, 2);
  const reentrantSocket = h.sockets[1];
  reentrantSocket.open();
  assert.equal(reentrantSocket.sent[0].reference, reentrantReference);
  assert.equal(h.states.at(-1).phase, 'claiming');
});

test('credential replacement aborts delayed transport startup before its external side effect', async () => {
  const activationStarted = deferred();
  const activationReleased = deferred();
  const effects = [];
  const h = harness({
    startTransport: async (slot, signal) => {
      activationStarted.resolve(signal);
      await activationReleased.promise;
      if (!signal.aborted) effects.push(slot);
      return !signal.aborted;
    },
  });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));

  const signal = await activationStarted.promise;
  h.sockets[0].serverClose(CREDENTIAL_REPLACED_CLOSE_CODE, 'credential_replaced');
  activationReleased.resolve();
  await settleAsyncWork();

  assert.equal(signal.aborted, true);
  assert.deepEqual(effects, []);
  assert.deepEqual(h.states.at(-1), { phase: 'replaced', reason: null });
});

test('a stale proof failure cannot fail a newer pairing generation', async () => {
  const signature = deferred();
  const claimIds = [CLAIM_ID, '018f63f5-6f3d-7d21-88bc-9ef561f030e3'];
  const h = harness({
    idGenerator: () => claimIds.shift(),
    crypto: { subtle: {
      importKey: async () => ({}),
      sign: () => signature.promise,
    } },
  });
  h.controller.start(REFERENCE);
  const oldSocket = h.sockets[0];
  oldSocket.open();
  acceptClaim(oldSocket);
  await settleAsyncWork();
  oldSocket.message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await settleAsyncWork();

  h.controller.start(REFERENCE);
  const newSocket = h.sockets[1];
  signature.reject(new Error('crypto failed'));
  await settleAsyncWork();

  assert.deepEqual(h.states.at(-1), { phase: 'connecting', reason: null });
  assert.equal(newSocket.closed.length, 0);
  assert.equal(h.states.some((state) => state.phase === 'failed'), false);
});

test('recovery preserves pending and reports an operational authentication exception', async () => {
  const h = harness({
    authenticateCredential: async () => { throw new Error('network unavailable'); },
  });
  await h.settings.stage(
    { credential: CREDENTIAL, version: 7 }, h.settings.getSnapshot().generation,
  );

  assert.equal(await h.controller.recover(), false);
  assert.deepEqual(h.settings.getPending(), { credential: CREDENTIAL, version: 7 });
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'authentication_failed' });
});

test('cancelling recovery aborts the credential probe and preserves pending', async () => {
  const probeStarted = deferred();
  let observedSignal;
  const h = harness({
    authenticateCredential: (_slot, signal) => {
      observedSignal = signal;
      probeStarted.resolve();
      return new Promise((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
      });
    },
  });
  const pending = { credential: CREDENTIAL, version: 7 };
  await h.settings.stage(pending, h.settings.getSnapshot().generation);

  const recovery = h.controller.recover();
  await probeStarted.promise;
  h.controller.cancel();

  assert.equal(await recovery, false);
  assert.equal(observedSignal.aborted, true);
  assert.deepEqual(h.settings.getPending(), pending);
  assert.equal(h.states.at(-1).phase, 'cancelled');
});

test('recovery leaves a newer pending slot and retries after confirmed rejection', async () => {
  const oldPending = { credential: CREDENTIAL, version: 7 };
  const newPending = { credential: REPLACEMENT, version: 7 };
  const active = { credential: 'a'.repeat(64), version: 6 };
  let snapshot = { active, pending: oldPending, generation: 1, provenance: 'authoritative' };
  let reads = 0;
  let discardCalls = 0;
  const settings = {
    getSnapshot() {
      reads += 1;
      if (reads === 2) snapshot = { ...snapshot, pending: newPending, generation: 2 };
      return snapshot;
    },
    async discardPending(expected, expectedGeneration) {
      discardCalls += 1;
      if (expectedGeneration !== snapshot.generation) return false;
      if (expected.credential !== snapshot.pending?.credential) return false;
      snapshot = { ...snapshot, pending: null, generation: snapshot.generation + 1 };
      return true;
    },
    async promotePending(expected, expectedGeneration) {
      if (expectedGeneration !== snapshot.generation
        || expected.credential !== snapshot.pending?.credential) return false;
      snapshot = { active: snapshot.pending, pending: null,
        generation: snapshot.generation + 1, provenance: 'authoritative' };
      return true;
    },
  };
  const attempts = [];
  const h = harness({
    settings,
    authenticateCredential: async (slot) => {
      attempts.push(slot.credential);
      return slot.credential === REPLACEMENT;
    },
  });

  assert.equal(await h.controller.recover(), true);
  assert.deepEqual(attempts, [CREDENTIAL, REPLACEMENT]);
  assert.equal(discardCalls, 0);
  assert.deepEqual(h.started, [newPending]);
});

test('a newer recovery owns activation after an older authentication resumes', async () => {
  const oldAuthentication = deferred();
  const oldPending = { credential: CREDENTIAL, version: 7 };
  const replacement = { credential: REPLACEMENT, version: 1 };
  const h = harness({
    authenticateCredential: async (slot) => (
      slot.credential === CREDENTIAL ? oldAuthentication.promise : true
    ),
  });
  await h.settings.stage(oldPending, h.settings.getSnapshot().generation);
  const oldRecovery = h.controller.recover();
  await h.settings.setToken(REPLACEMENT);
  await h.settings.setActive(replacement, h.settings.getSnapshot().generation);
  const newRecovery = h.controller.recover();

  assert.equal(await newRecovery, true);
  oldAuthentication.resolve(true);
  assert.equal(await oldRecovery, false);
  assert.deepEqual(h.started, [replacement]);
  assert.equal(h.states.filter((state) => state.phase === 'active').length, 1);
});

test('a newer recovery cannot be overwritten when old transport activation resumes', async () => {
  const oldActivation = deferred();
  const oldActive = { credential: 'a'.repeat(64), version: 6 };
  const replacement = { credential: REPLACEMENT, version: 1 };
  let activationCalls = 0;
  const h = harness({
    authenticateCredential: async () => true,
    startTransport: (slot) => {
      activationCalls += 1;
      if (activationCalls === 1) return oldActivation.promise;
      h.started.push(slot);
      return true;
    },
  });
  const oldRecovery = h.controller.recover();
  await settleAsyncWork();
  await h.settings.setToken(REPLACEMENT);
  await h.settings.setActive(replacement, h.settings.getSnapshot().generation);

  assert.equal(await h.controller.recover(), true);
  oldActivation.resolve(true);
  assert.equal(await oldRecovery, false);
  assert.deepEqual(h.started, [replacement]);
  assert.equal(h.states.filter((state) => state.phase === 'active').length, 1);
});

test('an illegal frame is terminal and a later valid frame cannot revive pairing', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  h.sockets[0].message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: 1000,
  }));

  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'invalid_response' });
  assert.equal(h.sockets[0].closed.length, 1);
  assert.equal(h.states.some((state) => state.phase === 'awaiting_approval'), false);
});

test('a non-pairing phone frame is rejected even when it has no current claim id', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'heartbeat.ack', v: 1, sequence: 1,
  }));

  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'invalid_response' });
  assert.equal(h.sockets[0].closed.length, 1);
});

test('a malformed frame is terminal and a later valid frame cannot revive pairing', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  h.sockets[0].message('{');
  h.sockets[0].message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: 1000,
  }));

  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'invalid_response' });
  assert.equal(h.sockets[0].closed.length, 1);
  assert.equal(h.states.some((state) => state.phase === 'awaiting_approval'), false);
});

test('a duplicate backward frame fails terminally and cannot advance again', () => {
  const h = harness();
  h.controller.start(REFERENCE);
  h.sockets[0].open();
  const claimed = JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: 1000,
  });
  h.sockets[0].message(claimed);
  h.sockets[0].message(claimed);

  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'invalid_response' });
  assert.equal(h.sockets[0].closed.length, 1);
});

test('connection, claim, and approval deadlines expire terminally without replay', () => {
  const deadlines = { connectionMs: 10, claimMs: 20, approvalMs: 30 };

  const connectionScheduler = new FakeScheduler();
  const connection = harness({ scheduler: connectionScheduler, deadlines });
  connection.controller.start(REFERENCE);
  connectionScheduler.advance(10);
  assert.deepEqual(connection.states.at(-1), { phase: 'failed', reason: 'connection_timeout' });
  assert.equal(connection.sockets[0].closed.length, 1);

  const claimScheduler = new FakeScheduler();
  const claim = harness({ scheduler: claimScheduler, deadlines });
  claim.controller.start(REFERENCE);
  claim.sockets[0].open();
  claimScheduler.advance(20);
  assert.deepEqual(claim.states.at(-1), { phase: 'failed', reason: 'claim_timeout' });
  assert.equal(claim.sockets[0].sent.length, 1);

  const approvalScheduler = new FakeScheduler();
  const approval = harness({ scheduler: approvalScheduler, deadlines, now: () => 0 });
  approval.controller.start(REFERENCE);
  approval.sockets[0].open();
  approval.sockets[0].message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: 1000,
  }));
  approvalScheduler.advance(30);
  assert.deepEqual(approval.states.at(-1), { phase: 'failed', reason: 'expired' });
  assert.equal(approval.sockets[0].sent.length, 1);
  assert.equal(approval.sockets[0].closed.length, 1);
});

test('activation remains bounded by server expiry after credential acknowledgment', async () => {
  const scheduler = new FakeScheduler();
  const h = harness({ scheduler, now: () => scheduler.now });
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  h.sockets[0].message(JSON.stringify({
    type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
    confirmationCode: '123 456', expiresAtUnixMs: 50,
  }));
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;

  assert.equal(h.states.at(-1).phase, 'activating');
  scheduler.advance(50);

  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'expired' });
  assert.equal(h.sockets[0].closed.length, 1);
  assert.equal(h.controller.claimId, null);
});

test('a synchronous reentrant start owns the only live deadline timer', () => {
  const scheduler = new FakeScheduler();
  const claimIds = [CLAIM_ID, '018f63f5-6f3d-7d21-88bc-9ef561f030e3'];
  let controller;
  let restarted = false;
  const h = harness({ scheduler, idGenerator: () => claimIds.shift() });
  controller = h.controller;
  controller.onState = (state) => {
    h.states.push(state);
    if (state.phase === 'connecting' && !restarted) {
      restarted = true;
      controller.start(REFERENCE);
    }
  };

  controller.start(REFERENCE);

  assert.equal(h.sockets.length, 2);
  assert.equal(scheduler.tasks.size, 1);
  scheduler.advance(10_000);
  assert.deepEqual(h.states.at(-1), { phase: 'failed', reason: 'connection_timeout' });
  assert.equal(h.sockets[0].closed.length, 1);
  assert.equal(h.sockets[1].closed.length, 1);
});

test('successful activation clears all pairing-only sensitive state', async () => {
  const h = harness();
  h.controller.start(REFERENCE);
  const ackSent = observeAck(h.sockets[0]);
  h.sockets[0].open();
  acceptClaim(h.sockets[0]);
  h.sockets[0].message(JSON.stringify({
    type: 'pair.credential', v: 1, claimId: CLAIM_ID,
    credential: CREDENTIAL, credentialVersion: 7,
  }));
  await ackSent;
  h.sockets[0].message(JSON.stringify({
    type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 7,
  }));
  await settleAsyncWork();

  assert.deepEqual(h.states.at(-1), { phase: 'active', reason: null });
  assert.equal(h.controller.reference, null);
  assert.equal(h.controller.claimId, null);
  assert.equal(h.controller.acknowledgedSlot, null);
  assert.equal(h.controller.pairingExpiresAtUnixMs, null);
  assert.equal(h.controller.deadlineTimer, null);
  assert.equal(h.controller.activation, null);
  assert.equal(h.controller.socket, null);
});
