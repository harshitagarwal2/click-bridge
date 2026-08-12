// Stateless one-phone / one-Mac relay logic.
//
// Deliberately transport-agnostic: a "connection" is any object with
// send(string) and close(). server.js supplies real WebSockets; tests supply
// fakes. Nothing here touches the network or persists anything.

import {
  parseClientMessage,
  encodeMessage,
  isExpired,
  ProtocolError,
} from './protocol.js';

import {
  PROTOCOL_VERSION,
  RELAY_PENDING_TTL_MS,
  CLOCK_SKEW_TOLERANCE_MS,
} from './constants.js';

const micros = () => Number(process.hrtime.bigint() / 1000n);

export class RelayState {
  constructor(options = {}) {
    this.phone = null;
    this.mac = null;
    this.macState = { remoteEnabled: false, permission: 'unknown' };

    /** actionId -> { phone, timer } */
    this.pending = new Map();
    /** syncId -> { phone, timer } */
    this.syncPending = new Map();

    this.now = options.now ?? (() => Date.now());
    this.setTimeout = options.setTimeout ?? setTimeout;
    this.clearTimeout = options.clearTimeout ?? clearTimeout;
    this.log = options.log ?? (() => {});
    this.pendingTtlMs = options.pendingTtlMs ?? RELAY_PENDING_TTL_MS;
    this.skewToleranceMs = options.skewToleranceMs ?? CLOCK_SKEW_TOLERANCE_MS;
  }

  // -- plumbing ------------------------------------------------------------

  #send(conn, message) {
    if (!conn) return false;
    try {
      conn.send(encodeMessage(message));
      return true;
    } catch (err) {
      this.log('send_failed', { type: message.type, error: err.code ?? err.message });
      return false;
    }
  }

  /**
   * Install `conn` as the current socket for `role`, closing any previous one.
   * Returns the displaced connection, if any.
   */
  replaceRole(role, conn) {
    const previous = this[role];
    this[role] = conn;
    if (previous && previous !== conn) {
      this.log('role_replaced', { role });
      try {
        previous.close();
      } catch { /* already gone */ }
    }
    if (role === 'mac') {
      // A fresh Mac has not published state yet.
      this.macState = { remoteEnabled: false, permission: 'unknown' };
    }
    return previous ?? null;
  }

  /**
   * Clear `role` ONLY if `conn` is still the current owner. Without this guard
   * a replaced socket's late close callback would null out its replacement.
   */
  detachIfCurrent(role, conn) {
    if (this[role] !== conn) return false;
    this[role] = null;
    if (role === 'mac') {
      this.macState = { remoteEnabled: false, permission: 'unknown' };
      this.publishState();
    }
    if (role === 'phone') this.#dropRoutesOwnedBy(conn);
    return true;
  }

  #dropRoutesOwnedBy(conn) {
    for (const [id, entry] of this.pending) {
      if (entry.phone === conn) {
        this.clearTimeout(entry.timer);
        this.pending.delete(id);
      }
    }
    for (const [id, entry] of this.syncPending) {
      if (entry.phone === conn) {
        this.clearTimeout(entry.timer);
        this.syncPending.delete(id);
      }
    }
  }

  publishState() {
    this.#send(this.phone, {
      type: 'state',
      v: PROTOCOL_VERSION,
      macOnline: this.mac !== null,
      remoteEnabled: this.macState.remoteEnabled,
      permission: this.macState.permission,
    });
  }

  #route(map, id, conn) {
    const timer = this.setTimeout(() => {
      map.delete(id);
      this.log('route_expired', { id });
    }, this.pendingTtlMs);
    if (typeof timer?.unref === 'function') timer.unref();
    map.set(id, { phone: conn, timer });
  }

  #resolve(map, id) {
    const entry = map.get(id);
    if (!entry) return null;
    this.clearTimeout(entry.timer);
    map.delete(id);
    return entry;
  }

  // -- message handling ----------------------------------------------------

  /**
   * Handle one authenticated frame.
   * @returns {'ok'|'ignored'} — invalid frames after auth are ignored, never fatal.
   */
  handleMessage(role, conn, raw) {
    const startedUs = micros();
    let msg;
    try {
      msg = parseClientMessage(raw, role);
    } catch (err) {
      if (err instanceof ProtocolError) {
        this.log('invalid_message', { role, code: err.code });
        return 'ignored';
      }
      throw err;
    }

    // A frame from a socket that has already been replaced is not authoritative.
    if (this[role] !== conn) {
      this.log('stale_socket_message', { role, type: msg.type });
      return 'ignored';
    }

    switch (msg.type) {
      case 'heartbeat.request':
        this.#send(conn, {
          type: 'heartbeat.ack', v: PROTOCOL_VERSION, sequence: msg.sequence,
        });
        return 'ok';

      case 'heartbeat.ack':
        return 'ok';

      case 'mac.state':
        this.macState = {
          remoteEnabled: msg.remoteEnabled,
          permission: msg.permission,
        };
        this.publishState();
        return 'ok';

      case 'action.request':
        return this.#handleActionRequest(conn, msg, startedUs);

      case 'action.result':
        return this.#handleActionResult(msg);

      case 'time.sync.request':
        return this.#handleSyncRequest(conn, msg);

      case 'time.sync.response':
        return this.#handleSyncResponse(msg);

      default:
        this.log('unhandled_type', { type: msg.type });
        return 'ignored';
    }
  }

  #ack(conn, actionId, status, startedUs) {
    this.#send(conn, {
      type: 'relay.ack',
      v: PROTOCOL_VERSION,
      actionId,
      status,
      relayProcessingUs: Math.max(0, micros() - startedUs),
    });
  }

  #handleActionRequest(conn, msg, startedUs) {
    if (isExpired(msg, this.now(), this.skewToleranceMs)) {
      this.log('action_expired', { actionId: msg.actionId });
      this.#ack(conn, msg.actionId, 'rejected', startedUs);
      return 'ok';
    }
    if (this.pending.has(msg.actionId)) {
      this.log('action_duplicate_in_flight', { actionId: msg.actionId });
      this.#ack(conn, msg.actionId, 'rejected', startedUs);
      return 'ok';
    }
    if (!this.mac) {
      this.#ack(conn, msg.actionId, 'mac_offline', startedUs);
      return 'ok';
    }

    const forwarded = this.#send(this.mac, msg);
    if (!forwarded) {
      this.#ack(conn, msg.actionId, 'rejected', startedUs);
      return 'ok';
    }
    this.#route(this.pending, msg.actionId, conn);
    this.#ack(conn, msg.actionId, 'forwarded', startedUs);
    return 'ok';
  }

  #handleActionResult(msg) {
    const entry = this.#resolve(this.pending, msg.actionId);
    if (!entry) {
      this.log('result_without_route', { actionId: msg.actionId });
      return 'ignored';
    }
    // Never hand a replaced phone's result to its replacement.
    if (entry.phone !== this.phone) {
      this.log('result_for_replaced_phone', { actionId: msg.actionId });
      return 'ignored';
    }
    this.#send(entry.phone, msg);
    return 'ok';
  }

  #handleSyncRequest(conn, msg) {
    if (!this.mac) return 'ignored';
    if (!this.#send(this.mac, msg)) return 'ignored';
    this.#route(this.syncPending, msg.syncId, conn);
    return 'ok';
  }

  #handleSyncResponse(msg) {
    const entry = this.#resolve(this.syncPending, msg.syncId);
    if (!entry || entry.phone !== this.phone) return 'ignored';
    this.#send(entry.phone, msg);
    return 'ok';
  }

  /** Release every timer. Used on shutdown and between tests. */
  dispose() {
    for (const { timer } of this.pending.values()) this.clearTimeout(timer);
    for (const { timer } of this.syncPending.values()) this.clearTimeout(timer);
    this.pending.clear();
    this.syncPending.clear();
  }
}
