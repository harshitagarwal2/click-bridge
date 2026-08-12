import { deriveRelayWebSocketUrl } from './relay-transport.js';
import { parseServerMessage } from './wire-protocol.js';

const PROTOCOL_VERSION = 1;
const PAIRING_VERSION = 1;
const REPLACED_CLOSE_CODE = 4004;
const HEX = /^[a-f0-9]{64}$/;

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
    this.socket = null;
    this.reference = null;
    this.claimId = null;
    this.acknowledgedSlot = null;
    this.generation = 0;
    this.phase = 'idle';
  }

  start(reference) {
    this.#retireSocket();
    const generation = ++this.generation;
    this.reference = reference;
    this.claimId = this.idGenerator();
    this.acknowledgedSlot = null;
    const sessionNonce = toHex(this.randomBytes());
    const socket = this.createSocket(deriveRelayWebSocketUrl(this.location));
    this.socket = socket;
    this.#publish('connecting');

    socket.onopen = () => {
      if (!this.#current(socket, generation)) return;
      socket.send(JSON.stringify({
        type: 'pair.claim',
        v: PROTOCOL_VERSION,
        reference: this.reference,
        claimId: this.claimId,
        sessionNonce,
        pairingVersion: PAIRING_VERSION,
        clientKind: 'pwa',
      }));
      this.reference = null;
      this.#publish('claiming');
    };
    socket.onmessage = (event) => {
      if (!this.#current(socket, generation)) return;
      void this.#receive(event.data, socket, generation);
    };
    socket.onclose = (event) => {
      if (!this.#current(socket, generation)) return;
      this.socket = null;
      this.reference = null;
      if (event.code === REPLACED_CLOSE_CODE) this.#publish('replaced');
      else if (!['active', 'failed', 'cancelled'].includes(this.phase)) this.#publish('failed', 'disconnected');
    };
    socket.onerror = () => {
      if (this.#current(socket, generation)) this.#publish('failed', 'connection_failed');
    };
  }

  cancel() {
    const socket = this.socket;
    if (socket?.readyState === 1 && this.claimId) {
      socket.send(JSON.stringify({
        type: 'pair.cancel.claim', v: PROTOCOL_VERSION, claimId: this.claimId,
      }));
    }
    this.generation += 1;
    this.reference = null;
    this.acknowledgedSlot = null;
    this.#retireSocket();
    this.#publish('cancelled');
  }

  async recover() {
    while (true) {
      const pending = this.settings.getPending();
      if (pending) {
        if (await this.#authenticates(pending)) {
          if (!this.settings.promotePending(pending)) {
            if (!sameSlot(this.settings.getPending(), pending)) continue;
            this.#publish('failed', 'storage_failed');
            return false;
          }
          return this.#activateTransport(pending);
        }
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
      if (await this.#authenticates(active)) {
        if (!sameSlot(this.settings.getActive(), active)) continue;
        return this.#activateTransport(active);
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
      this.#publish('failed', 'invalid_response');
      return;
    }
    if (!this.#current(socket, generation) || message.claimId !== this.claimId) return;

    if (message.type === 'pair.claimed.phone') {
      this.#publish('awaiting_approval', null, {
        confirmationCode: message.confirmationCode,
        expiresAtUnixMs: message.expiresAtUnixMs,
      });
      return;
    }
    if (message.type === 'pair.failed') {
      this.reference = null;
      this.#publish(message.reason === 'replaced' ? 'replaced' : 'failed', message.reason);
      return;
    }
    if (message.type === 'pair.credential') {
      const pending = { credential: message.credential, version: message.credentialVersion };
      if (!this.settings.stage(pending)) {
        this.#publish('failed', 'storage_failed');
        return;
      }
      let proof;
      try {
        proof = await activationProof(
          this.crypto, pending.credential, this.claimId, pending.version,
        );
      } catch {
        this.#publish('failed', 'activation_failed');
        return;
      }
      if (!this.#current(socket, generation)) return;
      if (!sameSlot(this.settings.getPending(), pending)) {
        this.#publish('failed', 'storage_failed');
        return;
      }
      this.acknowledgedSlot = pending;
      socket.send(JSON.stringify({
        type: 'pair.credential.ack',
        v: PROTOCOL_VERSION,
        claimId: this.claimId,
        credentialVersion: pending.version,
        proof,
      }));
      this.#publish('activating');
      return;
    }
    if (message.type === 'pair.active') {
      const acknowledged = this.acknowledgedSlot;
      if (!acknowledged || acknowledged.version !== message.activePhoneCredentialVersion
        || !this.settings.promotePending(acknowledged)) {
        this.#publish('failed', 'storage_failed');
        return;
      }
      this.acknowledgedSlot = null;
      this.reference = null;
      if (await this.#activateTransport(acknowledged)) {
        this.#retireSocket(1000, 'pairing_complete');
      }
    }
  }

  async #authenticates(slot) {
    try {
      return await this.authenticateCredential(slot) === true;
    } catch {
      return false;
    }
  }

  async #activateTransport(active) {
    if (!active) {
      this.#publish('failed', 'storage_failed');
      return false;
    }
    try {
      if (await this.startTransport(active) === false) {
        this.#publish('failed', 'activation_failed');
        return false;
      }
    } catch {
      this.#publish('failed', 'activation_failed');
      return false;
    }
    this.#publish('active');
    return true;
  }

  #publish(phase, reason = null, details = {}) {
    this.phase = phase;
    this.onState({ phase, reason, ...details });
  }

  #current(socket, generation) {
    return this.socket === socket && this.generation === generation;
  }

  #retireSocket(code, reason) {
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onclose = null;
    socket.onerror = null;
    if (socket.readyState < 2) socket.close(code, reason);
  }
}
