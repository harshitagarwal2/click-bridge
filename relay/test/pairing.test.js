import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';

import { AUTH_STORE_ERROR_CODES, AuthStoreError } from '../src/auth-store.js';
import { PairingCoordinator } from '../src/pairing.js';

const MAC = Object.freeze({ id: 'mac' });
const PHONE = Object.freeze({ id: 'claimant' });
const OLD_PHONE = Object.freeze({ id: 'old-phone' });
const REPLACEMENT_PHONE = Object.freeze({ id: 'replacement-phone' });
const NEW_ACTIVE_PHONE = Object.freeze({ id: 'new-active-phone' });
const REQUEST_ID = '11111111-1111-4111-8111-111111111111';
const CLAIM_ID = '22222222-2222-4222-8222-222222222222';
const SESSION_NONCE = '33'.repeat(32);
const INITIAL_VERIFIER = '44'.repeat(32);
const INVITATION_BYTES = Buffer.alloc(32, 0x51);
const CREDENTIAL_BYTES = Buffer.alloc(32, 0xa7);
const INVITATION = INVITATION_BYTES.toString('base64url');
const CREDENTIAL = CREDENTIAL_BYTES.toString('hex');

function createScheduler(clock) {
  let nextId = 1;
  const timers = new Map();
  return {
    setTimeout(callback, delay) {
      const id = nextId++;
      timers.set(id, { callback, at: clock.value + delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    advance(milliseconds) {
      clock.value += milliseconds;
      for (;;) {
        const due = [...timers.entries()]
          .filter(([, timer]) => timer.at <= clock.value)
          .sort((left, right) => left[1].at - right[1].at || left[0] - right[0]);
        if (due.length === 0) break;
        const [id, timer] = due[0];
        timers.delete(id);
        timer.callback();
      }
    },
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function harness({
  enabled = true,
  emitResult = true,
  activationGate = null,
  closeError = null,
  deauthorizationFailure = null,
  activePhoneCredentialVersion = 7,
} = {}) {
  const clock = { value: 1_700_000_000_000 };
  const scheduler = createScheduler(clock);
  const events = [];
  const closes = [];
  const logs = [];
  const randomBuffers = [INVITATION_BYTES, CREDENTIAL_BYTES];
  const randomIntCalls = [];
  let record = Object.freeze({
    schemaVersion: 1,
    activePhoneCredentialVersion,
    activePhoneVerifier: INITIAL_VERIFIER,
  });
  let activateCalls = 0;
  let activationError = null;
  let deauthorizationResult = deauthorizationFailure;
  let authenticatedPhones = [{ connection: OLD_PHONE, generation: 4, credentialVersion: 7 }];
  const authStore = {
    snapshot: () => record,
    async activate({ expectedVersion, credentialVersion, verifier }) {
      activateCalls += 1;
      if (activationGate) await activationGate.promise;
      if (activationError) throw activationError;
      if (expectedVersion !== record.activePhoneCredentialVersion) throw new Error('version conflict');
      record = Object.freeze({
        schemaVersion: 1,
        activePhoneCredentialVersion: credentialVersion,
        activePhoneVerifier: verifier,
      });
      return record;
    },
  };
  const coordinator = new PairingCoordinator({
    enabled,
    now: () => clock.value,
    randomBytes: (size) => {
      assert.equal(size, 32);
      const value = randomBuffers.shift();
      assert.ok(value, 'unexpected randomBytes call');
      return Buffer.from(value);
    },
    randomInt: (maximum) => {
      randomIntCalls.push(maximum);
      return 42;
    },
    scheduler,
    authStore,
    emit: (connection, message) => {
      events.push({ connection, message: structuredClone(message) });
      return typeof emitResult === 'function' ? emitResult(connection, message) : emitResult;
    },
    close: (connection, code, reason) => {
      closes.push({ connection, code, reason });
      if (closeError) throw closeError;
    },
    deauthorizeOlderPhones: ({ credentialVersion, exclude }) => {
      if (deauthorizationResult instanceof Error) throw deauthorizationResult;
      if (deauthorizationResult !== null) return deauthorizationResult;
      const revoked = authenticatedPhones.filter((phone) => phone.credentialVersion < credentialVersion
        && !(phone.connection === exclude.connection && phone.generation === exclude.generation));
      authenticatedPhones = authenticatedPhones.filter((phone) => !revoked.includes(phone));
      return revoked.map((phone) => ({ ...phone }));
    },
    log: (...args) => logs.push(args),
  });
  return {
    coordinator, clock, scheduler, events, closes, logs, randomBuffers, randomIntCalls, authStore,
    record: () => record,
    activateCalls: () => activateCalls,
    failActivation(error = new Error('disk failed')) { activationError = error; },
    setAuthenticatedPhones(phones) { authenticatedPhones = phones; },
    setDeauthorizationResult(result) { deauthorizationResult = result; },
    phoneCanAct(connection, generation) {
      const phone = authenticatedPhones.find((candidate) => candidate.connection === connection
        && candidate.generation === generation);
      return Boolean(phone && coordinator.allowsPhoneCredentialVersion(phone.credentialVersion));
    },
  };
}

function createMessage(requestId = REQUEST_ID) {
  return { type: 'pair.create', v: 1, requestId, pairingVersion: 1 };
}

function statusMessage(requestId = REQUEST_ID) {
  return { type: 'pair.status.request', v: 1, requestId, pairingVersion: 1 };
}

function connectMac(h, connection = MAC, generation = 3) {
  assert.equal(h.coordinator.macConnected(connection, generation), 'ok');
  assert.equal(h.events.length, 0, 'authentication alone must emit no pairing frame');
  assert.equal(h.coordinator.requestStatus(
    connection, generation, statusMessage(),
  ), 'ok');
}

function claimMessage(reference = INVITATION) {
  return {
    type: 'pair.claim', v: 1, reference, claimId: CLAIM_ID,
    sessionNonce: SESSION_NONCE, pairingVersion: 1, clientKind: 'ios',
  };
}

function connectAndCreate(h) {
  connectMac(h);
  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'ok');
  return h.events.at(-1).message;
}

function claim(h) {
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage()), 'ok');
}

function approve(h) {
  return h.coordinator.approve(MAC, 3, {
    type: 'pair.approve', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
  });
}

function activationProof() {
  return createHmac('sha256', CREDENTIAL_BYTES)
    .update(`clickbridge-pair-activate:v1:${CLAIM_ID}:8`, 'utf8')
    .digest('hex');
}

function acknowledge(h, overrides = {}) {
  return h.coordinator.acknowledge(PHONE, 5, {
    type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID,
    credentialVersion: 8, proof: activationProof(), ...overrides,
  });
}

test('pairing status is request-correlated and explicitly opts in one Mac generation', () => {
  const h = harness();
  const replacement = Object.freeze({ id: 'replacement-mac' });

  assert.equal(h.coordinator.macConnected(MAC, 3), 'ok');
  assert.equal(h.events.length, 0);
  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'capability_required');
  assert.equal(h.coordinator.requestStatus(MAC, 2, statusMessage()), 'ignored');
  assert.equal(h.coordinator.requestStatus(MAC, 3, statusMessage()), 'ok');
  assert.deepEqual(h.events, [{
    connection: MAC,
    message: {
      type: 'pair.status', v: 1, requestId: REQUEST_ID,
      enrollmentState: 'paired', activePhoneCredentialVersion: 7,
    },
  }]);
  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'ok');

  assert.equal(h.coordinator.macConnected(replacement, 4), 'ok');
  assert.equal(h.coordinator.create(replacement, 4, createMessage(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  )), 'capability_required');
  assert.equal(h.events.some(({ connection, message }) => (
    connection === replacement && message.type.startsWith('pair.')
  )), false);
});

test('legacy credential version zero is reported as existing enrollment', () => {
  const h = harness({ activePhoneCredentialVersion: 0 });
  assert.equal(h.coordinator.macConnected(MAC, 3), 'ok');

  assert.equal(h.coordinator.requestStatus(MAC, 3, statusMessage()), 'ok');

  assert.deepEqual(h.events.at(-1), {
    connection: MAC,
    message: {
      type: 'pair.status', v: 1, requestId: REQUEST_ID,
      enrollmentState: 'legacy', activePhoneCredentialVersion: 0,
    },
  });
});

test('create emits a 32-byte invitation synchronously, then retains only its verifier for 300 seconds', () => {
  const h = harness({
    emitResult: (_connection, message) => {
      if (message.type === 'pair.created') {
        assert.equal(JSON.stringify(h.coordinator).includes(message.reference), false);
      }
      return true;
    },
  });
  connectMac(h);

  const result = h.coordinator.create(MAC, 3, createMessage());

  assert.equal(result, 'ok');
  assert.deepEqual(h.events[1], {
    connection: MAC,
    message: {
      type: 'pair.created', v: 1, requestId: REQUEST_ID,
      reference: INVITATION, expiresAtUnixMs: h.clock.value + 300_000,
    },
  });
  assert.equal(JSON.stringify(h.coordinator).includes(INVITATION), false);
  assert.equal(INVITATION.length, 43);
  h.scheduler.advance(299_999);
  assert.equal(h.events.some(({ message }) => message.reason === 'expired'), false);
  h.scheduler.advance(1);
  assert.deepEqual(h.events.at(-1), {
    connection: MAC,
    message: { type: 'pair.failed', v: 1, requestId: REQUEST_ID, reason: 'expired' },
  });
});

test('only the current authenticated Mac generation owns create and replacing an invite invalidates it once', () => {
  const h = harness();
  h.randomBuffers.push(Buffer.alloc(32, 0x61));
  assert.equal(h.coordinator.macConnected(MAC, 3), 'ok');
  assert.equal(h.coordinator.create(MAC, 2, createMessage()), 'ignored');
  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'capability_required');
  assert.equal(h.events.length, 0);
  assert.equal(h.coordinator.requestStatus(MAC, 3, statusMessage()), 'ok');

  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'ok');
  assert.equal(h.events.filter(({ message }) => message.type === 'pair.created').length, 1);

  const replacementId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  assert.equal(h.coordinator.create(MAC, 3, createMessage(replacementId)), 'ok');
  assert.equal(h.events.filter(({ message }) => message.reason === 'replaced').length, 1);
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage(INVITATION)), 'used');
});

test('one exact connection generation and session owns a claim with a uniform formatted SAS', () => {
  const h = harness();
  connectAndCreate(h);

  claim(h);

  assert.deepEqual(h.randomIntCalls, [1_000_000]);
  assert.deepEqual(h.events.slice(-2), [
    {
      connection: PHONE,
      message: {
        type: 'pair.claimed.phone', v: 1, claimId: CLAIM_ID,
        confirmationCode: '000 042', expiresAtUnixMs: h.clock.value + 300_000,
      },
    },
    {
      connection: MAC,
      message: {
        type: 'pair.claimed.mac', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
        confirmationCode: '000 042', expiresAtUnixMs: h.clock.value + 300_000,
        clientKind: 'ios',
      },
    },
  ]);
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage()), 'ok');
  assert.equal(h.randomIntCalls.length, 1);
  assert.equal(h.coordinator.claim({ id: 'attacker' }, 5, claimMessage()), 'used');
  assert.equal(h.coordinator.claim(PHONE, 6, claimMessage()), 'used');
  assert.equal(h.coordinator.claim(PHONE, 5, { ...claimMessage(), sessionNonce: '55'.repeat(32) }), 'used');
});

test('a non-canonical base64url alias cannot redeem a canonical invitation', () => {
  const h = harness();
  connectAndCreate(h);
  const alias = `${INVITATION.slice(0, -1)}F`;
  assert.deepEqual(Buffer.from(alias, 'base64url'), Buffer.from(INVITATION, 'base64url'));

  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage(alias)), 'used');
  assert.equal(h.randomIntCalls.length, 0);
  assert.equal(h.coordinator.observe().claimId, null);
});

test('approval is claim-bound CAS and offers a next-version credential without activating it', () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);

  assert.equal(h.coordinator.approve(MAC, 2, {
    type: 'pair.approve', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
  }), 'ignored');
  assert.equal(h.coordinator.approve(MAC, 3, {
    type: 'pair.approve', v: 1, requestId: REQUEST_ID,
    claimId: '99999999-9999-4999-8999-999999999999',
  }), 'invalid_request');
  assert.equal(approve(h), 'ok');

  assert.deepEqual(h.events.at(-1), {
    connection: PHONE,
    message: {
      type: 'pair.credential', v: 1, claimId: CLAIM_ID,
      credential: CREDENTIAL, credentialVersion: 8,
    },
  });
  assert.equal(h.activateCalls(), 0);
  assert.equal(h.record().activePhoneCredentialVersion, 7);
  assert.equal(h.closes.length, 0);
  assert.equal(approve(h), 'ok');
  assert.equal(h.activateCalls(), 0);
  assert.equal(h.events.at(-1).message.credential, CREDENTIAL);
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage()), 'ok');
  assert.equal(h.events.at(-1).message.credential, CREDENTIAL);
});

test('exact credential-bound proof activates with CAS, clears secrets, then closes the old phone with 4004', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'ok');

  assert.equal(h.activateCalls(), 1);
  assert.deepEqual(h.record(), {
    schemaVersion: 1,
    activePhoneCredentialVersion: 8,
    activePhoneVerifier: createHash('sha256').update(CREDENTIAL_BYTES).digest('hex'),
  });
  assert.deepEqual(h.events.slice(-2), [
    {
      connection: PHONE,
      message: { type: 'pair.active', v: 1, claimId: CLAIM_ID, activePhoneCredentialVersion: 8 },
    },
    {
      connection: MAC,
      message: {
        type: 'pair.completed', v: 1, requestId: REQUEST_ID,
        claimId: CLAIM_ID, activePhoneCredentialVersion: 8,
      },
    },
  ]);
  assert.deepEqual(h.closes, [{ connection: OLD_PHONE, code: 4004, reason: 'credential_replaced' }]);
  assert.equal(JSON.stringify(h.coordinator).includes(CREDENTIAL), false);
  assert.equal(JSON.stringify(h.coordinator).includes(activationProof()), false);
});

test('wrong proof, stale claimant generation, and wrong version never activate or close the old phone', async () => {
  for (const [generation, overrides] of [
    [6, {}],
    [5, { credentialVersion: 9 }],
    [5, { proof: '00'.repeat(32) }],
  ]) {
    const h = harness();
    connectAndCreate(h);
    claim(h);
    approve(h);
    const result = await h.coordinator.acknowledge(PHONE, generation, {
      type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID,
      credentialVersion: 8, proof: activationProof(), ...overrides,
    }, OLD_PHONE);
    assert.notEqual(result, 'ok');
    assert.equal(h.activateCalls(), 0);
    assert.equal(h.record().activePhoneCredentialVersion, 7);
    assert.equal(h.closes.length, 0);
  }
});

test('concurrent and duplicate acknowledgements activate once and recover lost final confirmation', async () => {
  let dropFinal = true;
  const h = harness({
    emitResult: (_connection, message) => {
      if (dropFinal && (message.type === 'pair.active' || message.type === 'pair.completed')) return false;
      return true;
    },
  });
  connectAndCreate(h);
  claim(h);
  approve(h);

  const first = acknowledge(h);
  const duplicate = acknowledge(h);
  assert.deepEqual(await Promise.all([first, duplicate]), ['ok', 'ok']);
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.closes.length, 1);

  dropFinal = false;
  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.closes.length, 1);
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.type), ['pair.active', 'pair.completed']);
});

test('storage failure preserves the old credential and emits no secret-bearing terminal message', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  h.failActivation();

  assert.equal(await acknowledge(h), 'storage_failed');

  assert.equal(h.record().activePhoneCredentialVersion, 7);
  assert.equal(h.closes.length, 0);
  assert.equal(h.events.some(({ message }) => message.type === 'pair.active'), false);
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message), [
    { type: 'pair.failed', v: 1, claimId: CLAIM_ID, reason: 'storage_failed' },
    { type: 'pair.failed', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID, reason: 'storage_failed' },
  ]);
  assert.equal(JSON.stringify(h.coordinator).includes(CREDENTIAL), false);
});

test('activation CAS conflict is distinct from storage failure and preserves the old credential', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  h.failActivation(new AuthStoreError(
    AUTH_STORE_ERROR_CODES.VERSION_CONFLICT,
    'wording intentionally unrelated to versions',
  ));

  assert.equal(await acknowledge(h), 'activation_failed');
  assert.equal(h.record().activePhoneCredentialVersion, 7);
  assert.equal(h.closes.length, 0);
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.reason), [
    'activation_failed', 'activation_failed',
  ]);
});

test('generic storage errors are never promoted to activation conflicts by message wording', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  h.failActivation(new Error('version conflict next version'));

  assert.equal(await acknowledge(h), 'storage_failed');
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.reason), [
    'storage_failed', 'storage_failed',
  ]);
});

test('a forged auth-store error code without the typed error class remains a storage failure', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  h.failActivation(Object.assign(new Error('forged typed code'), {
    code: AUTH_STORE_ERROR_CODES.VERSION_CONFLICT,
  }));

  assert.equal(await acknowledge(h), 'storage_failed');
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.reason), [
    'storage_failed', 'storage_failed',
  ]);
});

test('an emit callback with no explicit return value counts as successful delivery', () => {
  const h = harness({ emitResult: () => undefined });
  connectMac(h);

  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'ok');
  assert.equal(h.coordinator.observe().phase, 'invited');
});

test('failed invitation delivery retains no session and a retry creates a fresh reference', () => {
  let failFirstInvitation = true;
  const h = harness({
    emitResult: (_connection, message) => {
      if (message.type === 'pair.created' && failFirstInvitation) {
        failFirstInvitation = false;
        return false;
      }
      return true;
    },
  });
  h.randomBuffers.push(Buffer.alloc(32, 0x61));
  connectMac(h);

  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'delivery_failed');
  assert.deepEqual(h.coordinator.observe(), {
    phase: 'idle', requestId: null, claimId: null, expiresAtUnixMs: null,
    hasInvitationVerifier: false, hasPendingCredential: false,
  });
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage(INVITATION)), 'used');

  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'ok');
  const created = h.events.filter(({ message }) => message.type === 'pair.created');
  assert.equal(created.length, 2);
  assert.notEqual(created[1].message.reference, created[0].message.reference);
});

test('absolute invitation deadline rejects duplicate claim and acknowledgement paths', async () => {
  const duplicateClaim = harness();
  connectAndCreate(duplicateClaim);
  claim(duplicateClaim);
  duplicateClaim.clock.value += 300_000;
  assert.equal(duplicateClaim.coordinator.claim(PHONE, 5, claimMessage()), 'expired');
  assert.equal(duplicateClaim.activateCalls(), 0);

  const expiredAck = harness();
  connectAndCreate(expiredAck);
  claim(expiredAck);
  approve(expiredAck);
  expiredAck.clock.value += 300_000;
  assert.equal(await acknowledge(expiredAck), 'expired');
  assert.equal(expiredAck.activateCalls(), 0);
  assert.equal(expiredAck.record().activePhoneCredentialVersion, 7);
});

test('activation linearizes before terminal races and cannot be replaced mid-commit', async () => {
  const actions = [
    (h) => h.coordinator.cancelByMac(MAC, 3, {
      type: 'pair.cancel', v: 1, requestId: REQUEST_ID,
    }),
    (h) => h.coordinator.cancelByClaimant(PHONE, 5, {
      type: 'pair.cancel.claim', v: 1, claimId: CLAIM_ID,
    }),
    (h) => h.coordinator.disconnectClaimant(PHONE, 5),
    (h) => h.coordinator.macDisconnected(MAC, 3),
    (h) => h.coordinator.macConnected(Object.freeze({ id: 'replacement-mac' }), 4),
    (h) => h.coordinator.create(MAC, 3, createMessage(
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    )),
  ];

  for (const action of actions) {
    const activationGate = deferred();
    const h = harness({ activationGate });
    connectAndCreate(h);
    claim(h);
    approve(h);
    const activation = acknowledge(h);
    assert.equal(h.activateCalls(), 1);
    assert.equal(action(h), 'activation_in_progress');
    h.scheduler.advance(300_000);
    activationGate.resolve();
    assert.equal(await activation, 'ok');
    assert.equal(h.record().activePhoneCredentialVersion, 8);
    assert.equal(h.events.some(({ message }) => [
      'cancelled', 'expired', 'mac_offline', 'replaced',
    ].includes(message.reason)), false);
  }
});

test('a replacement Mac must opt in before receiving durable pairing completion', async () => {
  const activationGate = deferred();
  const h = harness({ activationGate });
  const replacementMac = Object.freeze({ id: 'replacement-mac' });
  connectAndCreate(h);
  claim(h);
  approve(h);

  const activation = acknowledge(h);
  assert.equal(h.coordinator.macConnected(replacementMac, 4), 'activation_in_progress');
  assert.equal(h.coordinator.requestStatus(
    replacementMac, 4, statusMessage('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ), 'ok');
  activationGate.resolve();
  assert.equal(await activation, 'ok');

  const completed = h.events.filter(({ message }) => message.type === 'pair.completed');
  assert.equal(completed.length, 1);
  assert.equal(completed[0].connection, replacementMac);
  assert.equal(completed[0].message.activePhoneCredentialVersion, 8);
});

test('activation revokes the current old generation after persistence and excludes the new one', async () => {
  const activationGate = deferred();
  const h = harness({ activationGate });
  connectAndCreate(h);
  claim(h);
  approve(h);

  const activation = acknowledge(h);
  h.setAuthenticatedPhones([
    { connection: REPLACEMENT_PHONE, generation: 9, credentialVersion: 7 },
    { connection: NEW_ACTIVE_PHONE, generation: 10, credentialVersion: 8 },
  ]);
  activationGate.resolve();
  assert.equal(await activation, 'ok');

  assert.deepEqual(h.closes, [{
    connection: REPLACEMENT_PHONE, code: 4004, reason: 'credential_replaced',
  }]);
  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.closes.length, 1);
});

test('logical phone authorization is revoked before best-effort websocket close', async () => {
  const h = harness({ closeError: new Error('socket close failed') });
  connectAndCreate(h);
  claim(h);
  approve(h);
  assert.equal(h.phoneCanAct(OLD_PHONE, 4), true);

  assert.equal(await acknowledge(h), 'ok');

  assert.equal(h.phoneCanAct(OLD_PHONE, 4), false);
  assert.deepEqual(h.closes, [{
    connection: OLD_PHONE, code: 4004, reason: 'credential_replaced',
  }]);
  assert.equal(h.logs.some(([name]) => name === 'pairing_phone_revocation_failed'), true);
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.type), [
    'pair.active', 'pair.completed',
  ]);
});

test('durable activation remains unreconciled until logical deauthorization succeeds', async () => {
  const h = harness({ deauthorizationFailure: new Error('relay state unavailable') });
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'reconciliation_failed');
  assert.equal(h.record().activePhoneCredentialVersion, 8);
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.phoneCanAct(OLD_PHONE, 4), false);
  assert.equal(h.events.some(({ message }) => [
    'pair.active', 'pair.completed',
  ].includes(message.type)), false);
  assert.equal(h.coordinator.observe().phase, 'committed');

  h.randomBuffers.push(Buffer.alloc(32, 0x61));
  const createdBeforeRetry = h.events.filter(({ message }) => message.type === 'pair.created').length;
  assert.equal(h.coordinator.create(
    MAC, 3, createMessage('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ), 'activation_in_progress');
  assert.equal(h.randomBuffers.length, 1);
  assert.equal(
    h.events.filter(({ message }) => message.type === 'pair.created').length,
    createdBeforeRetry,
  );
  assert.equal(h.coordinator.observe().phase, 'committed');

  h.setDeauthorizationResult(null);
  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.coordinator.observe().phase, 'completed');
  assert.deepEqual(h.events.slice(-2).map(({ message }) => message.type), [
    'pair.active', 'pair.completed',
  ]);
});

test('deauthorization captures own data descriptors once before any close', async () => {
  const descriptorReads = new Map();
  const values = {
    connection: OLD_PHONE,
    generation: 4,
    credentialVersion: 7,
  };
  const phone = new Proxy({}, {
    get() {
      throw new Error('ordinary property reads are forbidden');
    },
    getOwnPropertyDescriptor(_target, property) {
      descriptorReads.set(property, (descriptorReads.get(property) ?? 0) + 1);
      if (!Object.hasOwn(values, property)) return undefined;
      return {
        configurable: true,
        enumerable: true,
        writable: true,
        value: values[property],
      };
    },
  });
  const h = harness({ deauthorizationFailure: [phone] });
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'ok');
  assert.deepEqual(h.closes, [{
    connection: OLD_PHONE, code: 4004, reason: 'credential_replaced',
  }]);
  assert.deepEqual(Object.fromEntries(descriptorReads), {
    connection: 1, generation: 1, credentialVersion: 1,
  });
});

test('accessor, inherited, claimant, and current phone entries fail closed before any close', async () => {
  let getterCalls = 0;
  const accessor = {};
  Object.defineProperty(accessor, 'connection', {
    configurable: true,
    get() {
      getterCalls += 1;
      return OLD_PHONE;
    },
  });
  Object.defineProperties(accessor, {
    generation: { configurable: true, value: 4 },
    credentialVersion: { configurable: true, value: 7 },
  });
  const inherited = Object.create({
    connection: OLD_PHONE, generation: 4, credentialVersion: 7,
  });
  const invalidLists = [
    Array(1),
    [accessor],
    [inherited],
    [{ connection: PHONE, generation: 5, credentialVersion: 7 }],
    [{ connection: NEW_ACTIVE_PHONE, generation: 10, credentialVersion: 8 }],
    [
      { connection: OLD_PHONE, generation: 4, credentialVersion: 7 },
      accessor,
    ],
  ];
  for (const phones of invalidLists) {
    const h = harness({ deauthorizationFailure: phones });
    connectAndCreate(h);
    claim(h);
    approve(h);
    assert.equal(await acknowledge(h), 'reconciliation_failed');
    assert.equal(h.closes.length, 0);
  }
  assert.equal(getterCalls, 0);
});

test('primitive connections invalidate the complete deauthorization result before any close', async () => {
  for (const connection of ['old-phone', 42, Symbol('old-phone')]) {
    const h = harness({
      deauthorizationFailure: [
        { connection: OLD_PHONE, generation: 4, credentialVersion: 7 },
        { connection, generation: 5, credentialVersion: 7 },
      ],
    });
    connectAndCreate(h);
    claim(h);
    approve(h);

    assert.equal(await acknowledge(h), 'reconciliation_failed');
    assert.equal(h.closes.length, 0);
    assert.equal(h.events.some(({ message }) => [
      'pair.active', 'pair.completed',
    ].includes(message.type)), false);
  }
});

test('claimant connection is never closed through a mismatched generation snapshot', async () => {
  const h = harness({
    deauthorizationFailure: [
      { connection: OLD_PHONE, generation: 4, credentialVersion: 7 },
      { connection: PHONE, generation: 999, credentialVersion: 7 },
    ],
  });
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'reconciliation_failed');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.closes.length, 0);
  assert.equal(h.events.some(({ message }) => [
    'pair.active', 'pair.completed',
  ].includes(message.type)), false);

  h.setDeauthorizationResult(null);
  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.coordinator.observe().phase, 'completed');
});

test('hostile deauthorization containers fail closed and remain retryable', async () => {
  const hostile = new Proxy([], {
    get(target, property, receiver) {
      if (property === Symbol.iterator) throw new Error('iterator unavailable');
      return Reflect.get(target, property, receiver);
    },
  });
  const h = harness({ deauthorizationFailure: hostile });
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'reconciliation_failed');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.closes.length, 0);
  assert.equal(h.events.some(({ message }) => [
    'pair.active', 'pair.completed',
  ].includes(message.type)), false);

  h.setDeauthorizationResult(null);
  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.activateCalls(), 1);
  assert.equal(h.coordinator.observe().phase, 'completed');
});

test('malformed deauthorization results cannot publish activation success', async () => {
  for (const malformed of [
    { not: 'an array' },
    [
      { connection: OLD_PHONE, generation: 4, credentialVersion: 7 },
      { connection: REPLACEMENT_PHONE, generation: 'wrong', credentialVersion: 7 },
    ],
  ]) {
    const h = harness({ deauthorizationFailure: malformed });
    connectAndCreate(h);
    claim(h);
    approve(h);

    assert.equal(await acknowledge(h), 'reconciliation_failed');
    assert.equal(h.record().activePhoneCredentialVersion, 8);
    assert.equal(h.phoneCanAct(OLD_PHONE, 4), false);
    assert.equal(h.closes.length, 0);
    assert.equal(h.events.some(({ message }) => [
      'pair.active', 'pair.completed',
    ].includes(message.type)), false);
  }
});

test('activation completion is never sent to a disconnected historical Mac generation', async () => {
  const scenarios = [
    (h) => h.coordinator.macDisconnected(MAC, 3),
    (h) => {
      const replacement = Object.freeze({ id: 'replacement-then-disconnected' });
      assert.equal(h.coordinator.macConnected(replacement, 4), 'activation_in_progress');
      return h.coordinator.macDisconnected(replacement, 4);
    },
  ];
  for (const disconnect of scenarios) {
    const activationGate = deferred();
    const h = harness({ activationGate });
    connectAndCreate(h);
    claim(h);
    approve(h);
    const activation = acknowledge(h);
    assert.equal(disconnect(h), 'activation_in_progress');
    activationGate.resolve();
    assert.equal(await activation, 'ok');
    assert.equal(h.events.filter(({ message }) => message.type === 'pair.completed').length, 0);
    assert.equal(h.events.filter(({ message }) => message.type === 'pair.active').length, 1);
  }
});

test('terminal output failures cannot skip durable completion or old-generation revocation', async () => {
  const h = harness({
    emitResult: (_connection, message) => {
      if (message.type === 'pair.active') {
        assert.equal(h.coordinator.observe().hasPendingCredential, false);
        throw new Error('socket closed during terminal output');
      }
      if (message.type === 'pair.completed') return false;
      return true;
    },
  });
  connectAndCreate(h);
  claim(h);
  approve(h);

  assert.equal(await acknowledge(h), 'ok');
  assert.equal(h.record().activePhoneCredentialVersion, 8);
  assert.deepEqual(h.closes, [{
    connection: OLD_PHONE, code: 4004, reason: 'credential_replaced',
  }]);
  assert.deepEqual(h.coordinator.observe(), {
    phase: 'completed', requestId: REQUEST_ID, claimId: CLAIM_ID,
    expiresAtUnixMs: null, hasInvitationVerifier: false, hasPendingCredential: false,
  });
  assert.equal(h.logs.some(([name]) => name === 'pairing_emit_failed'), true);
});

test('deny and either owner cancellation are terminal, idempotent, and preserve the active credential', () => {
  for (const action of ['deny', 'cancelByMac', 'cancelByClaimant']) {
    const h = harness();
    connectAndCreate(h);
    claim(h);
    let result;
    if (action === 'deny') {
      result = h.coordinator.deny(MAC, 3, {
        type: 'pair.deny', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
      });
    } else if (action === 'cancelByMac') {
      result = h.coordinator.cancelByMac(MAC, 3, {
        type: 'pair.cancel', v: 1, requestId: REQUEST_ID,
      });
    } else {
      result = h.coordinator.cancelByClaimant(PHONE, 5, {
        type: 'pair.cancel.claim', v: 1, claimId: CLAIM_ID,
      });
    }
    assert.equal(result, 'ok');
    const reason = action === 'deny' ? 'denied' : 'cancelled';
    assert.deepEqual(h.events.slice(-2).map(({ message }) => message.reason), [reason, reason]);
    assert.equal(h.record().activePhoneCredentialVersion, 7);
    assert.equal(h.closes.length, 0);
    const count = h.events.length;
    if (action === 'cancelByClaimant') {
      assert.equal(h.coordinator.cancelByClaimant(PHONE, 5, {
        type: 'pair.cancel.claim', v: 1, claimId: CLAIM_ID,
      }), 'ok');
    } else if (action === 'cancelByMac') {
      assert.equal(h.coordinator.cancelByMac(
        MAC, 3, { type: 'pair.cancel', v: 1, requestId: REQUEST_ID },
      ), 'ok');
    } else {
      assert.equal(h.coordinator.deny(MAC, 3, {
        type: 'pair.deny', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
      }), 'ok');
    }
    assert.equal(h.events.length, count);
  }
});

test('expiry, claimant disconnect, Mac disconnect, and relay restart abort pending pairing only', () => {
  const scenarios = [
    (h) => h.scheduler.advance(300_000),
    (h) => h.coordinator.disconnectClaimant(PHONE, 5),
    (h) => h.coordinator.macDisconnected(MAC, 3),
  ];
  for (const finish of scenarios) {
    const h = harness();
    connectAndCreate(h);
    claim(h);
    finish(h);
    assert.equal(h.record().activePhoneCredentialVersion, 7);
    assert.equal(h.closes.length, 0);
    assert.equal(h.events.at(-1).message.reason === 'expired'
      || h.events.at(-1).message.reason === 'cancelled'
      || h.events.at(-1).message.reason === 'mac_offline', true);
  }

  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  const restarted = harness();
  assert.equal(restarted.record().activePhoneCredentialVersion, 7);
  assert.equal(restarted.closes.length, 0);
});

test('credential versions remain monotonic across sequential activations', async () => {
  const h = harness();
  connectAndCreate(h);
  claim(h);
  approve(h);
  await acknowledge(h);
  assert.equal(h.record().activePhoneCredentialVersion, 8);

  h.randomBuffers.push(Buffer.alloc(32, 0x62), Buffer.alloc(32, 0xb8));
  const requestId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const claimId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  h.coordinator.create(MAC, 3, createMessage(requestId));
  const reference = h.events.at(-1).message.reference;
  h.coordinator.claim(PHONE, 6, {
    ...claimMessage(reference), claimId, sessionNonce: '66'.repeat(32), clientKind: 'pwa',
  });
  h.coordinator.approve(MAC, 3, {
    type: 'pair.approve', v: 1, requestId, claimId,
  });
  const credential = h.events.at(-1).message.credential;
  const proof = createHmac('sha256', Buffer.from(credential, 'hex'))
    .update(`clickbridge-pair-activate:v1:${claimId}:9`, 'utf8')
    .digest('hex');
  await h.coordinator.acknowledge(PHONE, 6, {
    type: 'pair.credential.ack', v: 1, claimId, credentialVersion: 9, proof,
  }, OLD_PHONE);
  assert.equal(h.record().activePhoneCredentialVersion, 9);
});

test('pairing-disabled public calls return unsupported without consuming randomness or auth state', async () => {
  const h = harness({ enabled: false });
  assert.equal(h.coordinator.allowsPhoneCredentialVersion(7), true);
  assert.equal(h.coordinator.allowsPhoneCredentialVersion(6), false);
  h.coordinator.macConnected(MAC, 3);
  assert.equal(h.coordinator.requestStatus(MAC, 3, statusMessage()), 'unsupported');
  assert.equal(h.coordinator.create(MAC, 3, createMessage()), 'unsupported');
  assert.equal(h.coordinator.claim(PHONE, 5, claimMessage()), 'unsupported');
  assert.equal(h.coordinator.approve(MAC, 3, {
    type: 'pair.approve', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
  }), 'unsupported');
  assert.equal(h.coordinator.deny(MAC, 3, {
    type: 'pair.deny', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID,
  }), 'unsupported');
  assert.equal(h.coordinator.cancelByMac(MAC, 3, {
    type: 'pair.cancel', v: 1, requestId: REQUEST_ID,
  }), 'unsupported');
  assert.equal(h.coordinator.cancelByClaimant(PHONE, 5, {
    type: 'pair.cancel.claim', v: 1, claimId: CLAIM_ID,
  }), 'unsupported');
  assert.equal(await h.coordinator.acknowledge(PHONE, 5, {
    type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID,
    credentialVersion: 8, proof: '00'.repeat(32),
  }), 'unsupported');
  assert.equal(h.coordinator.disconnectClaimant(PHONE, 5), 'unsupported');
  assert.equal(h.record().activePhoneCredentialVersion, 7);
  assert.equal(h.randomBuffers.length, 2);
});
