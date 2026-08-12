// Owns the single pending logical action, the result timeout, and the clock
// health gate. Transports are dumb pipes; this is the only place an action is
// created, so adding a second transport in Milestone 2 cannot create a second
// logical action.

import { reduce, activationDecision, clockSample, bestSample, clockHealthy } from './state.js';
import {
  PROTOCOL_VERSION,
  ACTION_LIFETIME_MS,
  PHONE_RESULT_TIMEOUT_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  CLOCK_HEALTH_SAMPLES,
  CLOCK_HEALTH_REFRESH_MS,
} from './constants-lite.js';

export class TransportCoordinator {
  constructor({ getState, dispatch, transports, now, uuid, setTimeout: st, clearTimeout: ct }) {
    this.getState = getState;
    this.dispatch = dispatch;
    this.transports = transports;              // [{ name, controller }]
    this.now = now ?? (() => Date.now());
    this.hiRes = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
    this.uuid = uuid ?? (() => crypto.randomUUID());
    this.setTimeout = st ?? ((f, ms) => setTimeout(f, ms));
    this.clearTimeout = ct ?? ((t) => clearTimeout(t));

    this.resultTimer = null;
    this.activationAt = null;
    this.pendingSyncs = new Map();
    this.samples = [];
    this.clockTimer = null;
    /** Diagnostics only; never mutates action.result. */
    this.firstResultVia = null;
  }

  // -- activation ----------------------------------------------------------

  /** @param {'pointer'|'click'} kind */
  activate(kind) {
    const decision = activationDecision(kind, this.getState());
    if (decision === 'consume') {
      this.dispatch({ type: 'pointer.consumed' });
      return 'consumed';
    }
    if (decision === 'ignore') return 'ignored';

    if (kind === 'pointer') this.dispatch({ type: 'pointer.armed' });

    const issuedAtUnixMs = this.now();
    const request = {
      type: 'action.request',
      v: PROTOCOL_VERSION,
      actionId: this.uuid(),
      action: 'click',
      issuedAtUnixMs,
      expiresAtUnixMs: issuedAtUnixMs + ACTION_LIFETIME_MS,
    };

    const ready = this.transports.filter((t) => t.controller.ready);
    if (ready.length === 0) return 'ignored';

    this.activationAt = this.hiRes();
    this.firstResultVia = null;
    this.dispatch({ type: 'action.sent', actionId: request.actionId });

    // Milestone 1 selects one path. Milestone 2 may send on every ready
    // transport — the identical immutable request, never a regenerated one.
    for (const t of ready) {
      t.controller.send(request);
      if (!this.hedging) break;
    }

    this.clearTimeout(this.resultTimer);
    this.resultTimer = this.setTimeout(() => {
      this.dispatch({ type: 'action.timeout', actionId: request.actionId });
    }, PHONE_RESULT_TIMEOUT_MS);

    return 'sent';
  }

  cancelPointer() {
    this.dispatch({ type: 'pointer.cancelled' });
  }

  // -- inbound -------------------------------------------------------------

  handleMessage(via, msg) {
    switch (msg.type) {
      case 'state':
        this.dispatch({
          type: 'mac.state',
          macOnline: msg.macOnline,
          remoteEnabled: msg.remoteEnabled,
          permission: msg.permission,
        });
        if (msg.macOnline && !this.getState().clock.checked) this.startClockHealth(via);
        return;

      case 'relay.ack':
        this.dispatch({ type: 'action.ack', actionId: msg.actionId, status: msg.status });
        if (msg.status !== 'forwarded') this.#stopResultTimer();
        return;

      case 'action.result': {
        const state = this.getState();
        const isFirst = state.action?.id === msg.actionId;
        if (isFirst) {
          this.firstResultVia = via;
          this.#stopResultTimer();
        }
        this.dispatch({
          type: 'action.result',
          actionId: msg.actionId,
          status: msg.status,
          reason: msg.reason,
          ms: isFirst && this.activationAt != null ? this.hiRes() - this.activationAt : null,
        });
        return;
      }

      case 'time.sync.response':
        this.#onSyncResponse(msg);
        return;

      default:
    }
  }

  #stopResultTimer() {
    this.clearTimeout(this.resultTimer);
    this.resultTimer = null;
  }

  // -- clock health --------------------------------------------------------

  /**
   * Measure the phone↔Mac offset before allowing any action. Without this a
   * skewed clock would make every click fail as `expired` with no explanation —
   * and a phone running fast would silently disable expiry altogether.
   */
  startClockHealth(via) {
    this.samples = [];
    this.pendingSyncs.clear();
    for (let i = 0; i < CLOCK_HEALTH_SAMPLES; i++) this.#sendSync(via);

    this.clearTimeout(this.clockTimer);
    this.clockTimer = this.setTimeout(() => {
      if (this.getState().mac.online) this.startClockHealth(via);
    }, CLOCK_HEALTH_REFRESH_MS);
  }

  #sendSync(via) {
    const transport = this.transports.find((t) => t.name === via) ?? this.transports[0];
    if (!transport?.controller.ready) return;
    const syncId = this.uuid();
    const phoneSendUnixMs = this.now();
    this.pendingSyncs.set(syncId, phoneSendUnixMs);
    transport.controller.send({
      type: 'time.sync.request', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs,
    });
  }

  #onSyncResponse(msg) {
    const t0 = this.pendingSyncs.get(msg.syncId);
    if (t0 === undefined) return;
    this.pendingSyncs.delete(msg.syncId);

    this.samples.push(clockSample({
      t0,
      t1: msg.macReceiveUnixMs,
      t2: msg.macSendUnixMs,
      t3: this.now(),
    }));

    if (this.samples.length < CLOCK_HEALTH_SAMPLES) return;

    const best = bestSample(this.samples);
    if (!best) {
      this.dispatch({ type: 'clock.health', healthy: false, offsetMs: null, uncertaintyMs: null });
      return;
    }
    this.dispatch({
      type: 'clock.health',
      healthy: clockHealthy(best.offsetMs, best.rttMs, CLOCK_SKEW_TOLERANCE_MS),
      offsetMs: best.offsetMs,
      uncertaintyMs: best.rttMs / 2,
    });
  }

  reset() {
    this.#stopResultTimer();
    this.clearTimeout(this.clockTimer);
    this.clockTimer = null;
    this.samples = [];
    this.pendingSyncs.clear();
    this.activationAt = null;
  }
}

export { reduce };
