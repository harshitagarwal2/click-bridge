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
  }

  async save(token) {
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
      || (expected?.kind === 'clear' && token !== null)) {
      this.reconciliationBlocked = true;
      return false;
    }
    this.reconciliationPending = false;
    this.reconciliationExpected = null;
    if (token) this.applyToken(token);
    else this.clearToken();
    return true;
  }

  #maybeResume() {
    if (!this.isVisible() || this.inFlight.size !== 0 || this.reconciliationPending
      || !this.currentToken() || this.transportReady()) return false;
    this.connect();
    return true;
  }
}
