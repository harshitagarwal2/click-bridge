import { performance } from 'node:perf_hooks';

import {
  CLOCK_SKEW_TOLERANCE_MS,
  PHONE_TAKEN_OVER_CLOSE_CODE,
  PROTOCOL_VERSION,
  RELAY_PENDING_TTL_MS,
} from './constants.js';

const VALID_ROLES = new Set(['phone', 'mac']);

/**
 * Transport-independent, in-memory routing state.
 *
 * Messages entering this object have already passed the strict role parser.
 * `emit` is the only output port and receives relay commands rather than wire
 * bytes, keeping WebSockets and encoding in server.js.
 */
export class RelayState {
  constructor({
    now = () => Date.now(),
    monotonicNowUs = () => performance.now() * 1000,
    schedule = (fn, ms) => setTimeout(fn, ms),
    cancel = (timer) => clearTimeout(timer),
    emit = () => false,
    log = () => {},
    pendingTtlMs = RELAY_PENDING_TTL_MS,
    skewToleranceMs = CLOCK_SKEW_TOLERANCE_MS,
    authorizePhone = () => true,
  } = {}) {
    this.now = now;
    this.monotonicNowUs = monotonicNowUs;
    this.schedule = schedule;
    this.cancel = cancel;
    this.emit = emit;
    this.log = log;
    this.pendingTtlMs = pendingTtlMs;
    this.skewToleranceMs = skewToleranceMs;
    this.authorizePhone = authorizePhone;

    this.phone = null;
    this.mac = null;
    this.macState = { remoteEnabled: false, permission: 'unknown' };
    this.pendingActions = new Map();
    this.pendingSync = new Map();
    this.pendingDiagnostics = new Map();
  }

  replaceRole(role, connection) {
    this.#assertRole(role);
    const previous = this[role];
    this[role] = connection;
    if (role === 'mac') {
      this.macState = { remoteEnabled: false, permission: 'unknown' };
    }
    if (previous && previous !== connection) {
      const close = role === 'phone'
        ? { code: PHONE_TAKEN_OVER_CLOSE_CODE, reason: 'another phone took over' }
        : { code: 4000, reason: 'replaced' };
      this.#emit(previous, { kind: 'close', ...close });
      this.log('role_replaced', { role });
    }
    return previous ?? null;
  }

  detachIfCurrent(role, connection) {
    this.#assertRole(role);
    if (this[role] !== connection) return false;
    this[role] = null;
    if (role === 'phone') {
      this.#dropOwnedRoutes(connection);
    } else {
      this.macState = { remoteEnabled: false, permission: 'unknown' };
      this.publishState();
    }
    return true;
  }

  publishState() {
    return this.#send(this.phone, {
      type: 'state',
      v: PROTOCOL_VERSION,
      macOnline: this.mac !== null,
      remoteEnabled: this.macState.remoteEnabled,
      permission: this.macState.permission,
    });
  }

  handlePhoneMessage(connection, message) {
    if (connection !== this.phone) {
      this.log('stale_socket_message', { role: 'phone', type: message.type });
      return 'ignored';
    }
    if (!this.authorizePhone(connection)) {
      this.log('stale_phone_credential', { type: message.type });
      return 'ignored';
    }
    switch (message.type) {
      case 'heartbeat.request':
        this.#send(connection, {
          type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: message.sequence,
        });
        return 'ok';
      case 'action.request':
        return this.#handleActionRequest(connection, message);
      case 'time.sync.request':
        return this.#forwardWithRoute(
          this.pendingSync, message.syncId, connection, this.mac, message, 'sync',
        );
      case 'diagnostics.request':
        return this.#forwardWithRoute(
          this.pendingDiagnostics, message.requestId, connection, this.mac, message, 'diagnostics',
        );
      default:
        this.log('unexpected_validated_message', { role: 'phone', type: message.type });
        return 'ignored';
    }
  }

  handleMacMessage(connection, message) {
    if (connection !== this.mac) {
      this.log('stale_socket_message', { role: 'mac', type: message.type });
      return 'ignored';
    }
    switch (message.type) {
      case 'heartbeat.request':
        this.#send(connection, {
          type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: message.sequence,
        });
        return 'ok';
      case 'mac.state':
        this.macState = {
          remoteEnabled: message.remoteEnabled,
          permission: message.permission,
        };
        this.publishState();
        return 'ok';
      case 'action.result':
        return this.#routeResponse(this.pendingActions, message.actionId, message, 'action');
      case 'time.sync.response':
        return this.#routeResponse(this.pendingSync, message.syncId, message, 'sync');
      case 'diagnostics.counters':
        return this.#routeResponse(
          this.pendingDiagnostics, message.requestId, message, 'diagnostics',
        );
      default:
        this.log('unexpected_validated_message', { role: 'mac', type: message.type });
        return 'ignored';
    }
  }

  #handleActionRequest(connection, message) {
    const startedUs = this.monotonicNowUs();
    const now = this.now();
    if (message.issuedAtUnixMs > now + this.skewToleranceMs) {
      this.log('action_future_issued', { actionId: message.actionId });
      this.#ack(connection, message.actionId, 'rejected', 'invalid_request', startedUs);
      return 'ok';
    }
    if (now > message.expiresAtUnixMs + this.skewToleranceMs) {
      this.log('action_expired', { actionId: message.actionId });
      this.#ack(connection, message.actionId, 'rejected', 'expired', startedUs);
      return 'ok';
    }
    if (this.pendingActions.has(message.actionId)) {
      this.log('action_duplicate_in_flight', { actionId: message.actionId });
      this.#ack(connection, message.actionId, 'rejected', 'invalid_request', startedUs);
      return 'ok';
    }
    if (!this.mac) {
      this.#ack(connection, message.actionId, 'mac_offline', 'mac_offline', startedUs);
      return 'ok';
    }

    const entry = this.#addRoute(this.pendingActions, message.actionId, connection, 'action');
    if (!this.#send(this.mac, message)) {
      this.#removeRoute(this.pendingActions, message.actionId, entry);
      this.#ack(connection, message.actionId, 'rejected', 'invalid_request', startedUs);
      return 'ok';
    }
    this.#ack(connection, message.actionId, 'forwarded', 'ok', startedUs);
    return 'ok';
  }

  #ack(connection, actionId, status, reason, startedUs) {
    this.#send(connection, {
      type: 'relay.ack',
      v: PROTOCOL_VERSION,
      actionId,
      status,
      reason,
      relayProcessingUs: Math.max(0, this.monotonicNowUs() - startedUs),
    });
  }

  #forwardWithRoute(map, id, owner, destination, message, routeType) {
    if (!destination || map.has(id)) {
      this.log(`${routeType}_not_forwarded`, { reason: destination ? 'duplicate_id' : 'mac_offline' });
      return 'ignored';
    }
    const entry = this.#addRoute(map, id, owner, routeType);
    if (!this.#send(destination, message)) {
      this.#removeRoute(map, id, entry);
      return 'ignored';
    }
    return 'ok';
  }

  #routeResponse(map, id, message, routeType) {
    const entry = map.get(id);
    if (!entry) {
      this.log(`${routeType}_without_route`, { id });
      return 'ignored';
    }
    this.#removeRoute(map, id, entry);
    if (entry.owner !== this.phone) {
      this.log(`${routeType}_for_replaced_phone`, { id });
      return 'ignored';
    }
    return this.#send(entry.owner, message) ? 'ok' : 'ignored';
  }

  #addRoute(map, id, owner, routeType) {
    const entry = { owner, timer: null };
    entry.timer = this.schedule(() => {
      if (map.get(id) === entry) map.delete(id);
      this.log('route_expired', { routeType, id });
    }, this.pendingTtlMs);
    entry.timer?.unref?.();
    map.set(id, entry);
    return entry;
  }

  #removeRoute(map, id, entry) {
    if (map.get(id) !== entry) return false;
    map.delete(id);
    this.cancel(entry.timer);
    return true;
  }

  #dropOwnedRoutes(owner) {
    for (const map of [this.pendingActions, this.pendingSync, this.pendingDiagnostics]) {
      for (const [id, entry] of map) {
        if (entry.owner === owner) this.#removeRoute(map, id, entry);
      }
    }
  }

  #send(connection, message) {
    if (!connection) return false;
    return this.#emit(connection, { kind: 'message', message });
  }

  #emit(connection, event) {
    try {
      return this.emit(connection, event) !== false;
    } catch (error) {
      this.log('emit_failed', {
        kind: event.kind,
        code: typeof error?.code === 'string' ? error.code : 'emit_error',
      });
      return false;
    }
  }

  #assertRole(role) {
    if (!VALID_ROLES.has(role)) throw new TypeError(`invalid role: ${role}`);
  }

  dispose() {
    for (const map of [this.pendingActions, this.pendingSync, this.pendingDiagnostics]) {
      for (const entry of map.values()) this.cancel(entry.timer);
      map.clear();
    }
  }
}
