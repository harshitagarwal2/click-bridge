// Owns exactly one WebSocket generation, one reconnect timer, and one
// heartbeat timer. Owns NO logical action state — that belongs to the
// coordinator, so adding a second transport in Milestone 2 changes nothing here.

import { parseServerMessage } from './protocol-lite.js';
import {
  PROTOCOL_VERSION,
  HEARTBEAT_INTERVAL_MS,
  HEARTBEAT_TIMEOUT_MS,
  PHONE_RECONNECT_BASE_MS,
  PHONE_RECONNECT_CAP_MS,
  CLOSE_ROLE_REPLACED,
} from './constants-lite.js';

export class TransportController {
  /**
   * @param {object} o
   * @param {string} o.name          'oci' | 'tailscale'
   * @param {() => string} o.url
   * @param {() => string|null} o.token
   * @param {(m:object)=>void} o.onMessage
   * @param {(s:string)=>void} o.onStatus  'open' | 'closed'
   * @param {(fn:Function,ms:number)=>any} [o.setTimeout]
   * @param {()=>number} [o.random]
   * @param {(url:string)=>WebSocket} [o.createSocket]
   */
  constructor(o) {
    this.name = o.name;
    this.getUrl = o.url;
    this.getToken = o.token;
    this.onMessage = o.onMessage ?? (() => {});
    this.onStatus = o.onStatus ?? (() => {});
    this.setTimeout = o.setTimeout ?? ((f, ms) => setTimeout(f, ms));
    this.clearTimeout = o.clearTimeout ?? ((t) => clearTimeout(t));
    this.random = o.random ?? Math.random;
    this.createSocket = o.createSocket ?? ((url) => new WebSocket(url));

    this.generation = 0;
    this.socket = null;
    this.authenticated = false;
    this.attempt = 0;
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.heartbeatDeadline = null;
    this.pendingSequence = null;
    this.sequence = 0;
    /** Explicit gate: set BEFORE an intentional close so callbacks cannot reconnect. */
    this.suspended = false;
  }

  connect() {
    this.suspended = false;
    this.#open();
  }

  #open() {
    if (this.suspended) return;
    const token = this.getToken();
    if (!token) return;

    this.#teardownSocket();
    const generation = ++this.generation;
    let socket;
    try {
      socket = this.createSocket(this.getUrl());
    } catch {
      return this.#scheduleReconnect();
    }
    this.socket = socket;
    this.authenticated = false;

    const stale = () => generation !== this.generation;

    socket.onopen = () => {
      if (stale()) return;
      this.attempt = 0;
      socket.send(JSON.stringify({
        type: 'hello', v: PROTOCOL_VERSION, role: 'phone', token,
      }));
    };

    socket.onmessage = (event) => {
      if (stale()) return;
      if (typeof event.data !== 'string') return;   // binary frames have no meaning here
      let msg;
      try {
        msg = parseServerMessage(event.data);
      } catch {
        return;                                      // invalid frame: no side effect
      }
      if (msg.type === 'hello.ok') {
        this.authenticated = true;
        this.#startHeartbeat();
        this.onStatus('open');
        return;
      }
      if (msg.type === 'heartbeat.ack') {
        // Only the outstanding sequence counts. Accepting any ack would let a
        // stale or replayed frame satisfy the liveness check and keep a dead
        // path looking alive.
        if (msg.sequence === this.pendingSequence) {
          this.clearTimeout(this.heartbeatDeadline);
          this.heartbeatDeadline = null;
          this.pendingSequence = null;
        }
        return;
      }
      if (!this.authenticated) return;
      this.onMessage(msg);
    };

    const down = (event) => {
      if (stale()) return;
      this.authenticated = false;
      if (event?.code === CLOSE_ROLE_REPLACED) {
        // Terminal, not a drop. Another phone holds the role now; reconnecting
        // would evict it, which would evict us back, forever. Only a deliberate
        // user act (foregrounding, or the reclaim control) resumes.
        this.suspend();
        this.onStatus('replaced');
        return;
      }
      this.#stopHeartbeat();
      this.onStatus('closed');
      this.#scheduleReconnect();
    };
    socket.onclose = down;
    socket.onerror = down;
  }

  #startHeartbeat() {
    this.#stopHeartbeat();
    const beat = () => {
      if (!this.authenticated || this.suspended) return;
      this.sequence += 1;
      this.pendingSequence = this.sequence;
      this.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: this.sequence });
      this.heartbeatDeadline = this.setTimeout(() => {
        // No acknowledgement: treat the path as dead and cycle it.
        this.reconnect();
      }, HEARTBEAT_TIMEOUT_MS);
      this.heartbeatTimer = this.setTimeout(beat, HEARTBEAT_INTERVAL_MS);
    };
    this.heartbeatTimer = this.setTimeout(beat, HEARTBEAT_INTERVAL_MS);
  }

  #stopHeartbeat() {
    this.clearTimeout(this.heartbeatTimer);
    this.clearTimeout(this.heartbeatDeadline);
    this.heartbeatTimer = null;
    this.heartbeatDeadline = null;
    this.pendingSequence = null;
  }

  #scheduleReconnect() {
    if (this.suspended || this.reconnectTimer) return;
    this.attempt += 1;
    const ceiling = Math.min(
      PHONE_RECONNECT_CAP_MS,
      PHONE_RECONNECT_BASE_MS * 2 ** (this.attempt - 1),
    );
    const delay = this.random() * ceiling;   // full jitter
    this.reconnectTimer = this.setTimeout(() => {
      this.reconnectTimer = null;
      this.#open();
    }, delay);
  }

  #teardownSocket() {
    const s = this.socket;
    this.socket = null;
    if (!s) return;
    s.onopen = s.onmessage = s.onclose = s.onerror = null;
    try { s.close(); } catch { /* already gone */ }
  }

  /** Intentional stop. Sets the gate first so no callback can revive it. */
  suspend() {
    this.suspended = true;
    this.generation += 1;
    this.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.#stopHeartbeat();
    this.#teardownSocket();
    this.authenticated = false;
    this.attempt = 0;
  }

  reconnect() {
    const wasSuspended = this.suspended;
    this.suspend();
    if (!wasSuspended) this.connect();
  }

  get ready() {
    return this.authenticated && this.socket?.readyState === 1;
  }

  send(message) {
    if (!this.socket || this.socket.readyState !== 1) return false;
    try {
      this.socket.send(JSON.stringify(message));
      return true;
    } catch {
      return false;
    }
  }
}
