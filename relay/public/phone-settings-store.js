const TOKEN_KEY = 'clickbridge.phoneToken';
const KEEP_WARM_KEY = 'clickbridge.keepWarm';
const CREDENTIAL_LOCK = 'clickbridge.phoneCredentials';
const CREDENTIAL = /^[a-f0-9]{64}$/;
const EPOCH = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function validCredential(value) {
  return typeof value === 'string' && CREDENTIAL.test(value);
}

function plainRecord(value) {
  if (value === null || typeof value !== 'object') return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function canonicalSlot(value) {
  try {
    if (!plainRecord(value)) return false;
    const credential = Object.getOwnPropertyDescriptor(value, 'credential');
    const version = Object.getOwnPropertyDescriptor(value, 'version');
    if (!(credential !== undefined
      && version !== undefined
      && 'value' in credential
      && 'value' in version
      && validCredential(credential.value)
      && Number.isSafeInteger(version.value)
      && version.value >= 0)) return null;
    return { credential: credential.value, version: version.value };
  } catch {
    return null;
  }
}

function nextVersion(credentials) {
  return (credentials.active?.version ?? 0) + 1;
}

function validGeneration(value) {
  return (Number.isSafeInteger(value) && value >= 0)
    || (typeof value === 'string' && EPOCH.test(value));
}

function emptyCredentials() {
  return { active: null, pending: null, generation: 0, provenance: 'unknown' };
}

export async function saveTokenChange(settings, token, onSaved, isCurrent = () => true) {
  if (!await settings.setToken(token)) {
    return {
      ok: false,
      message: 'Could not save the token. Check browser storage settings and try again.',
    };
  }
  if (isCurrent()) onSaved();
  return { ok: true };
}

export async function clearTokenChange(settings, onCleared) {
  if (!await settings.clearToken()) {
    return {
      ok: false,
      message: 'Could not clear the token. Check browser storage settings and try again.',
    };
  }
  onCleared();
  return { ok: true };
}

export function reconcileSavedToken(settings, onSaved, isVisible) {
  if (!isVisible()) return false;
  const token = settings.getToken();
  if (!token) return false;
  onSaved(token);
  return true;
}

export function tokenTransportCanResume(saveInFlight, token, ready) {
  return !saveInFlight && Boolean(token) && !ready;
}

export class PhoneSettingsStore {
  constructor(storage, locks = globalThis.navigator?.locks ?? null,
    epochFactory = () => globalThis.crypto?.randomUUID?.()) {
    this.storage = storage;
    this.locks = locks;
    this.epochFactory = epochFactory;
  }

  getToken() {
    return this.getActive()?.credential ?? null;
  }

  async setToken(token) {
    if (!validCredential(token)) return false;
    return this.#mutate((current) => ({
      active: current.active?.credential === token
        ? current.active
        : { credential: token, version: 0 },
      pending: null,
      provenance: current.active?.credential === token ? current.provenance : 'unknown',
    }));
  }

  async clearToken() {
    return this.forget();
  }

  getActive() {
    return this.#read()?.active ?? null;
  }

  getPending() {
    return this.#read()?.pending ?? null;
  }

  getSnapshot() {
    const current = this.#read();
    if (!current) return null;
    return {
      active: current.active, pending: current.pending,
      generation: current.generation, provenance: current.provenance,
    };
  }

  async setActive(active, expectedGeneration) {
    const canonical = canonicalSlot(active);
    if (!canonical || !validGeneration(expectedGeneration)) return false;
    return this.#mutate((current) => current.generation === expectedGeneration
      && !current.pending
      && canonical.version === (current.provenance === 'authoritative' ? nextVersion(current) : 1)
      ? { active: canonical, pending: null, provenance: 'authoritative' }
      : false);
  }

  async stage(pending, expectedGeneration) {
    const canonical = canonicalSlot(pending);
    if (!canonical) return false;
    if (!validGeneration(expectedGeneration)) return false;
    return this.#mutate((current) => {
      if (current.generation !== expectedGeneration) return false;
      if (current.provenance === 'authoritative'
        && !current.pending
        && canonical.version === nextVersion(current)) {
        return { ...current, pending: canonical };
      }
      if (current.active === null && canonical.version === 1
        && ['unknown', 'provisional'].includes(current.provenance)) {
        return { active: null, pending: canonical, provenance: 'provisional' };
      }
      return false;
    });
  }

  async promotePending(expected, expectedGeneration) {
    const canonical = canonicalSlot(expected);
    if (!canonical) return false;
    if (!validGeneration(expectedGeneration)) return false;
    return this.#mutate((current) => current.pending
      && current.generation === expectedGeneration
      && ['authoritative', 'provisional'].includes(current.provenance)
      && current.pending.credential === canonical.credential
      && current.pending.version === canonical.version
      ? { active: current.pending, pending: null, provenance: 'authoritative' }
      : false);
  }

  async discardPending(expected, expectedGeneration) {
    const canonical = canonicalSlot(expected);
    if (!canonical || !validGeneration(expectedGeneration)) return false;
    return this.#mutate((current) => current.generation === expectedGeneration
      && current.pending
      && current.pending.credential === canonical.credential
      && current.pending.version === canonical.version
      ? current.provenance === 'provisional'
        ? emptyCredentials()
        : { ...current, pending: null }
      : false);
  }

  async forget() {
    return this.#mutate(() => emptyCredentials(), { recoverCorrupt: true });
  }

  getKeepWarm() {
    try { return this.storage.getItem(KEEP_WARM_KEY) === '1'; } catch { return false; }
  }

  setKeepWarm(enabled) {
    try { this.storage.setItem(KEEP_WARM_KEY, enabled ? '1' : '0'); return true; } catch { return false; }
  }

  #read() {
    try {
      return this.#decode(this.storage.getItem(TOKEN_KEY));
    } catch {
      return null;
    }
  }

  #decode(serialized) {
    try {
      if (serialized === null) return emptyCredentials();
      if (typeof serialized !== 'string') return null;
      if (validCredential(serialized)) {
        return {
          active: { credential: serialized, version: 0 }, pending: null,
          generation: 0, provenance: 'unknown',
        };
      }
      const value = JSON.parse(serialized);
      if (!plainRecord(value)) return null;
      const active = Object.getOwnPropertyDescriptor(value, 'active');
      const pending = Object.getOwnPropertyDescriptor(value, 'pending');
      const generation = Object.getOwnPropertyDescriptor(value, 'generation');
      const provenance = Object.getOwnPropertyDescriptor(value, 'provenance');
      if (!active || !pending || !('value' in active) || !('value' in pending)) return null;
      if (generation && (!('value' in generation) || !validGeneration(generation.value))) return null;
      if (provenance && !('value' in provenance)) return null;
      const activeSlot = active.value === null ? null : canonicalSlot(active.value);
      const pendingSlot = pending.value === null ? null : canonicalSlot(pending.value);
      if ((active.value !== null && !activeSlot) || (pending.value !== null && !pendingSlot)) return null;
      const resolvedProvenance = provenance?.value ?? 'unknown';
      const resolvedActive = !provenance && activeSlot
        ? { credential: activeSlot.credential, version: 0 }
        : activeSlot;
      if (!['authoritative', 'provisional', 'unknown'].includes(resolvedProvenance)) return null;
      if ((resolvedProvenance === 'authoritative' && (!resolvedActive || resolvedActive.version === 0))
        || (resolvedProvenance === 'unknown' && resolvedActive && resolvedActive.version !== 0)
        || (resolvedProvenance === 'provisional' && (resolvedActive !== null
          || pendingSlot?.version !== 1))) return null;
      if (pendingSlot && resolvedProvenance === 'authoritative'
        && (!resolvedActive || pendingSlot.version !== resolvedActive.version + 1)) return null;
      if (pendingSlot && !['authoritative', 'provisional'].includes(resolvedProvenance)) return null;
      return {
        active: resolvedActive,
        pending: pendingSlot,
        generation: generation?.value ?? 0,
        provenance: resolvedProvenance,
      };
    } catch {
      return null;
    }
  }

  #writeMutation(credentials) {
    try {
      this.storage.setItem(TOKEN_KEY, JSON.stringify(credentials));
      return true;
    } catch {
      return false;
    }
  }

  #generationHint(serialized) {
    try {
      if (typeof serialized !== 'string' || validCredential(serialized)) return null;
      const value = JSON.parse(serialized);
      if (!plainRecord(value)) return null;
      const generation = Object.getOwnPropertyDescriptor(value, 'generation');
      return generation && 'value' in generation && validGeneration(generation.value)
        ? generation.value : null;
    } catch {
      return null;
    }
  }

  #freshEpoch(forbidden) {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const epoch = this.epochFactory();
      if (validGeneration(epoch) && epoch !== forbidden) return epoch;
    }
    return null;
  }

  async #mutate(change, { recoverCorrupt = false } = {}) {
    try {
      const request = this.locks?.request;
      if (typeof request !== 'function') return false;
      return await request.call(this.locks, CREDENTIAL_LOCK, { mode: 'exclusive' }, () => {
        let serialized;
        try { serialized = this.storage.getItem(TOKEN_KEY); } catch { return false; }
        const current = this.#decode(serialized);
        const generationHint = current?.generation ?? this.#generationHint(serialized);
        if (!current && !recoverCorrupt) return false;
        if (current?.generation === Number.MAX_SAFE_INTEGER) return false;
        const next = current ? change(current) : emptyCredentials();
        if (!next) return false;
        const epoch = this.#freshEpoch(generationHint);
        if (!epoch) return false;
        return this.#writeMutation({ ...next, generation: epoch });
      });
    } catch {
      return false;
    }
  }
}

export class MemorySettingsStore extends PhoneSettingsStore {
  constructor() {
    const values = new Map();
    const locks = { request: (_name, _options, callback) => callback() };
    super({
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, String(value)),
      removeItem: (key) => values.delete(key),
    }, locks);
  }
}
