import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, chmod, writeFile, readdir } from 'node:fs/promises';
import * as realFs from 'node:fs/promises';
import * as realCrypto from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  AUTH_STORE_ERROR_CODES,
  AuthStoreError,
  createPhoneAuthStore,
} from '../src/auth-store.js';

const TOKEN_A = '01'.repeat(32);
const TOKEN_B = '23'.repeat(32);
const VERIFIER_A = '72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793';
const VERIFIER_B = '5b19d45be03b87bdee0a7323ec312e8a11c89e91210d0cbe041e183ec111840f';
const DEVICE_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

async function temporaryRecordPath() {
  const directory = await mkdtemp(join(tmpdir(), 'clickbridge-auth-store-'));
  return { directory, recordPath: join(directory, 'phone-auth.json') };
}

// A v2 bridge record with exactly one active phone, for tests that need to
// seed disk state directly rather than going through initialize().
function singlePhoneRecord({
  macVerifier = VERIFIER_A, deviceId = 'seed-device-000001', label = 'Phone',
  credentialVersion, verifier, registryRevision = 1,
} = {}) {
  return `${JSON.stringify({
    schemaVersion: 2,
    macVerifier,
    registryRevision,
    phones: [{ deviceId, label, credentialVersion, verifier, status: 'active' }],
  })}\n`;
}

function assertBridgeShape(parsed, { registryRevision, activePhoneCount } = {}) {
  assert.equal(parsed.schemaVersion, 2);
  assert.match(parsed.macVerifier, /^[0-9a-f]{64}$/);
  assert.equal(Array.isArray(parsed.phones), true);
  if (registryRevision !== undefined) assert.equal(parsed.registryRevision, registryRevision);
  const active = parsed.phones.filter((phone) => phone.status === 'active');
  if (activePhoneCount !== undefined) assert.equal(active.length, activePhoneCount);
  for (const phone of parsed.phones) {
    assert.match(phone.deviceId, DEVICE_ID_PATTERN);
    assert.match(phone.verifier, /^[0-9a-f]{64}$/);
  }
}

async function captureAuthStoreError(operation, expectedCode) {
  let failure;
  try {
    await operation();
  } catch (error) {
    failure = error;
  }
  assert.equal(failure instanceof AuthStoreError, true);
  assert.equal(failure?.code, expectedCode);
  return failure;
}

test('exports a stable closed set of safe auth-store error codes', () => {
  assert.deepEqual(AUTH_STORE_ERROR_CODES, {
    INVALID_INPUT: 'invalid_input',
    VERSION_CONFLICT: 'version_conflict',
    NEXT_VERSION_INVALID: 'next_version_invalid',
    PERSISTENCE_FAILED: 'persistence_failed',
    STORAGE_FAILED: 'storage_failed',
    NOT_INITIALIZED: 'not_initialized',
    RECORD_INVALID: 'record_invalid',
    CAPACITY: 'capacity',
    UNKNOWN_DEVICE: 'unknown_device',
    ALREADY_REVOKED: 'already_revoked',
  });
  assert.equal(Object.isFrozen(AUTH_STORE_ERROR_CODES), true);

  const terse = new AuthStoreError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid');
  const reworded = new AuthStoreError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'completely different wording');
  assert.equal(terse.code, reworded.code);
});

test('initialize migrates the initial credential to a one-phone bridge record', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: realFs,
    crypto: realCrypto,
    log: () => {},
  });

  // initialize() resolves the raw durable record (verifier included, for
  // internal use); snapshot() is the redacted summary safe to expose.
  const created = await store.initialize();
  assert.equal(created.phones[0].credentialVersion, 0);
  assert.equal(store.snapshot().activePhoneCredentialVersion, 0);
  assert.equal(store.snapshot().enrolledCount, 1);

  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assertBridgeShape(onDisk, { registryRevision: 1, activePhoneCount: 1 });
  assert.equal(onDisk.phones[0].credentialVersion, 0);
  assert.equal(onDisk.phones[0].verifier, VERIFIER_A);
  assert.equal((await stat(recordPath)).mode & 0o777, 0o600);
  assert.equal(await store.matchesCredential(TOKEN_A), true);
  assert.equal(await store.matchesCredential(TOKEN_B), false);
  assert.equal(Object.isFrozen(store.snapshot()), true);
});

test('an existing valid record is authoritative over the environment credential', async () => {
  const { recordPath } = await temporaryRecordPath();
  await writeFile(recordPath, singlePhoneRecord({ credentialVersion: 7, verifier: VERIFIER_B }), { mode: 0o600 });
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: realFs,
    crypto: realCrypto,
    log: () => {},
  });

  await store.initialize();
  assert.equal(store.snapshot().activePhoneCredentialVersion, 7);
  assert.equal(await store.matchesCredential(TOKEN_A), false);
  assert.equal(await store.matchesCredential(TOKEN_B), true);
  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assert.equal(onDisk.phones[0].credentialVersion, 7);
  assert.equal(onDisk.phones[0].verifier, VERIFIER_B);
});

test('authenticateCredential returns only an immutable device descriptor for the matching phone', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: realFs,
    crypto: realCrypto,
    log: () => {},
  });
  await store.initialize();

  const descriptor = store.authenticateCredential(TOKEN_A);
  assert.deepEqual(Object.keys(descriptor).sort(), ['credentialVersion', 'deviceId']);
  assert.equal(descriptor.credentialVersion, 0);
  assert.match(descriptor.deviceId, DEVICE_ID_PATTERN);
  assert.equal(Object.isFrozen(descriptor), true);
  assert.equal(JSON.stringify(descriptor).includes(TOKEN_A), false);
  assert.equal(JSON.stringify(descriptor).includes(VERIFIER_A), false);
  assert.throws(() => {
    descriptor.credentialVersion = 99;
  }, TypeError);
  assert.equal(descriptor.credentialVersion, 0);
});

test('authenticateCredential fails closed for uninitialized, wrong, and malformed credentials', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });

  for (const credential of [TOKEN_A, TOKEN_B, '', null, undefined, ['01'.repeat(32)], new String(TOKEN_A)]) {
    assert.equal(store.authenticateCredential(credential), null);
  }

  await store.initialize();
  for (const credential of [TOKEN_B, '', null, undefined, ['01'.repeat(32)], new String(TOKEN_A)]) {
    assert.equal(store.authenticateCredential(credential), null);
  }
});

test('authenticateCredential remains closed after malformed authority initialization fails', async () => {
  const { recordPath } = await temporaryRecordPath();
  await writeFile(recordPath, '{"schemaVersion":1}\n', { mode: 0o600 });
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });

  await captureAuthStoreError(() => store.initialize(), AUTH_STORE_ERROR_CODES.RECORD_INVALID);
  assert.equal(store.authenticateCredential(TOKEN_A), null);
});

test('authenticateCredential keeps every prior device authenticating after an additive activation', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await store.initialize();

  const beforeRotation = store.authenticateCredential(TOKEN_A);
  await store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B });

  // Additive: the original device's credential and device identity are
  // unchanged by a second device's activation.
  assert.deepEqual(store.authenticateCredential(TOKEN_A), beforeRotation);
  const second = store.authenticateCredential(TOKEN_B);
  assert.equal(second.credentialVersion, 1);
  assert.notEqual(second.deviceId, beforeRotation.deviceId);
});

test('authenticateCredential is synchronous and redacts hostile crypto failures', async () => {
  const { recordPath } = await temporaryRecordPath();
  const logs = [];
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: (entry) => logs.push(String(entry)) });
  await store.initialize();

  const failureText = `${TOKEN_A} ${VERIFIER_A}`;
  const hostileStore = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_B,
    fs: realFs,
    crypto: {
      ...realCrypto,
      timingSafeEqual() { throw new Error(failureText); },
    },
    log: (entry) => logs.push(String(entry)),
  });
  await hostileStore.initialize();

  const result = hostileStore.authenticateCredential(TOKEN_A);
  assert.equal(result, null);
  assert.equal(result instanceof Promise, false);
  assert.equal(logs.some((entry) => entry.includes(TOKEN_A) || entry.includes(VERIFIER_A)), false);
});

test('initialize fails closed for malformed, permissive, and wrong-owner records', async () => {
  const malformed = await temporaryRecordPath();
  await writeFile(malformed.recordPath, '{"schemaVersion":1}\n', { mode: 0o600 });
  await captureAuthStoreError(
    () => createPhoneAuthStore({ recordPath: malformed.recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} }).initialize(),
    AUTH_STORE_ERROR_CODES.RECORD_INVALID,
  );

  const permissive = await temporaryRecordPath();
  await writeFile(permissive.recordPath, singlePhoneRecord({ credentialVersion: 0, verifier: VERIFIER_A }), { mode: 0o600 });
  await chmod(permissive.recordPath, 0o644);
  await captureAuthStoreError(
    () => createPhoneAuthStore({ recordPath: permissive.recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} }).initialize(),
    AUTH_STORE_ERROR_CODES.RECORD_INVALID,
  );
  await chmod(permissive.recordPath, 0o600);

  const wrongOwnerFs = {
    ...realFs,
    async stat(path) {
      const metadata = await realFs.stat(path);
      return { ...metadata, uid: (process.getuid?.() ?? 0) + 1 };
    },
  };
  await captureAuthStoreError(
    () => createPhoneAuthStore({ recordPath: permissive.recordPath, initialPhoneToken: TOKEN_A, fs: wrongOwnerFs, crypto: realCrypto, log: () => {} }).initialize(),
    AUTH_STORE_ERROR_CODES.RECORD_INVALID,
  );
});

test('initialize classifies invalid input and storage failures without leaking sensitive details', async () => {
  const invalidPath = `/sensitive/${TOKEN_A}/phone-auth.json`;
  const invalidInput = await captureAuthStoreError(
    () => Promise.resolve().then(() => createPhoneAuthStore({ recordPath: '', initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto })),
    AUTH_STORE_ERROR_CODES.INVALID_INPUT,
  );
  assert.equal(invalidInput.message.includes(TOKEN_A), false);

  for (const wording of [`cannot read ${invalidPath}`, `different storage wording ${VERIFIER_A}`]) {
    const failingFs = {
      ...realFs,
      async stat() {
        const error = new Error(wording);
        error.code = 'EACCES';
        throw error;
      },
    };
    const failure = await captureAuthStoreError(
      () => createPhoneAuthStore({ recordPath: invalidPath, initialPhoneToken: TOKEN_A, fs: failingFs, crypto: realCrypto }).initialize(),
      AUTH_STORE_ERROR_CODES.STORAGE_FAILED,
    );
    assert.equal(failure.message.includes(invalidPath), false);
    assert.equal(failure.message.includes(TOKEN_A), false);
    assert.equal(failure.message.includes(VERIFIER_A), false);
  }
});

test('atomic persistence fsyncs a 0600 sibling temp before rename and fsyncs the directory after', async () => {
  const { directory, recordPath } = await temporaryRecordPath();
  const events = [];
  const observingFs = {
    ...realFs,
    async open(path, flags, mode) {
      const handle = await realFs.open(path, flags, mode);
      const kind = path === directory ? 'directory' : 'temporary';
      if (kind === 'temporary') {
        assert.equal(flags, 'wx');
        assert.equal(mode, 0o600);
      }
      return {
        async writeFile(value) { events.push(`${kind}:write`); return handle.writeFile(value); },
        async sync() { events.push(`${kind}:fsync`); return handle.sync(); },
        async close() { events.push(`${kind}:close`); return handle.close(); },
      };
    },
    async rename(from, to) {
      events.push('rename');
      assert.equal(to, recordPath);
      assert.equal(from.startsWith(`${recordPath}.tmp-`), true);
      return realFs.rename(from, to);
    },
  };
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: observingFs, crypto: realCrypto, log: () => {} });

  await store.initialize();
  assert.deepEqual(events, [
    'temporary:write', 'temporary:fsync', 'temporary:close',
    'rename', 'directory:fsync', 'directory:close',
  ]);
});

test('activate is compare-and-swap, requires the next monotonic version, and is additive', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await store.initialize();

  await captureAuthStoreError(
    () => store.activate({ expectedVersion: 1, credentialVersion: 2, verifier: VERIFIER_B }),
    AUTH_STORE_ERROR_CODES.VERSION_CONFLICT,
  );
  await captureAuthStoreError(
    () => store.activate({ expectedVersion: 0, credentialVersion: 2, verifier: VERIFIER_B }),
    AUTH_STORE_ERROR_CODES.NEXT_VERSION_INVALID,
  );
  await captureAuthStoreError(
    () => store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: 'zz'.repeat(32) }),
    AUTH_STORE_ERROR_CODES.INVALID_INPUT,
  );
  assert.equal(store.snapshot().activePhoneCredentialVersion, 0);

  const activated = await store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B });
  assert.equal(activated.activePhoneCredentialVersion, 1);
  assert.equal(activated.enrolledCount, 2);
  assert.equal(Object.isFrozen(activated), true);

  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assertBridgeShape(onDisk, { registryRevision: 2, activePhoneCount: 2 });
  // The original phone is still present and active, not replaced.
  assert.equal(onDisk.phones[0].credentialVersion, 0);
  assert.equal(onDisk.phones[0].status, 'active');
  assert.equal(onDisk.phones[1].credentialVersion, 1);
  assert.equal(onDisk.phones[1].verifier, VERIFIER_B);
});

test('activate rejects a ninth simultaneous phone', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await store.initialize();

  let expectedVersion = 0;
  for (let index = 0; index < 7; index += 1) {
    const credentialVersion = expectedVersion + 1;
    const verifier = realCrypto.createHash('sha256')
      .update(Buffer.from(String(index).padStart(64, '0'), 'hex')).digest('hex');
    // eslint-disable-next-line no-await-in-loop
    await store.activate({ expectedVersion, credentialVersion, verifier });
    expectedVersion = credentialVersion;
  }
  assert.equal(store.snapshot().enrolledCount, 8);

  await captureAuthStoreError(
    () => store.activate({
      expectedVersion,
      credentialVersion: expectedVersion + 1,
      verifier: realCrypto.createHash('sha256').update(Buffer.from('ff'.repeat(32), 'hex')).digest('hex'),
    }),
    AUTH_STORE_ERROR_CODES.CAPACITY,
  );
  assert.equal(store.snapshot().enrolledCount, 8);
});

test('snapshot before initialization has a stable typed error', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto });
  const failure = await captureAuthStoreError(
    () => Promise.resolve().then(() => store.snapshot()),
    AUTH_STORE_ERROR_CODES.NOT_INITIALIZED,
  );
  assert.equal(failure.message.includes(recordPath), false);
  assert.equal(failure.message.includes(TOKEN_A), false);
});

test('a failed activation preserves the prior durable and in-memory record and removes only its temp', async () => {
  const { directory, recordPath } = await temporaryRecordPath();
  const logs = [];
  const failingFs = {
    ...realFs,
    async rename() { throw new Error(`injected rename failure ${TOKEN_B} ${VERIFIER_B}`); },
  };
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: (entry) => logs.push(String(entry)) });
  await store.initialize();
  const failingStore = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_B, fs: failingFs, crypto: realCrypto, log: (entry) => logs.push(String(entry)) });
  await failingStore.initialize();

  let failure;
  try {
    await failingStore.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B });
  } catch (error) {
    failure = error;
  }
  assert.equal(failure instanceof AuthStoreError, true);
  assert.equal(failure?.code, AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED);
  assert.match(failure?.message ?? '', /persist auth record failed/);
  for (const secret of [recordPath, TOKEN_A, TOKEN_B, VERIFIER_A, VERIFIER_B]) {
    assert.equal(failure?.message.includes(secret), false);
    assert.equal(logs.some((entry) => entry.includes(secret)), false);
  }
  assert.equal(failingStore.snapshot().activePhoneCredentialVersion, 0);
  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assert.equal(onDisk.phones.length, 1);
  assert.equal(onDisk.phones[0].verifier, VERIFIER_A);
  assert.deepEqual((await readdir(directory)).sort(), ['phone-auth.json']);
});

test('a post-rename durability failure suspends every authority until rollback is fully durable', async () => {
  const { directory, recordPath } = await temporaryRecordPath();
  const initialStore = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await initialStore.initialize();

  let failNextDirectorySync = true;
  let directorySyncFailed = false;
  let rollbackCloseStarted;
  let releaseRollbackClose;
  const rollbackCloseGate = new Promise((resolve) => { rollbackCloseStarted = resolve; });
  const rollbackCloseRelease = new Promise((resolve) => { releaseRollbackClose = resolve; });
  const failingFs = {
    ...realFs,
    async open(path, flags, mode) {
      const handle = await realFs.open(path, flags, mode);
      if (path !== directory) return handle;
      return {
        async sync() {
          if (failNextDirectorySync) {
            failNextDirectorySync = false;
            directorySyncFailed = true;
            throw new Error('injected directory fsync failure');
          }
          return handle.sync();
        },
        async close() {
          if (directorySyncFailed) {
            directorySyncFailed = false;
            rollbackCloseStarted();
            await rollbackCloseRelease;
          }
          return handle.close();
        },
      };
    },
  };
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_B, fs: failingFs, crypto: realCrypto, log: () => {} });
  await store.initialize();

  const activation = store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B });
  await rollbackCloseGate;

  const queuedActivation = store.activate(null);
  let queuedActivationSettled = false;
  queuedActivation.catch(() => { queuedActivationSettled = true; });
  try {
    assert.throws(
      () => store.snapshot(),
      (error) => error instanceof AuthStoreError
        && error.code === AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
    );
    assert.throws(
      () => store.authenticateCredential(TOKEN_A),
      (error) => error instanceof AuthStoreError
        && error.code === AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
    );
    await captureAuthStoreError(
      () => store.matchesCredential(TOKEN_A),
      AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
    );
    await captureAuthStoreError(
      () => store.initialize(),
      AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
    );
    await Promise.resolve();
    assert.equal(queuedActivationSettled, true);
  } finally {
    releaseRollbackClose();
  }

  await assert.rejects(activation, /persist auth record failed/);
  await assert.rejects(queuedActivation);
  assert.equal(store.snapshot().activePhoneCredentialVersion, 0);
  const restored = store.authenticateCredential(TOKEN_A);
  assert.equal(restored.credentialVersion, 0);
  assert.equal(await store.matchesCredential(TOKEN_A), true);
  assert.equal(await store.matchesCredential(TOKEN_B), false);
  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assert.equal(onDisk.phones.length, 1);
  assert.equal(onDisk.phones[0].verifier, VERIFIER_A);
  assert.deepEqual((await readdir(directory)).sort(), ['phone-auth.json']);
});

test('a failed rollback after post-rename durability failure poisons every authority API until a fresh store reloads disk', async () => {
  const { directory, recordPath } = await temporaryRecordPath();
  const initialStore = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await initialStore.initialize();

  const logs = [];
  let directorySyncCount = 0;
  let renameCount = 0;
  let releaseRollbackCleanup;
  let rollbackCleanupStarted;
  const rollbackCleanupGate = new Promise((resolve) => { rollbackCleanupStarted = resolve; });
  const rollbackCleanupRelease = new Promise((resolve) => { releaseRollbackCleanup = resolve; });
  const failingFs = {
    ...realFs,
    async open(path, flags, mode) {
      const handle = await realFs.open(path, flags, mode);
      if (path !== directory) return handle;
      return {
        async sync() {
          directorySyncCount += 1;
          if (directorySyncCount === 1) {
            throw new Error(`injected directory fsync failure ${TOKEN_A} ${VERIFIER_A}`);
          }
          return handle.sync();
        },
        async close() { return handle.close(); },
      };
    },
    async rename(from, to) {
      renameCount += 1;
      if (renameCount === 2) {
        throw new Error(`injected rollback rename failure ${TOKEN_B} ${VERIFIER_B}`);
      }
      return realFs.rename(from, to);
    },
    async unlink(path) {
      if (path.startsWith(`${recordPath}.tmp-`) && renameCount === 2) {
        rollbackCleanupStarted();
        await rollbackCleanupRelease;
      }
      return realFs.unlink(path);
    },
  };
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: failingFs,
    crypto: realCrypto,
    log: (entry) => logs.push(String(entry)),
  });
  await store.initialize();

  const activation = captureAuthStoreError(
    () => store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B }),
    AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
  );
  await rollbackCleanupGate;
  assert.throws(
    () => store.authenticateCredential(TOKEN_A),
    (error) => error instanceof AuthStoreError
      && error.code === AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
  );
  releaseRollbackCleanup();
  const activationFailure = await activation;
  const snapshotFailure = await captureAuthStoreError(
    () => Promise.resolve().then(() => store.snapshot()),
    AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
  );
  for (const credential of [TOKEN_A, TOKEN_B]) {
    assert.throws(
      () => store.authenticateCredential(credential),
      (error) => error instanceof AuthStoreError
        && error.code === AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED
        && !error.message.includes(credential),
    );
  }
  const matchFailure = await captureAuthStoreError(
    () => store.matchesCredential(TOKEN_A),
    AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
  );
  const secondActivationFailure = await captureAuthStoreError(
    () => store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B }),
    AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED,
  );
  assert.equal(renameCount, 2);

  for (const failure of [activationFailure, snapshotFailure, matchFailure, secondActivationFailure]) {
    assert.match(failure.message, /auth record|phone auth store|persist auth record/);
    for (const secret of [recordPath, TOKEN_A, TOKEN_B, VERIFIER_A, VERIFIER_B]) {
      assert.equal(failure.message.includes(secret), false);
    }
  }
  assert.deepEqual(logs, [
    'phone auth record rollback failed',
    'phone auth record persistence failed',
  ]);
  for (const secret of [recordPath, TOKEN_A, TOKEN_B, VERIFIER_A, VERIFIER_B]) {
    assert.equal(logs.some((entry) => entry.includes(secret)), false);
  }

  const onDisk = JSON.parse(await readFile(recordPath, 'utf8'));
  assert.equal(onDisk.phones.length, 2);
  assert.equal(onDisk.phones[1].credentialVersion, 1);
  assert.equal(onDisk.phones[1].verifier, VERIFIER_B);
  const freshStore = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await freshStore.initialize();
  assert.equal(freshStore.snapshot().activePhoneCredentialVersion, 1);
  assert.equal(await freshStore.matchesCredential(TOKEN_A), true);
  assert.equal(await freshStore.matchesCredential(TOKEN_B), true);
});
