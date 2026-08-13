import { dirname } from 'node:path';

import {
  addPhone,
  bridgeSnapshot,
  createBridgeRecord,
  hasActiveCredentialVersion,
  isPhoneActive,
  latestCredentialVersion,
  renamePhone,
  revokePhone,
  validateBridgeRecord,
  authenticatePhone,
} from './bridge-registry.js';

const SCHEMA_VERSION = 2;
const LEGACY_SCHEMA_VERSION = 1;
const HEX_64 = /^[0-9a-f]{64}$/;
const SESSION_ID = /^[A-Za-z0-9_-]{22}$/;
const RECORD_FIELDS = ['schemaVersion', 'sessions'];
const SESSION_FIELDS = ['bridge', 'createdAtUnixMs'];
const LEGACY_SESSION_FIELDS = [
  'activePhoneCredentialVersion', 'activePhoneVerifier', 'createdAtUnixMs', 'macVerifier',
];

function hashToken(token, crypto) {
  if (typeof token !== 'string' || !HEX_64.test(token)) throw new TypeError('invalid credential');
  return crypto.createHash('sha256').update(Buffer.from(token, 'hex')).digest('hex');
}

function sameHex(left, right, crypto) {
  if (typeof left !== 'string' || typeof right !== 'string' || !HEX_64.test(left) || !HEX_64.test(right)) {
    return false;
  }
  return crypto.timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

function exactFields(value, fields) {
  return Object.keys(value).sort().join('\0') === fields.join('\0');
}

function mutationErrorCode(error) {
  if (!(error instanceof RangeError)) return 'invalid_input';
  if (error.message === 'active phone capacity reached') return 'capacity';
  if (error.message === 'phone unavailable: unknown_device') return 'unknown_device';
  if (error.message === 'phone unavailable: already_revoked') return 'already_revoked';
  return 'invalid_input';
}

function mutationErrorMessage(code) {
  if (code === 'capacity') return 'active phone capacity reached';
  if (code === 'unknown_device') return 'unknown phone device';
  if (code === 'already_revoked') return 'phone already revoked';
  return 'invalid phone registry mutation';
}

function initialRecord() {
  return { schemaVersion: SCHEMA_VERSION, sessions: {} };
}

function validateV2Record(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)
      || value.schemaVersion !== SCHEMA_VERSION || !exactFields(value, RECORD_FIELDS)
      || typeof value.sessions !== 'object' || value.sessions === null || Array.isArray(value.sessions)) {
    throw new TypeError('invalid session record');
  }
  const sessions = {};
  for (const [id, session] of Object.entries(value.sessions)) {
    if (!SESSION_ID.test(id) || typeof session !== 'object' || session === null || Array.isArray(session)
        || !exactFields(session, SESSION_FIELDS)
        || !Number.isSafeInteger(session.createdAtUnixMs) || session.createdAtUnixMs < 0) {
      throw new TypeError('invalid session record');
    }
    sessions[id] = { createdAtUnixMs: session.createdAtUnixMs, bridge: validateBridgeRecord(session.bridge) };
  }
  return { schemaVersion: SCHEMA_VERSION, sessions };
}

function migrateV1Record(value, crypto) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)
      || value.schemaVersion !== LEGACY_SCHEMA_VERSION || !exactFields(value, RECORD_FIELDS)
      || typeof value.sessions !== 'object' || value.sessions === null || Array.isArray(value.sessions)) {
    throw new TypeError('invalid session record');
  }
  const sessions = {};
  for (const [id, session] of Object.entries(value.sessions)) {
    if (!SESSION_ID.test(id) || typeof session !== 'object' || session === null || Array.isArray(session)
        || !exactFields(session, LEGACY_SESSION_FIELDS)
        || !Number.isSafeInteger(session.createdAtUnixMs) || session.createdAtUnixMs < 0
        || !HEX_64.test(session.macVerifier) || !HEX_64.test(session.activePhoneVerifier)
        || !Number.isSafeInteger(session.activePhoneCredentialVersion)
        || session.activePhoneCredentialVersion < 0) {
      throw new TypeError('invalid session record');
    }
    sessions[id] = {
      createdAtUnixMs: session.createdAtUnixMs,
      bridge: createBridgeRecord({
        macVerifier: session.macVerifier,
        registryRevision: 1,
        phones: [{
          deviceId: crypto.randomBytes(16).toString('base64url'),
          label: 'Legacy phone',
          credentialVersion: session.activePhoneCredentialVersion,
          verifier: session.activePhoneVerifier,
          status: 'active',
        }],
      }),
    };
  }
  return { schemaVersion: SCHEMA_VERSION, sessions };
}

export class SessionStoreError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'SessionStoreError';
    this.code = code;
  }
}

export function createSessionStore({ recordPath, fs, crypto, maxSessions = 500, ttlMs = 90 * 24 * 60 * 60 * 1000,
  now = () => Date.now(), log = () => {} }) {
  if (typeof recordPath !== 'string' || recordPath.length === 0 || !Number.isSafeInteger(maxSessions)
      || maxSessions < 1 || !Number.isSafeInteger(ttlMs) || ttlMs < 1) {
    throw new TypeError('invalid session store configuration');
  }
  let record = null;
  let queue = Promise.resolve();

  const enqueue = (work) => {
    const operation = queue.then(work);
    queue = operation.catch(() => {});
    return operation;
  };

  async function persist(next) {
    const directory = dirname(recordPath);
    const temporaryPath = `${recordPath}.tmp-${crypto.randomBytes(12).toString('hex')}`;
    let handle;
    let directoryHandle;
    try {
      handle = await fs.open(temporaryPath, 'wx', 0o600);
      await handle.writeFile(`${JSON.stringify(next)}\n`);
      await handle.sync();
      await handle.close();
      handle = null;
      await fs.rename(temporaryPath, recordPath);
      directoryHandle = await fs.open(directory, 'r');
      await directoryHandle.sync();
      await directoryHandle.close();
      directoryHandle = null;
    } catch {
      try { await handle?.close(); } catch {}
      try { await directoryHandle?.close(); } catch {}
      try { await fs.unlink(temporaryPath); } catch {}
      log('session_store_persistence_failed');
      throw new SessionStoreError('persistence_failed', 'session persistence failed');
    }
  }

  function expiryCutoff() { return now() - ttlMs; }
  function isExpired(session) { return session.createdAtUnixMs < expiryCutoff(); }
  function withoutExpired(source) {
    const sessions = Object.fromEntries(Object.entries(source.sessions)
      .filter(([, session]) => !isExpired(session)));
    return { schemaVersion: SCHEMA_VERSION, sessions };
  }
  function requireInitialized() {
    if (!record) throw new SessionStoreError('not_initialized', 'session store not initialized');
  }

  async function initialize() {
    if (record) return;
    try {
      const metadata = await fs.stat(recordPath);
      if ((metadata.mode & 0o777) !== 0o600) throw new TypeError('invalid session record permissions');
      const value = JSON.parse(await fs.readFile(recordPath, 'utf8'));
      if (value?.schemaVersion === LEGACY_SCHEMA_VERSION) {
        record = migrateV1Record(value, crypto);
        await persist(record);
      } else {
        record = validateV2Record(value);
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        if (error instanceof SessionStoreError) throw error;
        throw new SessionStoreError('record_invalid', 'session record is invalid');
      }
      record = initialRecord();
      await persist(record);
    }
  }

  async function prune() {
    requireInitialized();
    const next = withoutExpired(record);
    if (Object.keys(next.sessions).length !== Object.keys(record.sessions).length) {
      await persist(next);
      record = next;
    }
  }

  async function get(id) {
    if (!SESSION_ID.test(id ?? '')) return null;
    return enqueue(async () => {
      await prune();
      return record.sessions[id] ? Object.freeze({ id }) : null;
    });
  }

  async function createSession() {
    return enqueue(async () => {
      await prune();
      if (Object.keys(record.sessions).length >= maxSessions) {
        throw new SessionStoreError('capacity', 'session capacity reached');
      }
      let id;
      do { id = crypto.randomBytes(16).toString('base64url'); } while (record.sessions[id]);
      const macToken = crypto.randomBytes(32).toString('hex');
      const next = {
        schemaVersion: SCHEMA_VERSION,
        sessions: {
          ...record.sessions,
          [id]: {
            createdAtUnixMs: now(),
            bridge: createBridgeRecord({ macVerifier: hashToken(macToken, crypto) }),
          },
        },
      };
      await persist(next);
      record = next;
      return Object.freeze({ id, macToken });
    });
  }

  function has(id) {
    requireInitialized();
    return SESSION_ID.test(id ?? '') && Boolean(record.sessions[id] && !isExpired(record.sessions[id]));
  }

  function authenticateMac(id, token) {
    requireInitialized();
    const session = record.sessions[id];
    return Boolean(session && !isExpired(session)
      && sameHex(hashToken(token, crypto), session.bridge.macVerifier, crypto));
  }

  function phoneAuthStore(id) {
    function session() {
      requireInitialized();
      const value = record.sessions[id];
      if (!value || isExpired(value)) throw new SessionStoreError('unknown_session', 'session is unavailable');
      return value;
    }

    async function mutate(operation) {
      return enqueue(async () => {
        const current = session();
        let bridge;
        try { bridge = operation(current.bridge); } catch (error) {
          if (error instanceof SessionStoreError) throw error;
          const code = mutationErrorCode(error);
          throw new SessionStoreError(code, mutationErrorMessage(code));
        }
        const next = {
          schemaVersion: SCHEMA_VERSION,
          sessions: { ...record.sessions, [id]: { ...current, bridge } },
        };
        await persist(next);
        record = next;
        return bridgeSnapshot(bridge);
      });
    }

    async function activate(input) {
      if (typeof input !== 'object' || input === null || Array.isArray(input)) {
        throw new SessionStoreError('invalid_input', 'invalid phone credential activation');
      }
      const { expectedVersion, credentialVersion, verifier } = input;
      if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0
          || !Number.isSafeInteger(credentialVersion) || credentialVersion !== expectedVersion + 1
          || !HEX_64.test(verifier)) {
        throw new SessionStoreError('invalid_input', 'invalid phone credential activation');
      }
      return mutate((bridge) => {
        if (latestCredentialVersion(bridge) !== expectedVersion) {
          throw new SessionStoreError('version_conflict', 'phone credential version conflict');
        }
        return addPhone(bridge, {
          deviceId: typeof input.deviceId === 'string'
            ? input.deviceId : crypto.randomBytes(16).toString('base64url'),
          label: typeof input.label === 'string' ? input.label : 'Phone',
          credentialVersion,
          verifier,
        });
      });
    }

    return Object.freeze({
      async initialize() { await get(id); session(); },
      snapshot() { return bridgeSnapshot(session().bridge); },
      authenticateCredential(token) {
        try {
          return authenticatePhone(session().bridge, hashToken(token, crypto), crypto);
        } catch { return null; }
      },
      activate,
      addPhone: activate,
      renamePhone: (input) => mutate((bridge) => renamePhone(bridge, input)),
      revokePhone: (input) => mutate((bridge) => revokePhone(bridge, input)),
      isDeviceActive: (deviceId, credentialVersion) => {
        try { return isPhoneActive(session().bridge, deviceId, credentialVersion); } catch { return false; }
      },
      hasCredentialVersion: (credentialVersion) => {
        try { return hasActiveCredentialVersion(session().bridge, credentialVersion); } catch { return false; }
      },
    });
  }

  return Object.freeze({ initialize, createSession, get, has, authenticateMac, phoneAuthStore });
}
