const TOKEN_KEY = 'clickbridge.phoneToken';
const KEEP_WARM_KEY = 'clickbridge.keepWarm';
const CREDENTIAL = /^[a-f0-9]{64}$/;

function validSlot(value) {
  return value !== null
    && typeof value === 'object'
    && CREDENTIAL.test(value.credential)
    && Number.isSafeInteger(value.version)
    && value.version >= 0;
}

function emptyCredentials() {
  return { active: null, pending: null };
}

export function saveTokenChange(settings, token, onSaved) {
  if (!settings.setToken(token)) {
    return {
      ok: false,
      message: 'Could not save the token. Check browser storage settings and try again.',
    };
  }
  onSaved();
  return { ok: true };
}

export function clearTokenChange(settings, onCleared) {
  if (!settings.clearToken()) {
    return {
      ok: false,
      message: 'Could not clear the token. Check browser storage settings and try again.',
    };
  }
  onCleared();
  return { ok: true };
}

export class PhoneSettingsStore {
  constructor(storage) {
    this.storage = storage;
  }

  getToken() {
    return this.getActive()?.credential ?? null;
  }

  setToken(token) {
    if (!CREDENTIAL.test(token)) return false;
    const current = this.#read();
    if (!current) return false;
    return this.#write({ ...current, active: { credential: token, version: current.active?.version ?? 0 } });
  }

  clearToken() {
    return this.forget();
  }

  getActive() {
    return this.#read()?.active ?? null;
  }

  getPending() {
    return this.#read()?.pending ?? null;
  }

  setActive(active) {
    if (!validSlot(active)) return false;
    const current = this.#read();
    if (!current) return false;
    return this.#write({ ...current, active: { ...active } });
  }

  stage(pending) {
    if (!validSlot(pending)) return false;
    const current = this.#read();
    if (!current) return false;
    return this.#write({ ...current, pending: { ...pending } });
  }

  promotePending(expected) {
    if (!validSlot(expected)) return false;
    const current = this.#read();
    if (!current?.pending) return false;
    if (current.pending.credential !== expected.credential
      || current.pending.version !== expected.version) return false;
    return this.#write({ active: current.pending, pending: null });
  }

  discardPending() {
    const current = this.#read();
    if (!current) return false;
    if (!current.pending) return true;
    return this.#write({ ...current, pending: null });
  }

  forget() {
    return this.#write(emptyCredentials());
  }

  getKeepWarm() {
    try { return this.storage.getItem(KEEP_WARM_KEY) === '1'; } catch { return false; }
  }

  setKeepWarm(enabled) {
    try { this.storage.setItem(KEEP_WARM_KEY, enabled ? '1' : '0'); return true; } catch { return false; }
  }

  #read() {
    try {
      const serialized = this.storage.getItem(TOKEN_KEY);
      if (serialized === null) return emptyCredentials();
      if (CREDENTIAL.test(serialized)) {
        return { active: { credential: serialized, version: 0 }, pending: null };
      }
      const value = JSON.parse(serialized);
      return {
        active: validSlot(value?.active) ? { ...value.active } : null,
        pending: validSlot(value?.pending) ? { ...value.pending } : null,
      };
    } catch {
      return null;
    }
  }

  #write(credentials) {
    try {
      this.storage.setItem(TOKEN_KEY, JSON.stringify(credentials));
      return true;
    } catch {
      return false;
    }
  }
}

export class MemorySettingsStore extends PhoneSettingsStore {
  constructor() {
    const values = new Map();
    super({
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, String(value)),
      removeItem: (key) => values.delete(key),
    });
  }
}
