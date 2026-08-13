import { dirname } from 'node:path';

import {
  addPhone,
  authenticatePhone,
  bridgeSnapshot,
  createBridgeRecord,
  encodeBridgeRecord,
  hasActiveCredentialVersion,
  isPhoneActive,
  latestCredentialVersion,
  renamePhone,
  revokePhone,
  validateBridgeRecord,
} from './bridge-registry.js';

const SCHEMA_VERSION = 2;
const LEGACY_SCHEMA_VERSION = 1;
const HEX_64 = /^[0-9a-f]{64}$/;
const LEGACY_RECORD_FIELDS = Object.freeze([
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
  CAPACITY: 'capacity',
  UNKNOWN_DEVICE: 'unknown_device',
  ALREADY_REVOKED: 'already_revoked',
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

function validateVerifier(value) {
  if (typeof value !== 'string' || !HEX_64.test(value)) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone verifier');
  }
  return value;
}

// Reads either an already-v2 bridge record, or a legacy (schemaVersion 1)
// single-credential record for one-time migration. Callers distinguish the
// two by checking `migratedFrom`.
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
  if (value.schemaVersion === SCHEMA_VERSION) {
    try {
      return { bridge: validateBridgeRecord(value), migratedFrom: null };
    } catch {
      throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
    }
  }
  if (Object.keys(value).sort().join('\0') !== LEGACY_RECORD_FIELDS.join('\0')
      || value.schemaVersion !== LEGACY_SCHEMA_VERSION
      || !Number.isSafeInteger(value.activePhoneCredentialVersion)
      || value.activePhoneCredentialVersion < 0
      || typeof value.activePhoneVerifier !== 'string'
      || !HEX_64.test(value.activePhoneVerifier)) {
    throw authError(AUTH_STORE_ERROR_CODES.RECORD_INVALID, 'invalid auth record');
  }
  return {
    bridge: null,
    migratedFrom: {
      credentialVersion: value.activePhoneCredentialVersion,
      verifier: value.activePhoneVerifier,
    },
  };
}

function encodeRecord(record) {
  return encodeBridgeRecord(record);
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

function mutationErrorCode(error) {
  if (!(error instanceof RangeError)) return AUTH_STORE_ERROR_CODES.INVALID_INPUT;
  if (error.message === 'active phone capacity reached') return AUTH_STORE_ERROR_CODES.CAPACITY;
  if (error.message === 'phone unavailable: unknown_device') return AUTH_STORE_ERROR_CODES.UNKNOWN_DEVICE;
  if (error.message === 'phone unavailable: already_revoked') return AUTH_STORE_ERROR_CODES.ALREADY_REVOKED;
  return AUTH_STORE_ERROR_CODES.INVALID_INPUT;
}

function mutationErrorMessage(error) {
  const code = mutationErrorCode(error);
  if (code === AUTH_STORE_ERROR_CODES.CAPACITY) return 'active phone capacity reached';
  if (code === AUTH_STORE_ERROR_CODES.UNKNOWN_DEVICE) return 'unknown phone device';
  if (code === AUTH_STORE_ERROR_CODES.ALREADY_REVOKED) return 'phone already revoked';
  return 'invalid phone registry mutation';
}

// This store backs both legacy /ws (a single bridge, its device list capped
// at eight like every other bridge) and, via the same shape, is reused
// wherever a single durable bridge record is needed outside the multi-bridge
// session store. `initialMacToken` seeds the bridge's mac verifier; it has no
// bearing on legacy /ws authentication itself, which still compares MAC_TOKEN
// directly (see server.js) — the field exists only because every bridge
// record requires one, and reusing that already-provisioned token avoids
// inventing an unused secret.
export function createPhoneAuthStore({
  recordPath, initialPhoneToken, initialMacToken = initialPhoneToken, fs, crypto, log = () => {},
}) {
  if (typeof recordPath !== 'string' || recordPath.length === 0) {
    throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid auth record path');
  }
  let current = null;
  let initializePromise = null;
  let activationQueue = Promise.resolve();
  let poisoned = false;

  function assertUsable() {
    if (poisoned) {
      throw authError(AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED, 'phone auth store unavailable');
    }
  }

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
      if (renamed) poisoned = true;
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
          poisoned = false;
        } catch {
          poisoned = true;
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

  function migratedBridge(legacy) {
    return createBridgeRecord({
      macVerifier: verifierForCredential(initialMacToken, crypto),
      registryRevision: 1,
      phones: [{
        deviceId: crypto.randomBytes(16).toString('base64url'),
        label: 'Legacy phone',
        credentialVersion: legacy.credentialVersion,
        verifier: legacy.verifier,
        status: 'active',
      }],
    });
  }

  async function initializeOnce() {
    if (current) return current;
    try {
      await verifyRecordMetadata(recordPath, fs);
      const parsed = parseRecord(await fs.readFile(recordPath, 'utf8'));
      if (parsed.migratedFrom) {
        current = migratedBridge(parsed.migratedFrom);
        await persist(current);
      } else {
        current = parsed.bridge;
      }
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

    const record = createBridgeRecord({
      macVerifier: verifierForCredential(initialMacToken, crypto),
      registryRevision: 1,
      phones: [{
        deviceId: crypto.randomBytes(16).toString('base64url'),
        label: 'Phone',
        credentialVersion: 0,
        verifier: verifierForCredential(initialPhoneToken, crypto),
        status: 'active',
      }],
    });
    await persist(record);
    current = record;
    return current;
  }

  async function initialize() {
    assertUsable();
    initializePromise ??= initializeOnce();
    return initializePromise;
  }

  function snapshot() {
    assertUsable();
    if (!current) {
      throw authError(AUTH_STORE_ERROR_CODES.NOT_INITIALIZED, 'phone auth store not initialized');
    }
    return bridgeSnapshot(current);
  }

  function authenticateCredential(credential) {
    assertUsable();
    if (!current) return null;
    try {
      const candidate = verifierForCredential(credential, crypto);
      return authenticatePhone(current, candidate, crypto);
    } catch {
      return null;
    }
  }

  async function matchesCredential(credential) {
    snapshot();
    return authenticateCredential(credential) !== null;
  }

  function isDeviceActive(deviceId, credentialVersion) {
    assertUsable();
    return current !== null && isPhoneActive(current, deviceId, credentialVersion);
  }

  function hasCredentialVersion(credentialVersion) {
    assertUsable();
    return current !== null && hasActiveCredentialVersion(current, credentialVersion);
  }

  async function activate(input) {
    assertUsable();
    const operation = activationQueue.then(async () => {
      if (typeof input !== 'object' || input === null || Array.isArray(input)) {
        throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone auth activation');
      }
      const { expectedVersion, credentialVersion, verifier } = input;
      if (!current) {
        throw authError(AUTH_STORE_ERROR_CODES.NOT_INITIALIZED, 'phone auth store not initialized');
      }
      const record = current;
      if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0) {
        throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid expected phone credential version');
      }
      if (expectedVersion !== latestCredentialVersion(record)) {
        throw authError(AUTH_STORE_ERROR_CODES.VERSION_CONFLICT, 'phone auth version conflict');
      }
      if (!Number.isSafeInteger(credentialVersion) || credentialVersion !== expectedVersion + 1) {
        throw authError(AUTH_STORE_ERROR_CODES.NEXT_VERSION_INVALID, 'phone credential must use next version');
      }
      let next;
      try {
        next = addPhone(record, {
          deviceId: typeof input.deviceId === 'string'
            ? input.deviceId : crypto.randomBytes(16).toString('base64url'),
          label: typeof input.label === 'string' ? input.label : 'Phone',
          credentialVersion,
          verifier: validateVerifier(verifier),
        });
      } catch (error) {
        if (error instanceof RangeError && error.message === 'active phone capacity reached') {
          throw authError(AUTH_STORE_ERROR_CODES.CAPACITY, 'active phone capacity reached');
        }
        throw authError(AUTH_STORE_ERROR_CODES.INVALID_INPUT, 'invalid phone auth activation');
      }
      await persist(next, record);
      current = next;
      return bridgeSnapshot(next);
    });
    activationQueue = operation.catch(() => {});
    return operation;
  }

  async function mutate(operation) {
    assertUsable();
    const queued = activationQueue.then(async () => {
      if (!current) throw authError(AUTH_STORE_ERROR_CODES.NOT_INITIALIZED, 'phone auth store not initialized');
      const previous = current;
      let next;
      try {
        next = operation(previous);
      } catch (error) {
        if (error instanceof AuthStoreError) throw error;
        throw authError(mutationErrorCode(error), mutationErrorMessage(error));
      }
      await persist(next, previous);
      current = next;
      return bridgeSnapshot(next);
    });
    activationQueue = queued.catch(() => {});
    return queued;
  }

  return Object.freeze({
    initialize,
    snapshot,
    authenticateCredential,
    matchesCredential,
    activate,
    isDeviceActive,
    hasCredentialVersion,
    addPhone: activate,
    renamePhone: (input) => mutate((bridge) => renamePhone(bridge, input)),
    revokePhone: (input) => mutate((bridge) => revokePhone(bridge, input)),
  });
}
