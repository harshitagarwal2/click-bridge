import { dirname } from 'node:path';

const SCHEMA_VERSION = 1;
const HEX_64 = /^[0-9a-f]{64}$/;
const SESSION_ID = /^[A-Za-z0-9_-]{22}$/;

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

function initialRecord() {
  return { schemaVersion: SCHEMA_VERSION, sessions: {} };
}

function validateRecord(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)
      || value.schemaVersion !== SCHEMA_VERSION || typeof value.sessions !== 'object'
      || value.sessions === null || Array.isArray(value)
      || Object.keys(value).some((key) => key !== 'schemaVersion' && key !== 'sessions')) {
    throw new TypeError('invalid session record');
  }
  for (const [id, session] of Object.entries(value.sessions)) {
    if (!SESSION_ID.test(id) || typeof session !== 'object' || session === null
        || !Number.isSafeInteger(session.createdAtUnixMs) || session.createdAtUnixMs < 0
        || !HEX_64.test(session.macVerifier) || !Number.isSafeInteger(session.activePhoneCredentialVersion)
        || session.activePhoneCredentialVersion < 0 || !HEX_64.test(session.activePhoneVerifier)
        || Object.keys(session).sort().join('\0')
          !== ['activePhoneCredentialVersion', 'activePhoneVerifier', 'createdAtUnixMs', 'macVerifier'].join('\0')) {
      throw new TypeError('invalid session record');
    }
  }
  return value;
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
    try {
      handle = await fs.open(temporaryPath, 'wx', 0o600);
      await handle.writeFile(`${JSON.stringify(next)}\n`);
      await handle.sync();
      await handle.close();
      handle = null;
      await fs.rename(temporaryPath, recordPath);
      const directoryHandle = await fs.open(directory, 'r');
      await directoryHandle.sync();
      await directoryHandle.close();
    } catch (error) {
      try { await handle?.close(); } catch {}
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
      record = validateRecord(JSON.parse(await fs.readFile(recordPath, 'utf8')));
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
            macVerifier: hashToken(macToken, crypto),
            activePhoneCredentialVersion: 0,
            activePhoneVerifier: hashToken(crypto.randomBytes(32).toString('hex'), crypto),
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
    return Boolean(session && !isExpired(session) && sameHex(hashToken(token, crypto), session.macVerifier, crypto));
  }

  function phoneAuthStore(id) {
    function session() {
      requireInitialized();
      const value = record.sessions[id];
      if (!value || isExpired(value)) throw new SessionStoreError('unknown_session', 'session is unavailable');
      return value;
    }
    return Object.freeze({
      async initialize() { await get(id); session(); },
      snapshot() {
        const value = session();
        return Object.freeze({ activePhoneCredentialVersion: value.activePhoneCredentialVersion });
      },
      authenticateCredential(token) {
        try {
          const value = session();
          return sameHex(hashToken(token, crypto), value.activePhoneVerifier, crypto)
            ? Object.freeze({ credentialVersion: value.activePhoneCredentialVersion }) : null;
        } catch { return null; }
      },
      async activate({ expectedVersion, credentialVersion, verifier }) {
        if (!Number.isSafeInteger(expectedVersion) || !Number.isSafeInteger(credentialVersion)
            || credentialVersion !== expectedVersion + 1 || !HEX_64.test(verifier)) {
          throw new SessionStoreError('invalid_input', 'invalid phone credential activation');
        }
        return enqueue(async () => {
          const current = session();
          if (current.activePhoneCredentialVersion !== expectedVersion) {
            throw new SessionStoreError('version_conflict', 'phone credential version conflict');
          }
          const next = {
            schemaVersion: SCHEMA_VERSION,
            sessions: {
              ...record.sessions,
              [id]: { ...current, activePhoneCredentialVersion: credentialVersion, activePhoneVerifier: verifier },
            },
          };
          await persist(next);
          record = next;
          return this.snapshot();
        });
      },
    });
  }

  return Object.freeze({ initialize, createSession, get, has, authenticateMac, phoneAuthStore });
}
