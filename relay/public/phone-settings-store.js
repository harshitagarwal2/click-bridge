const TOKEN_KEY = 'clickbridge.phoneToken';
const KEEP_WARM_KEY = 'clickbridge.keepWarm';

export class PhoneSettingsStore {
  constructor(storage) {
    this.storage = storage;
  }

  getToken() {
    try { return this.storage.getItem(TOKEN_KEY); } catch { return null; }
  }

  setToken(token) {
    try { this.storage.setItem(TOKEN_KEY, token); return true; } catch { return false; }
  }

  clearToken() {
    try { this.storage.removeItem(TOKEN_KEY); return true; } catch { return false; }
  }

  getKeepWarm() {
    try { return this.storage.getItem(KEEP_WARM_KEY) === '1'; } catch { return false; }
  }

  setKeepWarm(enabled) {
    try { this.storage.setItem(KEEP_WARM_KEY, enabled ? '1' : '0'); return true; } catch { return false; }
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
