export function authenticateCredentialProbe(slot, signal, {
  createTransport, location, scheduler = globalThis,
}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timeout = null;
    const finish = (result, error = null) => {
      if (settled) return;
      settled = true;
      if (timeout !== null) scheduler.clearTimeout(timeout);
      probe.close('pairing_probe_complete');
      signal?.removeEventListener('abort', abort);
      if (error) reject(error);
      else resolve(result);
    };
    const abort = () => finish(null, new Error('pairing_probe_cancelled'));
    const probe = createTransport({
      location,
      token: slot.credential,
      onStatus: ({ state }) => {
        if (state === 'ready') finish(true);
        else if (state === 'taken_over') finish(false);
        else if (state === 'backoff') finish(null, new Error('pairing_probe_unavailable'));
      },
    });
    timeout = scheduler.setTimeout(
      () => finish(null, new Error('pairing_probe_timeout')), 10_000,
    );
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) { abort(); return; }
    probe.connect();
  });
}

export class PairingRecoveryGate {
  constructor({ needed, isVisible, startRecovery, recover, visible, online }) {
    this.needed = Boolean(needed);
    this.isVisible = isVisible;
    this.startRecovery = startRecovery;
    this.recover = recover;
    this.visibleLifecycle = visible;
    this.onlineLifecycle = online;
    this.inFlight = null;
  }

  visible() {
    if (this.needed || this.inFlight) {
      void this.#recoverIfNeeded();
      return true;
    }
    this.visibleLifecycle();
    return false;
  }

  online() {
    if (this.needed || this.inFlight) {
      void this.#recoverIfNeeded();
      return true;
    }
    this.onlineLifecycle();
    return false;
  }

  #recoverIfNeeded() {
    if (!this.needed || !this.isVisible()) return this.inFlight ?? Promise.resolve(this.needed);
    if (this.inFlight) return this.inFlight;
    this.startRecovery();
    this.inFlight = Promise.resolve(this.recover())
      .then((recovered) => {
        if (recovered) this.needed = false;
        return this.needed;
      })
      .catch(() => true)
      .finally(() => { this.inFlight = null; });
    return this.inFlight;
  }
}

export class CredentialLifecycleController {
  constructor({ settings, isVisible, currentToken, transportReady,
    applyToken, clearToken, connect, reportError }) {
    this.settings = settings;
    this.isVisible = isVisible;
    this.currentToken = currentToken;
    this.transportReady = transportReady;
    this.applyToken = applyToken;
    this.clearToken = clearToken;
    this.connect = connect;
    this.reportError = reportError;
    this.operation = 0;
    this.inFlight = new Set();
    this.latestIntent = null;
    this.latestSucceeded = null;
    this.reconciliationPending = false;
    this.reconciliationBlocked = false;
    this.reconciliationExpected = null;
    this.pairingActivation = null;
  }

  async save(token) {
    this.#finishPairingActivation(false);
    const operation = ++this.operation;
    this.inFlight.add(operation);
    this.latestIntent = { kind: 'save', token };
    this.latestSucceeded = null;
    const saved = await this.settings.setToken(token);
    if (saved) {
      this.reconciliationPending = true;
      this.reconciliationBlocked = false;
    }
    this.inFlight.delete(operation);
    if (operation !== this.operation) {
      this.#settleDurableState();
      return saved;
    }
    this.latestSucceeded = saved;
    if (!saved) {
      this.reportError('Could not save the token. Check browser storage settings and try again.');
      this.reconciliationPending = true;
      this.reconciliationBlocked = false;
      this.#settleDurableState();
      return false;
    }
    this.#settleDurableState();
    return true;
  }

  async clear() {
    this.#finishPairingActivation(false);
    const operation = ++this.operation;
    this.inFlight.add(operation);
    this.latestIntent = { kind: 'clear' };
    this.latestSucceeded = null;
    const cleared = await this.settings.clearToken();
    if (cleared) {
      this.reconciliationPending = true;
      this.reconciliationBlocked = false;
    }
    this.inFlight.delete(operation);
    if (operation !== this.operation) {
      this.#settleDurableState();
      return cleared;
    }
    this.latestSucceeded = cleared;
    if (!cleared) {
      this.reportError('Could not clear the token. Check browser storage settings and try again.');
      this.reconciliationPending = true;
      this.reconciliationBlocked = false;
      this.#settleDurableState();
      return false;
    }
    this.#settleDurableState();
    return true;
  }

  activatePairing(slot, signal) {
    this.#finishPairingActivation(false);
    const operation = ++this.operation;
    this.latestIntent = { kind: 'pairing', slot };
    this.latestSucceeded = true;
    this.reconciliationPending = true;
    this.reconciliationBlocked = false;
    this.reconciliationExpected = this.latestIntent;
    if (signal?.aborted) {
      this.reconciliationPending = true;
      this.reconciliationBlocked = true;
      this.reconciliationExpected = null;
      this.latestSucceeded = null;
      this.latestIntent = null;
      return Promise.resolve(false);
    }
    return new Promise((resolve) => {
      const activation = { operation, signal, resolve, onAbort: null };
      activation.onAbort = () => this.#finishPairingActivation(false, activation);
      signal?.addEventListener('abort', activation.onAbort, { once: true });
      this.pairingActivation = activation;
      this.#settleDurableState();
    });
  }

  visible() {
    this.#reconcile();
    this.#maybeResume();
  }

  online() {
    this.#reconcile();
    this.#maybeResume();
  }

  #settleDurableState() {
    if (this.inFlight.size !== 0) return false;
    if (this.reconciliationPending) {
      this.reconciliationExpected = this.latestSucceeded ? this.latestIntent : null;
      return this.#reconcile();
    }
    return this.#maybeResume();
  }

  #reconcile(expected = this.reconciliationExpected) {
    if (!this.reconciliationPending || !this.isVisible()
      || this.inFlight.size !== 0 || this.reconciliationBlocked) return false;
    let snapshot;
    try { snapshot = this.settings.getSnapshot(); } catch { snapshot = null; }
    const token = snapshot?.active?.credential ?? null;
    if (!snapshot
      || (expected?.kind === 'save' && token !== expected.token)
      || (expected?.kind === 'clear' && token !== null)
      || (expected?.kind === 'pairing' && (!snapshot.active
        || snapshot.pending !== null
        || snapshot.active.credential !== expected.slot?.credential
        || snapshot.active.version !== expected.slot?.version))) {
      this.reconciliationBlocked = true;
      if (expected?.kind === 'pairing') this.#finishPairingActivation(false);
      return false;
    }
    this.reconciliationPending = false;
    this.reconciliationExpected = null;
    if (token) this.applyToken(token);
    else this.clearToken();
    if (expected?.kind === 'pairing') this.#finishPairingActivation(true);
    return true;
  }

  #finishPairingActivation(result, expected = this.pairingActivation) {
    const activation = this.pairingActivation;
    if (!activation || activation !== expected) return;
    this.pairingActivation = null;
    if (!result && this.reconciliationExpected?.kind === 'pairing'
      && this.reconciliationExpected === this.latestIntent) {
      this.reconciliationPending = true;
      this.reconciliationBlocked = true;
      this.reconciliationExpected = null;
      this.latestSucceeded = null;
      this.latestIntent = null;
    }
    activation.signal?.removeEventListener('abort', activation.onAbort);
    activation.resolve(result);
  }

  #maybeResume() {
    if (!this.isVisible() || this.inFlight.size !== 0 || this.reconciliationPending
      || !this.currentToken() || this.transportReady()) return false;
    this.connect();
    return true;
  }
}
