import { dirname } from 'node:path';

const SCHEMA_VERSION = 1;
const HEX_64 = /^[0-9a-f]{64}$/;
const RECORD_FIELDS = Object.freeze([
  'activePhoneCredentialVersion',
  'activePhoneVerifier',
  'schemaVersion',
]);

export const AUTH_STORE_ERROR_CODES = Object.freeze({
  INVALID_INPUT: 'invalid_input',
  VERSION_CONFLICT: 'version_conflict',
  NEXT_VERSION_INVALID: 'next_version_invalid',
  PERSISTENCE_FAILED: 'persistence_failed',
  STORAGE_FAILED: 'storage_failed',
  NOT_INITIALIZED: 'not_initialized',
  RECORD_INVALID: 'record_invalid',
});

export class AuthStoreError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AuthStoreError';
    this.code = code;
  }
}

function authError(code, message) {
  return new AuthStoreError(code, message);
}

function immutableRecord(credentialVersion, verifier) {
  return Object.freeze({
    schemaVersion: SCHEMA_VERSION,
    activePhoneCredentialVersion: credentialVersion,
    activePhoneVerifier: verifier,
  });
}

function validateVerifier(value) {
  if (typeof value !== 'string' || !HEX_64.test(value)) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone verifier');
  }
  return value;
}

function validateVersion(value) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone credential version');
  }
  return value;
}

function parseRecord(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
  if (Object.keys(value).sort().join('\0') !== RECORD_FIELDS.join('\0')) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
  if (value.schemaVersion !== SCHEMA_VERSION) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
  try {
    return immutableRecord(
      validateVersion(value.activePhoneCredentialVersion),
      validateVerifier(value.activePhoneVerifier),
    );
  } catch {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
}

function encodeRecord(record) {
  return `${JSON.stringify(record)}\n`;
}

function verifierForCredential(credential, crypto) {
  if (typeof credential !== 'string' || !HEX_64.test(credential)) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone credential');
  }
  return crypto.createHash('sha256').update(Buffer.from(credential, 'hex')).digest('hex');
}

async function verifyRecordMetadata(recordPath, fs) {
  const metadata = await fs.stat(recordPath);
  if ((metadata.mode & 0o777) !== 0o600) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record permissions');
  }
  if (typeof process.getuid === 'function' && typeof metadata.uid === 'number'
      && metadata.uid !== process.getuid()) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record owner');
  }
}

export function createPhoneAuthStore({ recordPath, initialPhoneToken, fs, crypto, log = () => {} }) {
  if (typeof recordPath !== 'string' || recordPath.length === 0) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid auth record path');
  }
  let current = null;
  let initializePromise = null;
  let activationQueue = Promise.resolve();

  async function persist(record, previousRecord = null) {
    const directory = dirname(recordPath);
    const temporaryPath = `${recordPath}.tmp-${crypto.randomBytes(12).toString('hex')}`;
    let temporaryHandle;
    let directoryHandle;
    let renamed = false;
    try {
      temporaryHandle = await fs.open(temporaryPath, 'wx', 0o600);
      await temporaryHandle.writeFile(encodeRecord(record));
      await temporaryHandle.sync();
      await temporaryHandle.close();
      temporaryHandle = null;
      await fs.rename(temporaryPath, recordPath);
      renamed = true;
      directoryHandle = await fs.open(directory, 'r');
      await directoryHandle.sync();
      await directoryHandle.close();
      directoryHandle = null;
    } catch {
      if (temporaryHandle) {
        try { await temporaryHandle.close(); } catch {}
      }
      if (directoryHandle) {
        try { await directoryHandle.close(); } catch {}
      }
      try { await fs.unlink(temporaryPath); } catch {}
      if (renamed && previousRecord) {
        const rollbackPath = `${recordPath}.tmp-${crypto.randomBytes(12).toString('hex')}`;
        let rollbackHandle;
        let rollbackDirectoryHandle;
        try {
          rollbackHandle = await fs.open(rollbackPath, 'wx', 0o600);
          await rollbackHandle.writeFile(encodeRecord(previousRecord));
          await rollbackHandle.sync();
          await rollbackHandle.close();
          rollbackHandle = null;
          await fs.rename(rollbackPath, recordPath);
          rollbackDirectoryHandle = await fs.open(directory, 'r');
          await rollbackDirectoryHandle.sync();
          await rollbackDirectoryHandle.close();
          rollbackDirectoryHandle = null;
        } catch {
          if (rollbackHandle) {
            try { await rollbackHandle.close(); } catch {}
          }
          if (rollbackDirectoryHandle) {
            try { await rollbackDirectoryHandle.close(); } catch {}
          }
          try { await fs.unlink(rollbackPath); } catch {}
          log('phone auth record rollback failed');
        }
      }
      log('phone auth record persistence failed');
      throw authError(AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED, 'persist auth record failed');
    }
  }

  async function initializeOnce() {
    if (current) return current;
    try {
      await verifyRecordMetadata(recordPath, fs);
      current = parseRecord(await fs.readFile(recordPath, 'utf8'));
      return current;
    } catch (error) {
      if (error?.code === 'ENOENT') {
        // The record is initialized below.
      } else if (error instanceof AuthStoreError) {
        throw error;
      } else {
        throw authError(AUTH_STORE_ERROR_CODES.STORAGE_FAILED, 'read auth record failed');
      }
    }

    const record = immutableRecord(0, verifierForCredential(initialPhoneToken, crypto));
    await persist(record);
    current = record;
    return current;
  }

  async function initialize() {
    initializePromise ??= initializeOnce();
    return initializePromise;
  }

  function snapshot() {
    if (!current) {
      throw authError(AUTH_STORE_ERROR_CODES.NOT_INITIALIZED, 'phone auth store not initialized');
    }
    return current;
  }

  function authenticateCredential(credential) {
    const record = current;
    if (!record
        || record.schemaVersion !== SCHEMA_VERSION
        || !Number.isSafeInteger(record.activePhoneCredentialVersion)
        || record.activePhoneCredentialVersion < 0
        || typeof record.activePhoneVerifier !== 'string'
        || !HEX_64.test(record.activePhoneVerifier)) {
      return null;
    }
    try {
      const candidate = verifierForCredential(credential, crypto);
      if (!crypto.timingSafeEqual(
        Buffer.from(candidate, 'hex'),
        Buffer.from(record.activePhoneVerifier, 'hex'),
      )) {
        return null;
      }
      return Object.freeze({ credentialVersion: record.activePhoneCredentialVersion });
    } catch {
      return null;
    }
  }

  async function matchesCredential(credential) {
    snapshot();
    return authenticateCredential(credential) !== null;
  }

  async function activate(input) {
    const operation = activationQueue.then(async () => {
      if (typeof input !== 'object' || input === null || Array.isArray(input)) {
        throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone auth activation');
      }
      const { expectedVersion, credentialVersion, verifier } = input;
      const record = snapshot();
      if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0) {
        throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid expected phone credential version');
      }
      if (expectedVersion !== record.activePhoneCredentialVersion) {
        throw authError(AUTH_STORE_ERROR_CODES.VERSION_CONFLICT, 'phone auth version conflict');
      }
      if (!Number.isSafeInteger(credentialVersion) || credentialVersion !== expectedVersion + 1) {
        throw authError(AUTH_STORE_ERROR_CODES.NEXT_VERSION_INVALID, 'phone credential must use next version');
      }
      const next = immutableRecord(credentialVersion, validateVerifier(verifier));
      await persist(next, record);
      current = next;
      return next;
    });
    activationQueue = operation.catch(() => {});
    return operation;
  }

  return Object.freeze({ initialize, snapshot, authenticateCredential, matchesCredential, activate });
}
