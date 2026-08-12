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

async function temporaryRecordPath() {
  const directory = await mkdtemp(join(tmpdir(), 'clickbridge-auth-store-'));
  return { directory, recordPath: join(directory, 'phone-auth.json') };
}

function expectedRecord(version, verifier) {
  return `${JSON.stringify({
    schemaVersion: 1,
    activePhoneCredentialVersion: version,
    activePhoneVerifier: verifier,
  })}\n`;
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
  });
  assert.equal(Object.isFrozen(AUTH_STORE_ERROR_CODES), true);

  const terse = new AuthStoreError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid');
  const reworded = new AuthStoreError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'completely different wording');
  assert.equal(terse.code, reworded.code);
});

test('initialize migrates the initial credential to an exact verifier-only version-zero record', async () => {
  const { recordPath } = await temporaryRecordPath();
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: realFs,
    crypto: realCrypto,
    log: () => {},
  });

  assert.deepEqual(await store.initialize(), {
    schemaVersion: 1,
    activePhoneCredentialVersion: 0,
    activePhoneVerifier: VERIFIER_A,
  });
  assert.equal(await readFile(recordPath, 'utf8'), expectedRecord(0, VERIFIER_A));
  assert.equal((await stat(recordPath)).mode & 0o777, 0o600);
  assert.equal(await store.matchesCredential(TOKEN_A), true);
  assert.equal(await store.matchesCredential(TOKEN_B), false);
  assert.equal(Object.isFrozen(store.snapshot()), true);
});

test('an existing valid record is authoritative over the environment credential', async () => {
  const { recordPath } = await temporaryRecordPath();
  await writeFile(recordPath, expectedRecord(7, VERIFIER_B), { mode: 0o600 });
  const store = createPhoneAuthStore({
    recordPath,
    initialPhoneToken: TOKEN_A,
    fs: realFs,
    crypto: realCrypto,
    log: () => {},
  });

  assert.equal((await store.initialize()).activePhoneCredentialVersion, 7);
  assert.equal(await store.matchesCredential(TOKEN_A), false);
  assert.equal(await store.matchesCredential(TOKEN_B), true);
  assert.equal(await readFile(recordPath, 'utf8'), expectedRecord(7, VERIFIER_B));
});

test('initialize fails closed for malformed, permissive, and wrong-owner records', async () => {
  const malformed = await temporaryRecordPath();
  await writeFile(malformed.recordPath, '{"schemaVersion":1}\n', { mode: 0o600 });
  await captureAuthStoreError(
    () => createPhoneAuthStore({ recordPath: malformed.recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} }).initialize(),
    AUTH_STORE_ERROR_CODES.RECORD_INVALID,
  );

  const permissive = await temporaryRecordPath();
  await writeFile(permissive.recordPath, expectedRecord(0, VERIFIER_A), { mode: 0o600 });
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

test('activate is compare-and-swap and requires the next monotonic version', async () => {
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
  assert.deepEqual(activated, {
    schemaVersion: 1,
    activePhoneCredentialVersion: 1,
    activePhoneVerifier: VERIFIER_B,
  });
  assert.equal(Object.isFrozen(activated), true);
  assert.equal(await readFile(recordPath, 'utf8'), expectedRecord(1, VERIFIER_B));
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
  assert.equal(await readFile(recordPath, 'utf8'), expectedRecord(0, VERIFIER_A));
  assert.deepEqual((await readdir(directory)).sort(), ['phone-auth.json']);
});

test('a directory fsync failure after rename rolls the durable record back before rejecting', async () => {
  const { directory, recordPath } = await temporaryRecordPath();
  const initialStore = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_A, fs: realFs, crypto: realCrypto, log: () => {} });
  await initialStore.initialize();

  let failNextDirectorySync = true;
  const failingFs = {
    ...realFs,
    async open(path, flags, mode) {
      const handle = await realFs.open(path, flags, mode);
      if (path !== directory) return handle;
      return {
        async sync() {
          if (failNextDirectorySync) {
            failNextDirectorySync = false;
            throw new Error('injected directory fsync failure');
          }
          return handle.sync();
        },
        async close() { return handle.close(); },
      };
    },
  };
  const store = createPhoneAuthStore({ recordPath, initialPhoneToken: TOKEN_B, fs: failingFs, crypto: realCrypto, log: () => {} });
  await store.initialize();

  await assert.rejects(
    store.activate({ expectedVersion: 0, credentialVersion: 1, verifier: VERIFIER_B }),
    /persist auth record failed/,
  );
  assert.equal(store.snapshot().activePhoneCredentialVersion, 0);
  assert.equal(await readFile(recordPath, 'utf8'), expectedRecord(0, VERIFIER_A));
  assert.deepEqual((await readdir(directory)).sort(), ['phone-auth.json']);
});
