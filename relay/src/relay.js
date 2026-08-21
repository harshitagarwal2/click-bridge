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

    this.phonesByDevice = new Map();
    this.macs = new Set();
    this.macStates = new Map();
    // Legacy aliases kept for backward-compat with tests/tools that read .mac/.macState
    this._legacyMac = null;
    this._legacyMacState = { remoteEnabled: false, permission: 'unknown' };
    Object.defineProperty(this, 'mac', {
      get: () => {
        for (const c of this.macs) return c;
        return this._legacyMac;
      },
      set: (v) => { this._legacyMac = v; },
      configurable: true,
      enumerable: true,
    });
    Object.defineProperty(this, 'macState', {
      get: () => {
        if (this.macStates.size > 0) {
          for (const c of this.macs) return this.macStates.get(c) ?? this._legacyMacState;
        }
        return this._legacyMacState;
      },
      set: (v) => { this._legacyMacState = v; },
      configurable: true,
      enumerable: true,
    });
    this.pendingActions = new Map();
    this.pendingSync = new Map();
    this.pendingDiagnostics = new Map();
  }

  replaceRole(role, connection) {
    this.#assertRole(role);
    if (role === 'phone') {
      const deviceId = this.#phoneDeviceId(connection);
      const previous = this.phonesByDevice.get(deviceId) ?? null;
      this.phonesByDevice.set(deviceId, connection);
      if (previous && previous !== connection) {
        this.#dropOwnedRoutes(previous);
        this.#emit(previous, {
          kind: 'close', code: PHONE_TAKEN_OVER_CLOSE_CODE, reason: 'another phone took over',
        });
        this.log('role_replaced', {
          role, deviceId,
          previousConnectionId: previous.id,
          replacementConnectionId: connection.id,
        });
      }
      return previous;
    }
    // Multi-mac: allow coexistence. Each distinct connection is a separate desktop (Mac or Windows).
    // Do not close previous macs; just add and initialize its state.
    const already = this.macs.has(connection);
    const wasEmpty = this.macs.size === 0;
    this.macs.add(connection);
    if (!this.macStates.has(connection)) {
      this.macStates.set(connection, { remoteEnabled: false, permission: 'unknown' });
    }
    if (already) return null;
    // Keep legacy alias in sync for callers that read .mac (only when first)
    if (wasEmpty) {
      this._legacyMac = connection;
      this._legacyMacState = this.macStates.get(connection);
    }
    this.log('mac_added', { connectionId: connection.id, totalMacs: this.macs.size });
    return null;
  }

  detachIfCurrent(role, connection) {
    this.#assertRole(role);
    if (role === 'phone') {
      const deviceId = this.#phoneDeviceId(connection);
      if (this.phonesByDevice.get(deviceId) !== connection) return false;
      this.phonesByDevice.delete(deviceId);
      this.#dropOwnedRoutes(connection);
      return true;
    }
    if (!this.macs.has(connection)) return false;
    this.macs.delete(connection);
    this.macStates.delete(connection);
    if (this._legacyMac === connection) {
      this._legacyMac = null;
      this._legacyMacState = { remoteEnabled: false, permission: 'unknown' };
      for (const c of this.macs) {
        this._legacyMac = c;
        this._legacyMacState = this.macStates.get(c);
        break;
      }
    }
    this.publishState();
    return true;
  }

  publishState() {
    const aggregated = this.#aggregatedMacState();
    const message = {
      type: 'state',
      v: PROTOCOL_VERSION,
      macOnline: aggregated.macOnline,
      remoteEnabled: aggregated.remoteEnabled,
      permission: aggregated.permission,
    };
    let sent = false;
    for (const [deviceId, phone] of this.phonesByDevice) {
      if (!this.authorizePhone(phone)) {
        this.detachDevice(deviceId, phone);
        continue;
      }
      sent = this.#send(phone, message) || sent;
    }
    return sent;
  }

  #aggregatedMacState() {
    if (this.macs.size === 0) {
      return { macOnline: false, remoteEnabled: false, permission: 'unknown' };
    }
    const states = [...this.macStates.values()];
    const remoteEnabled = states.every((s) => s.remoteEnabled === true);
    let permission;
    if (states.every((s) => s.permission === 'ready')) permission = 'ready';
    else if (states.some((s) => s.permission === 'required')) permission = 'required';
    else permission = 'unknown';
    return { macOnline: true, remoteEnabled, permission };
  }

  handlePhoneMessage(connection, message) {
    const deviceId = this.#phoneDeviceId(connection);
    if (this.phonesByDevice.get(deviceId) !== connection) {
      this.log('stale_socket_message', { role: 'phone', type: message.type });
      return 'ignored';
    }
    if (!this.authorizePhone(connection)) {
      this.log('stale_phone_credential', { type: message.type });
      this.detachDevice(deviceId, connection);
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
      case 'time.sync.request': {
        const dest = this.#firstMac();
        return this.#forwardWithRoute(
          this.pendingSync, message.syncId, connection, dest, message, 'sync',
        );
      }
      case 'diagnostics.request': {
        const dest = this.#firstMac();
        return this.#forwardWithRoute(
          this.pendingDiagnostics, message.requestId, connection, dest, message, 'diagnostics',
        );
      }
      default:
        this.log('unexpected_validated_message', { role: 'phone', type: message.type });
        return 'ignored';
    }
  }

  handleMacMessage(connection, message) {
    if (!this.macs.has(connection)) {
      this.log('stale_socket_message', { role: 'mac', type: message.type });
      return 'ignored';
    }
    switch (message.type) {
      case 'heartbeat.request':
        this.#send(connection, {
          type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: message.sequence,
        });
        return 'ok';
      case 'mac.state': {
        const next = {
          remoteEnabled: message.remoteEnabled,
          permission: message.permission,
        };
        this.macStates.set(connection, next);
        if (this._legacyMac === connection) this._legacyMacState = next;
        this.publishState();
        return 'ok';
      }
      case 'action.result':
        return this.#routeActionResult(message.actionId, message);
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

  #firstMac() {
    for (const c of this.macs) return c;
    return null;
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
    if (this.macs.size === 0) {
      this.#ack(connection, message.actionId, 'mac_offline', 'mac_offline', startedUs);
      return 'ok';
    }

    const entry = this.#addRoute(this.pendingActions, message.actionId, connection, 'action');
    // Snapshot expected desktop count for result aggregation.
    entry.expectedMacs = this.macs.size;
    entry.results = [];
    entry.aggregateTimer = null;
    entry.hasPosted = false;
    let forwarded = 0;
    let lastEmitFailed = false;
    for (const macConn of this.macs) {
      if (this.#send(macConn, message)) forwarded += 1;
      else lastEmitFailed = true;
    }
    if (forwarded === 0) {
      this.#removeRoute(this.pendingActions, message.actionId, entry);
      this.log('action_not_forwarded_to_any_mac', { actionId: message.actionId, totalMacs: this.macs.size });
      this.#ack(connection, message.actionId, 'rejected', 'invalid_request', startedUs);
      return 'ok';
    }
    if (lastEmitFailed) this.log('action_partial_forward', { actionId: message.actionId, forwarded, totalMacs: this.macs.size });
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
    if (this.phonesByDevice.get(entry.deviceId) !== entry.owner
        || !this.authorizePhone(entry.owner)) {
      this.detachDevice(entry.deviceId, entry.owner);
      this.log(`${routeType}_for_replaced_phone`, { id });
      return 'ignored';
    }
    return this.#send(entry.owner, message) ? 'ok' : 'ignored';
  }

  #routeActionResult(actionId, message) {
    const entry = this.pendingActions.get(actionId);
    if (!entry) {
      this.log('action_without_route', { id: actionId });
      return 'ignored';
    }
    if (this.phonesByDevice.get(entry.deviceId) !== entry.owner
        || !this.authorizePhone(entry.owner)) {
      this.detachDevice(entry.deviceId, entry.owner);
      this.log('action_for_replaced_phone', { id: actionId });
      return 'ignored';
    }
    // Single-desktop fast path: preserve original at-most-once immediate delivery.
    if ((entry.expectedMacs ?? 1) <= 1) {
      const sent = this.#send(entry.owner, message) ? 'ok' : 'ignored';
      this.#removeRoute(this.pendingActions, actionId, entry);
      return sent;
    }
    // Multi-desktop aggregation: collect results for a short window and send
    // one aggregated outcome that prefers posted over any rejection. This
    // prevents the phone from seeing a spurious rejected when one desktop is
    // not ready but the others posted.
    entry.results = entry.results ?? [];
    entry.results.push(message);
    if (message.status === 'posted') entry.hasPosted = true;
    // If we have all expected results, flush immediately.
    if (entry.results.length >= (entry.expectedMacs ?? this.macs.size)) {
      return this.#flushAggregatedAction(actionId, entry);
    }
    // First result in multi-desktop mode: start the 150ms aggregation window.
    if (!entry.aggregateTimer) {
      entry.aggregateTimer = this.schedule(() => {
        if (this.pendingActions.get(actionId) !== entry) return;
        this.#flushAggregatedAction(actionId, entry);
      }, 150);
      entry.aggregateTimer?.unref?.();
    }
    return 'ok';
  }

  #flushAggregatedAction(actionId, entry) {
    if (entry.aggregateTimer) {
      this.cancel(entry.aggregateTimer);
      entry.aggregateTimer = null;
    }
    // Prefer posted; otherwise pick first result (most informative rejection).
    let best = entry.results?.[0] ?? null;
    if (entry.results) {
      const posted = entry.results.find((r) => r.status === 'posted');
      if (posted) best = posted;
    }
    if (!best) {
      this.#removeRoute(this.pendingActions, actionId, entry);
      return 'ignored';
    }
    if (this.phonesByDevice.get(entry.deviceId) !== entry.owner
        || !this.authorizePhone(entry.owner)) {
      this.#removeRoute(this.pendingActions, actionId, entry);
      this.detachDevice(entry.deviceId, entry.owner);
      this.log('action_for_replaced_phone', { id: actionId });
      return 'ignored';
    }
    const sent = this.#send(entry.owner, best) ? 'ok' : 'ignored';
    this.#removeRoute(this.pendingActions, actionId, entry);
    this.log('action_aggregated', { actionId, totalMacs: entry.expectedMacs, received: entry.results.length, chose: best.status });
    return sent;
  }

  #addRoute(map, id, owner, routeType) {
    const entry = { owner, deviceId: this.#phoneDeviceId(owner), timer: null };
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
    if (entry.aggregateTimer) this.cancel(entry.aggregateTimer);
    return true;
  }

  #dropOwnedRoutes(owner) {
    for (const map of [this.pendingActions, this.pendingSync, this.pendingDiagnostics]) {
      for (const [id, entry] of map) {
        if (entry.owner === owner) this.#removeRoute(map, id, entry);
      }
    }
  }

  detachDevice(deviceId, expectedConnection = null) {
    const connection = this.phonesByDevice.get(deviceId);
    if (!connection || (expectedConnection && connection !== expectedConnection)) return false;
    this.phonesByDevice.delete(deviceId);
    this.#dropOwnedRoutes(connection);
    return true;
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

  #phoneDeviceId(connection) {
    if (connection && (typeof connection === 'object' || typeof connection === 'function')
        && typeof connection.deviceId === 'string' && connection.deviceId.length > 0) {
      return connection.deviceId;
    }
    return connection;
  }

  dispose() {
    for (const map of [this.pendingActions, this.pendingSync, this.pendingDiagnostics]) {
      for (const entry of map.values()) {
        this.cancel(entry.timer);
        if (entry.aggregateTimer) this.cancel(entry.aggregateTimer);
      }
      map.clear();
    }
  }
}
