import {
  AUTHENTICATION_REJECTED_CLOSE_CODE,
  encodeMessage,
  parseServerMessage,
  PHONE_TAKEN_OVER_CLOSE_CODE,
  PROTOCOL_VERSION,
} from './wire-protocol.js';
import {
  HEARTBEAT_INTERVAL_MS,
  HEARTBEAT_TIMEOUT_MS,
  KEEPWARM_INTERVAL_MS,
  PHONE_RECONNECT_BASE_MS,
  PHONE_RECONNECT_CAP_MS,
} from './runtime-constants.js';

const defaultScheduler = Object.freeze({
  setTimeout: (callback, delay) => setTimeout(callback, delay),
  clearTimeout: (timer) => clearTimeout(timer),
});

export class TransportController {
  constructor({
    name = 'oci',
    url,
    token,
    role,
    createSocket,
    clock = { now: Date.now },
    scheduler = defaultScheduler,
    random = Math.random,
    onMessage = () => {},
    onStatus = () => {},
  }) {
    this.name = name;
    this.getUrl = typeof url === 'function' ? url : () => url;
    this.getToken = typeof token === 'function' ? token : () => token;
    this.role = role;
    this.createSocket = createSocket ?? ((socketUrl) => new WebSocket(socketUrl));
    this.clock = clock;
    this.scheduler = scheduler;
    this.random = random;
    this.onMessage = onMessage;
    this.onStatus = onStatus;

    this._generation = 0;
    this._state = 'idle';
    this.socket = null;
    this.authenticated = false;
    this.suspended = false;
    this.terminalReason = null;
    this.keepWarm = false;
    this.attempt = 0;
    this.sequence = 0;
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.livenessTimer = null;
  }

  get state() { return this._state; }
  get generation() { return this._generation; }
  get ready() { return this.authenticated && this.socket?.readyState === 1; }

  connect() {
    this.#clearReconnect();
    if (this.terminalReason) {
      this.#publish('taken_over', this.terminalReason);
      return;
    }
    this.suspended = false;
    this.#open();
  }

  resume() {
    this.terminalReason = null;
    this.connect();
  }

  close(reason = 'intentional') {
    this.suspended = true;
    this.#clearReconnect();
    this.#stopHeartbeat();
    this.authenticated = false;
    this.attempt = 0;
    this._generation += 1;
    this.#teardownSocket(1000, reason);
    this.#publish('suspended', reason);
  }

  setKeepWarm(enabled) {
    this.keepWarm = Boolean(enabled);
    if (this.authenticated) this.#scheduleHeartbeat();
  }

  send(message) {
    if (!this.ready) return false;
    try {
      this.socket.send(encodeMessage(message));
      return true;
    } catch {
      this.#failGeneration('send_failed');
      return false;
    }
  }

  #open() {
    if (this.suspended) return;
    const token = this.getToken();
    if (!token) {
      this.#publish('idle', 'missing_token');
      return;
    }

    this.#stopHeartbeat();
    this.#teardownSocket(1000, 'replaced');
    const generation = ++this._generation;
    this.authenticated = false;
    this.#publish('connecting', 'connect');

    let socket;
    try {
      socket = this.createSocket(this.getUrl());
    } catch {
      this.#scheduleReconnect('create_failed');
      return;
    }
    this.socket = socket;
    const stale = () => generation !== this._generation || socket !== this.socket;

    socket.onopen = () => {
      if (stale()) return;
      this.#publish('authenticating', 'socket_open');
      try {
        socket.send(encodeMessage({
          type: 'hello', v: PROTOCOL_VERSION, role: this.role, token,
        }));
      } catch {
        this.#failGeneration('hello_failed');
      }
    };

    socket.onmessage = (event) => {
      if (stale()) return;
      let message;
      try {
        message = parseServerMessage(event.data, this.role);
      } catch {
        this.#failGeneration('invalid_frame');
        return;
      }

      if (!this.authenticated) {
        if (message.type !== 'hello.ok') {
          this.#failGeneration('expected_hello_ok');
          return;
        }
        this.authenticated = true;
        this.attempt = 0;
        this.#publish('ready', 'authenticated');
        this.#scheduleHeartbeat();
        return;
      }

      if (message.type === 'hello.ok') {
        this.#failGeneration('duplicate_hello');
        return;
      }
      if (message.type === 'heartbeat.ack') {
        this.scheduler.clearTimeout(this.livenessTimer);
        this.livenessTimer = null;
        return;
      }
      this.onMessage(message, Object.freeze({ name: this.name, generation }));
    };

    const down = () => {
      if (stale()) return;
      this.#failGeneration('socket_closed');
    };
    // The close event owns reconnection because only it carries application
    // close codes such as the terminal phone-takeover signal.
    socket.onerror = () => {};
    socket.onclose = (event) => {
      if (stale()) return;
      if (!this.authenticated && event.code === AUTHENTICATION_REJECTED_CLOSE_CODE) {
        this.#stopForAuthenticationRejection();
        return;
      }
      if (event.code === PHONE_TAKEN_OVER_CLOSE_CODE) {
        this.#stopForTakeover();
        return;
      }
      down();
    };
  }

  #stopForAuthenticationRejection() {
    this.suspended = true;
    this.authenticated = false;
    this.attempt = 0;
    this.#clearReconnect();
    this.#stopHeartbeat();
    this._generation += 1;
    this.#teardownSocket(1000, 'authentication_rejected');
    this.#publish('auth_rejected', 'server_rejected_credentials');
  }

  #stopForTakeover() {
    this.terminalReason = 'another_phone_took_over';
    this.suspended = true;
    this.authenticated = false;
    this.attempt = 0;
    this.#clearReconnect();
    this.#stopHeartbeat();
    this._generation += 1;
    this.#teardownSocket(1000, 'taken_over');
    this.#publish('taken_over', this.terminalReason);
  }

  #failGeneration(reason) {
    if (this.suspended || this._state === 'backoff') return;
    this.authenticated = false;
    this.#stopHeartbeat();
    this._generation += 1;
    this.#teardownSocket(1002, reason);
    this.#scheduleReconnect(reason);
  }

  #scheduleReconnect(reason) {
    if (this.suspended || this.reconnectTimer) return;
    this.attempt += 1;
    const ceiling = Math.min(
      PHONE_RECONNECT_CAP_MS,
      PHONE_RECONNECT_BASE_MS * (2 ** (this.attempt - 1)),
    );
    const delay = this.random() * ceiling;
    this.#publish('backoff', reason);
    this.reconnectTimer = this.scheduler.setTimeout(() => {
      this.reconnectTimer = null;
      this.#open();
    }, delay);
  }

  #scheduleHeartbeat() {
    this.scheduler.clearTimeout(this.heartbeatTimer);
    this.heartbeatTimer = null;
    const interval = this.keepWarm ? KEEPWARM_INTERVAL_MS : HEARTBEAT_INTERVAL_MS;
    this.heartbeatTimer = this.scheduler.setTimeout(() => this.#heartbeat(), interval);
  }

  #heartbeat() {
    this.heartbeatTimer = null;
    if (!this.ready || this.suspended) return;
    this.sequence += 1;
    if (!this.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: this.sequence })) return;
    if (this.livenessTimer == null) {
      this.livenessTimer = this.scheduler.setTimeout(() => {
        this.livenessTimer = null;
        this.#failGeneration('heartbeat_timeout');
      }, HEARTBEAT_TIMEOUT_MS);
    }
    this.#scheduleHeartbeat();
  }

  #stopHeartbeat() {
    this.scheduler.clearTimeout(this.heartbeatTimer);
    this.scheduler.clearTimeout(this.livenessTimer);
    this.heartbeatTimer = null;
    this.livenessTimer = null;
  }

  #clearReconnect() {
    this.scheduler.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  #teardownSocket(code, reason) {
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onerror = null;
    socket.onclose = null;
    try { socket.close(code, reason); } catch { /* socket is already closed */ }
  }

  #publish(state, reason) {
    this._state = state;
    this.onStatus(Object.freeze({
      state,
      reason,
      generation: this._generation,
      atUnixMs: this.clock.now(),
    }));
  }
}
