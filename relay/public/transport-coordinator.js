import { ACTION_LIFETIME_MS, PROTOCOL_VERSION } from './wire-protocol.js';
import { PHONE_RESULT_TIMEOUT_MS } from './runtime-constants.js';

export function createActionRequest({ nowUnixMs, actionId }) {
  return Object.freeze({
    type: 'action.request',
    v: PROTOCOL_VERSION,
    actionId,
    action: 'click',
    issuedAtUnixMs: nowUnixMs,
    expiresAtUnixMs: nowUnixMs + ACTION_LIFETIME_MS,
  });
}

export class TransportCoordinator {
  constructor({
    getState,
    dispatch,
    transports,
    selectTransports,
    clock,
    scheduler,
    idGenerator,
    getClockDiagnostics,
    onBusyChange,
    onMetric,
  }) {
    this.getState = getState;
    this.dispatch = dispatch;
    this.getTransports = typeof transports === 'function' ? transports : () => transports;
    this.selectTransports = selectTransports ?? ((ports) => ports.filter((port) => port.ready).slice(0, 1));
    this.clock = clock ?? { now: Date.now, monotonicNow: () => performance.now() };
    this.scheduler = scheduler ?? { setTimeout, clearTimeout };
    this.idGenerator = idGenerator ?? (() => crypto.randomUUID());
    this.getClockDiagnostics = getClockDiagnostics ?? (() => null);
    this.onBusyChange = onBusyChange ?? (() => {});
    this.onMetric = onMetric ?? (() => {});
    this.pending = null;
    this.resultTimer = null;
  }

  get busy() {
    return this.pending !== null;
  }

  activate() {
    if (this.pending || !this.getState().visible) return 'ignored';
    const readyPorts = this.getTransports().filter((port) => port.ready);
    const selected = this.selectTransports(readyPorts).filter((port) => port.ready);
    if (selected.length === 0) return 'ignored';

    const activationMonotonicMs = this.clock.monotonicNow();
    const activationUnixMs = this.clock.epochMonotonicNow?.() ?? this.clock.now();

    const request = createActionRequest({
      nowUnixMs: this.clock.now(),
      actionId: this.idGenerator(),
    });
    const sentPorts = selected.filter((port) => port.send(request));
    if (sentPorts.length === 0) return 'ignored';

    this.pending = {
      request,
      activationMonotonicMs,
      ports: Object.freeze(sentPorts.map((port) => Object.freeze({
        name: port.name,
        generation: port.generation,
      }))),
    };
    this.dispatch({ type: 'action.sent', actionId: request.actionId });
    this.onMetric({
      type: 'activation', actionId: request.actionId, activationUnixMs,
      pathsSent: sentPorts.map((port) => port.name).join('+'),
    });
    this.onBusyChange(true);
    this.resultTimer = this.scheduler.setTimeout(() => {
      if (this.pending?.request.actionId !== request.actionId) return;
      this.dispatch({ type: 'action.timeout', actionId: request.actionId });
      this.onMetric({ type: 'terminal', actionId: request.actionId, status: 'Unknown',
        reason: 'result_timeout', confirmationMs: this.clock.monotonicNow() - this.pending.activationMonotonicMs });
      this.#settled();
    }, PHONE_RESULT_TIMEOUT_MS);
    return 'sent';
  }

  handleMessage(_via, message) {
    if (message.type === 'relay.ack') {
      if (this.pending?.request.actionId !== message.actionId) return false;
      const terminal = message.status !== 'forwarded';
      this.dispatch({
        type: 'action.ack',
        actionId: message.actionId,
        status: message.status,
        reason: message.reason,
        clockDiagnostics: message.reason === 'expired' ? this.getClockDiagnostics() : null,
      });
      this.onMetric({
        type: 'ack', actionId: message.actionId,
        ackMs: this.clock.monotonicNow() - this.pending.activationMonotonicMs,
        relayProcessingUs: message.relayProcessingUs, status: message.status, reason: message.reason,
      });
      if (terminal) {
        const confirmationMs = this.clock.monotonicNow() - this.pending.activationMonotonicMs;
        this.onMetric({ type: 'terminal', actionId: message.actionId, status: 'Rejected',
          reason: message.reason, confirmationMs,
          relayProcessingUs: message.relayProcessingUs, firstResultVia: _via });
        this.#settled();
      }
      return true;
    }

    if (message.type === 'action.result') {
      if (this.pending?.request.actionId !== message.actionId) {
        this.dispatch({
          type: 'action.result', actionId: message.actionId,
          status: message.status, reason: message.reason, ms: null,
        });
        this.onMetric({ type: 'late-result', actionId: message.actionId, via: _via });
        return false;
      }
      const ms = this.clock.monotonicNow() - this.pending.activationMonotonicMs;
      this.dispatch({
        type: 'action.result', actionId: message.actionId,
        status: message.status, reason: message.reason, ms,
      });
      this.onMetric({
        type: 'terminal', actionId: message.actionId, confirmationMs: ms,
        status: message.status, reason: message.reason, acceptedVia: message.acceptedVia,
        firstResultVia: _via, macProcessingUs: message.macProcessingUs,
        mouseDownPostedUnixMs: message.mouseDownPostedUnixMs ?? null,
      });
      this.#settled();
      return true;
    }
    return false;
  }

  abandon(reason = 'disconnected') {
    if (!this.pending) return;
    const actionId = this.pending.request.actionId;
    this.dispatch({ type: 'action.timeout', actionId, reason });
    this.onMetric({ type: 'terminal', actionId, status: 'Unknown', reason,
      confirmationMs: this.clock.monotonicNow() - this.pending.activationMonotonicMs });
    this.#settled();
  }

  #settled() {
    if (!this.pending) return;
    this.scheduler.clearTimeout(this.resultTimer);
    this.resultTimer = null;
    this.pending = null;
    this.onBusyChange(false);
  }
}
