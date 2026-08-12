import { deriveRelayWebSocketUrl } from './relay-transport.js';
import {
  CREDENTIAL_REPLACED_CLOSE_CODE,
  PAIRING_TTL_MS,
  PAIRING_VERSION,
  PROTOCOL_VERSION,
  encodeMessage,
  parseServerMessage,
} from './wire-protocol.js';

const HEX = /^[a-f0-9]{64}$/;
const DEFAULT_DEADLINES = Object.freeze({
  connectionMs: 10_000,
  claimMs: 10_000,
  approvalMs: PAIRING_TTL_MS,
});
const ALLOWED_MESSAGES = Object.freeze({
  claiming: new Set(['pair.claimed.phone', 'pair.failed']),
  awaiting_approval: new Set(['pair.credential', 'pair.failed']),
  activating: new Set(['pair.active', 'pair.failed']),
});
const PAIRING_SERVER_MESSAGES = new Set([
  'pair.claimed.phone', 'pair.credential', 'pair.active', 'pair.failed',
]);

function toHex(bytes) {
  return [...bytes].map((value) => value.toString(16).padStart(2, '0')).join('');
}

function fromHex(value) {
  if (!HEX.test(value)) throw new Error('invalid credential');
  return Uint8Array.from(value.match(/../g), (byte) => Number.parseInt(byte, 16));
}

function sameSlot(left, right) {
  return Boolean(left && right
    && left.credential === right.credential
    && left.version === right.version);
}

async function activationProof(cryptoProvider, credential, claimId, credentialVersion) {
  const key = await cryptoProvider.subtle.importKey(
    'raw', fromHex(credential), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const payload = new TextEncoder().encode(
    `clickbridge-pair-activate:v1:${claimId}:${credentialVersion}`,
  );
  return toHex(new Uint8Array(await cryptoProvider.subtle.sign('HMAC', key, payload)));
}

export class PairingController {
  constructor({
    location,
    settings,
    createSocket = (url) => new WebSocket(url),
    idGenerator = () => crypto.randomUUID(),
    randomBytes = () => crypto.getRandomValues(new Uint8Array(32)),
    crypto: cryptoProvider = crypto,
    onState = () => {},
    authenticateCredential = async () => false,
    startTransport = () => {},
    scheduler = globalThis,
    deadlines = DEFAULT_DEADLINES,
    now = () => Date.now(),
  }) {
    this.location = location;
    this.settings = settings;
    this.createSocket = createSocket;
    this.idGenerator = idGenerator;
    this.randomBytes = randomBytes;
    this.crypto = cryptoProvider;
    this.onState = onState;
    this.authenticateCredential = authenticateCredential;
    this.startTransport = startTransport;
    this.scheduler = scheduler;
    this.deadlines = { ...DEFAULT_DEADLINES, ...deadlines };
    this.now = now;
    this.socket = null;
    this.reference = null;
    this.claimId = null;
    this.acknowledgedSlot = null;
    this.generation = 0;
    this.phase = 'idle';
    this.deadlineTimer = null;
    this.pairingExpiresAtUnixMs = null;
    this.activation = null;
  }

  start(reference) {
    const activation = this.#detachActivation();
    const socketToRetire = this.socket;
    const generation = ++this.generation;
    this.#clearDeadline();
    this.#clearSensitive();
    this.#retireSocket(socketToRetire);
    this.#abortActivation(activation);
    if (this.generation !== generation) return;
    this.reference = reference;
    this.claimId = this.idGenerator();
    this.acknowledgedSlot = null;
    const sessionNonce = toHex(this.randomBytes());
    const socket = this.createSocket(deriveRelayWebSocketUrl(this.location));
    this.socket = socket;
    this.#scheduleDeadline(
      socket, generation, 'connecting', this.deadlines.connectionMs, 'connection_timeout',
    );
    this.#publish('connecting');

    socket.onopen = () => {
      if (!this.#current(socket, generation)) return;
      try {
        this.#send(socket, {
          type: 'pair.claim',
          reference: this.reference,
          claimId: this.claimId,
          sessionNonce,
          pairingVersion: PAIRING_VERSION,
          clientKind: 'pwa',
        });
      } catch {
        this.#terminate('failed', 'connection_failed', socket);
        return;
      }
      this.reference = null;
      this.#scheduleDeadline(
        socket, generation, 'claiming', this.deadlines.claimMs, 'claim_timeout',
      );
      this.#publish('claiming');
    };
    socket.onmessage = (event) => {
      if (!this.#current(socket, generation)) return;
      void this.#receive(event.data, socket, generation);
    };
    socket.onclose = (event) => {
      if (!this.#current(socket, generation)) return;
      if (event.code === CREDENTIAL_REPLACED_CLOSE_CODE) {
        this.#terminate('replaced', null, socket);
      } else {
        this.#terminate('failed', 'disconnected', socket);
      }
    };
    socket.onerror = () => {
      if (this.#current(socket, generation)) {
        this.#terminate('failed', 'connection_failed', socket);
      }
    };
  }

  cancel() {
    const socket = this.socket;
    try {
      if (socket?.readyState === 1 && this.claimId) {
        this.#send(socket, { type: 'pair.cancel.claim', claimId: this.claimId });
      }
    } catch {
      // Cancellation is local-first. Cleanup below must not depend on delivery.
    } finally {
      const activation = this.#detachActivation();
      const cancellationGeneration = ++this.generation;
      this.#clearDeadline();
      this.#clearSensitive();
      this.#retireSocket(socket);
      this.#abortActivation(activation);
      if (this.generation === cancellationGeneration) this.#publish('cancelled');
    }
  }

  async recover() {
    const activation = this.#detachActivation();
    const ownership = { generation: ++this.generation, socket: null };
    this.#clearDeadline();
    this.#retireSocket(this.socket);
    this.#clearSensitive();
    this.#abortActivation(activation);
    if (!this.#owns(ownership)) return false;
    while (true) {
      if (!this.#owns(ownership)) return false;
      const pending = this.settings.getPending();
      if (pending) {
        const authentication = await this.#authenticate(pending);
        if (!this.#owns(ownership)) return false;
        if (authentication === 'error') {
          this.#publish('failed', 'authentication_failed');
          return false;
        }
        if (!sameSlot(this.settings.getPending(), pending)) continue;
        if (authentication === 'accepted') {
          if (!this.settings.promotePending(pending)) {
            if (!sameSlot(this.settings.getPending(), pending)) continue;
            this.#publish('failed', 'storage_failed');
            return false;
          }
          return this.#activateTransport(pending, ownership);
        }
        if (!sameSlot(this.settings.getPending(), pending)) continue;
        if (!this.settings.discardPending(pending)) {
          if (!sameSlot(this.settings.getPending(), pending)) continue;
          this.#publish('failed', 'storage_failed');
          return false;
        }
      }

      const active = this.settings.getActive();
      if (!active) {
        this.#publish('idle');
        return false;
      }
      const authentication = await this.#authenticate(active);
      if (!this.#owns(ownership)) return false;
      if (authentication === 'error') {
        this.#publish('failed', 'authentication_failed');
        return false;
      }
      if (!sameSlot(this.settings.getActive(), active)) continue;
      if (authentication === 'accepted') {
        return this.#activateTransport(active, ownership);
      }
      this.#publish('idle');
      return false;
    }
  }

  async #receive(raw, socket, generation) {
    let message;
    try {
      message = parseServerMessage(raw, 'phone');
    } catch {
      if (this.#current(socket, generation)) {
        this.#terminate('failed', 'invalid_response', socket);
      }
      return;
    }
    if (!this.#current(socket, generation)) return;
    if (!PAIRING_SERVER_MESSAGES.has(message.type)) {
      this.#terminate('failed', 'invalid_response', socket);
      return;
    }
    if (message.claimId !== this.claimId) return;
    if (!ALLOWED_MESSAGES[this.phase]?.has(message.type)) {
      this.#terminate('failed', 'invalid_response', socket);
      return;
    }

    if (message.type === 'pair.claimed.phone') {
      this.pairingExpiresAtUnixMs = message.expiresAtUnixMs;
      const untilServerExpiry = Math.max(0, message.expiresAtUnixMs - this.now());
      this.#scheduleDeadline(
        socket,
        generation,
        'awaiting_approval',
        Math.min(this.deadlines.approvalMs, untilServerExpiry),
        'expired',
      );
      this.#publish('awaiting_approval', null, {
        confirmationCode: message.confirmationCode,
        expiresAtUnixMs: message.expiresAtUnixMs,
      });
      return;
    }
    if (message.type === 'pair.failed') {
      this.#terminate(
        message.reason === 'replaced' ? 'replaced' : 'failed', message.reason, socket,
      );
      return;
    }
    if (message.type === 'pair.credential') {
      const pending = { credential: message.credential, version: message.credentialVersion };
      if (!this.settings.stage(pending)) {
        this.#terminate('failed', 'storage_failed', socket);
        return;
      }
      let proof;
      try {
        proof = await activationProof(
          this.crypto, pending.credential, this.claimId, pending.version,
        );
      } catch {
        if (this.#current(socket, generation)) {
          this.#terminate('failed', 'activation_failed', socket);
        }
        return;
      }
      if (!this.#current(socket, generation)) return;
      if (!sameSlot(this.settings.getPending(), pending)) {
        this.#terminate('failed', 'storage_failed', socket);
        return;
      }
      this.acknowledgedSlot = pending;
      try {
        this.#send(socket, {
          type: 'pair.credential.ack',
          claimId: this.claimId,
          credentialVersion: pending.version,
          proof,
        });
      } catch {
        this.#terminate('failed', 'activation_failed', socket);
        return;
      }
      const untilServerExpiry = Math.max(
        0, (this.pairingExpiresAtUnixMs ?? this.now()) - this.now(),
      );
      this.#scheduleDeadline(
        socket, generation, 'activating', untilServerExpiry, 'expired',
      );
      this.#publish('activating');
      return;
    }
    if (message.type === 'pair.active') {
      const acknowledged = this.acknowledgedSlot;
      if (!acknowledged || acknowledged.version !== message.activePhoneCredentialVersion
        || !this.settings.promotePending(acknowledged)) {
        this.#terminate('failed', 'storage_failed', socket);
        return;
      }
      this.acknowledgedSlot = null;
      this.reference = null;
      if (await this.#activateTransport(acknowledged, { socket, generation })) {
        this.#retireSocket(socket, 1000, 'pairing_complete');
      }
    }
  }

  async #authenticate(slot) {
    try {
      return await this.authenticateCredential(slot) === true ? 'accepted' : 'rejected';
    } catch {
      return 'error';
    }
  }

  async #activateTransport(active, ownership) {
    if (!this.#owns(ownership)) return false;
    if (!active) {
      this.#failActivation('storage_failed', ownership);
      return false;
    }
    const previousActivation = this.#detachActivation();
    this.#abortActivation(previousActivation);
    if (!this.#owns(ownership)) return false;
    const activation = { controller: new AbortController(), ownership };
    this.activation = activation;
    try {
      if (await this.startTransport(active, activation.controller.signal) === false) {
        if (this.activation === activation) this.activation = null;
        if (this.#owns(ownership)) this.#failActivation('activation_failed', ownership);
        return false;
      }
    } catch {
      if (this.activation === activation) this.activation = null;
      if (this.#owns(ownership)) this.#failActivation('activation_failed', ownership);
      return false;
    }
    if (!this.#owns(ownership) || activation.controller.signal.aborted) return false;
    if (this.activation === activation) this.activation = null;
    this.#clearDeadline();
    this.#clearSensitive();
    this.#publish('active');
    return true;
  }

  #failActivation(reason, ownership) {
    if (ownership.socket) this.#terminate('failed', reason, ownership.socket);
    else {
      this.#clearSensitive();
      this.#publish('failed', reason);
    }
  }

  #send(socket, message) {
    socket.send(encodeMessage({ ...message, v: PROTOCOL_VERSION }));
  }

  #scheduleDeadline(socket, generation, phase, delay, reason) {
    this.#clearDeadline();
    const deadline = { generation, handle: null };
    this.deadlineTimer = deadline;
    deadline.handle = this.scheduler.setTimeout(() => {
      if (this.deadlineTimer !== deadline) return;
      this.deadlineTimer = null;
      if (this.#current(socket, generation) && this.phase === phase) {
        this.#terminate('failed', reason, socket);
      }
    }, Math.max(0, delay));
  }

  #clearDeadline() {
    if (this.deadlineTimer === null) return;
    const deadline = this.deadlineTimer;
    this.deadlineTimer = null;
    if (deadline.handle !== null) this.scheduler.clearTimeout(deadline.handle);
  }

  #terminate(phase, reason, socket) {
    const activation = this.#detachActivation();
    const terminalGeneration = ++this.generation;
    this.#clearDeadline();
    this.#clearSensitive();
    this.#retireSocket(socket);
    this.#abortActivation(activation);
    if (this.generation === terminalGeneration) this.#publish(phase, reason);
  }

  #clearSensitive() {
    this.reference = null;
    this.claimId = null;
    this.acknowledgedSlot = null;
    this.pairingExpiresAtUnixMs = null;
  }

  #detachActivation() {
    const activation = this.activation;
    this.activation = null;
    return activation;
  }

  #abortActivation(activation) {
    activation?.controller.abort();
  }

  #publish(phase, reason = null, details = {}) {
    this.phase = phase;
    this.onState({ phase, reason, ...details });
  }

  #current(socket, generation) {
    return this.socket === socket && this.generation === generation;
  }

  #owns({ socket, generation }) {
    return this.generation === generation && (socket === null || this.socket === socket);
  }

  #retireSocket(socket, code, reason) {
    if (this.socket === socket) this.socket = null;
    if (!socket) return;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onclose = null;
    socket.onerror = null;
    if (socket.readyState < 2) socket.close(code, reason);
  }
}
