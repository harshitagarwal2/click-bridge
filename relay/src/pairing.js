import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

import {
  PAIRING_TTL_MS,
  PROTOCOL_VERSION,
} from './constants.js';
import { AUTH_STORE_ERROR_CODES, AuthStoreError } from './auth-store.js';

const ACTIVATION_CONTEXT = 'clickbridge-pair-activate:v1';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sameHex(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string'
      || left.length !== right.length || !/^[0-9a-f]+$/.test(left)
      || !/^[0-9a-f]+$/.test(right)) {
    return false;
  }
  return timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

function invitationVerifier(reference) {
  if (typeof reference !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(reference)) return null;
  const bytes = Buffer.from(reference, 'base64url');
  return bytes.length === 32 && bytes.toString('base64url') === reference ? sha256(bytes) : null;
}

function failureForMac(session, reason) {
  const message = {
    type: 'pair.failed',
    v: PROTOCOL_VERSION,
    requestId: session.requestId,
  };
  if (session.claimId) message.claimId = session.claimId;
  message.reason = reason;
  return message;
}

function failureForClaimant(claimId, reason) {
  return { type: 'pair.failed', v: PROTOCOL_VERSION, claimId, reason };
}

export class PairingCoordinator {
  #enabled;
  #now;
  #randomBytes;
  #randomInt;
  #scheduler;
  #authStore;
  #emit;
  #log;
  #mac = null;
  #session = null;
  #completed = null;
  #ended = null;

  constructor({
    enabled = true,
    now,
    randomBytes,
    randomInt,
    scheduler,
    authStore,
    emit,
    log = () => {},
  }) {
    this.#enabled = enabled;
    this.#now = now;
    this.#randomBytes = randomBytes;
    this.#randomInt = randomInt;
    this.#scheduler = scheduler;
    this.#authStore = authStore;
    this.#emit = emit;
    this.#log = log;
  }

  macConnected(connection, generation) {
    if (!this.#enabled) return 'unsupported';
    if (this.#mac && !this.#owns(this.#mac, connection, generation)) {
      if (this.#isActivating()) {
        this.#mac = { connection, generation, pairingCapable: false };
        return 'activation_in_progress';
      }
      this.#terminate('replaced');
    }
    this.#mac = { connection, generation, pairingCapable: false };
    return 'ok';
  }

  requestStatus(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    const snapshot = this.#authStore.snapshot();
    const credentialVersion = snapshot.activePhoneCredentialVersion;
    if (!Number.isSafeInteger(credentialVersion) || credentialVersion < 0) {
      return 'invalid_state';
    }
    this.#mac.pairingCapable = true;
    this.#send(connection, {
      type: 'pair.status',
      v: PROTOCOL_VERSION,
      requestId: message.requestId,
      enrollmentState: credentialVersion === 0 ? 'legacy' : 'paired',
      activePhoneCredentialVersion: credentialVersion,
    });
    return 'ok';
  }

  macDisconnected(connection, generation) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    this.#mac = null;
    if (this.#isActivating()) return 'activation_in_progress';
    this.#terminate('mac_offline');
    return 'ok';
  }

  create(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    if (!this.#mac.pairingCapable) return 'capability_required';
    if (this.#isActivating()) return 'activation_in_progress';
    if (this.#completed && !this.#completed.reconciled) return 'activation_in_progress';
    if (this.#session && this.#expired(this.#session)) {
      this.#terminate('expired');
    }
    if (this.#session?.requestId === message.requestId
        && this.#owns(this.#session.mac, connection, generation)) {
      return 'ok';
    }
    if (this.#session) this.#terminate('replaced');
    this.#completed = null;
    this.#ended = null;

    const invitation = this.#randomBytes(32);
    if (!Buffer.isBuffer(invitation) || invitation.length !== 32) {
      throw new TypeError('randomBytes must return 32 bytes');
    }
    const reference = invitation.toString('base64url');
    if (invitationVerifier(reference) !== sha256(invitation)) {
      throw new TypeError('randomBytes produced a non-canonical invitation');
    }
    const expiresAtUnixMs = this.#now() + PAIRING_TTL_MS;
    if (!this.#send(connection, {
      type: 'pair.created',
      v: PROTOCOL_VERSION,
      requestId: message.requestId,
      reference,
      expiresAtUnixMs,
    })) {
      this.#log('pairing_invitation_delivery_failed');
      return 'delivery_failed';
    }

    const session = {
      requestId: message.requestId,
      verifier: sha256(invitation),
      expiresAtUnixMs,
      mac: { connection, generation },
      timer: null,
      claimId: null,
      claimVerifier: null,
      claimant: null,
      sessionNonce: null,
      clientKind: null,
      confirmationCode: null,
      pendingCredential: null,
      pendingVerifier: null,
      expectedVersion: null,
      credentialVersion: null,
      activationPromise: null,
    };
    session.timer = this.#scheduler.setTimeout(() => {
      if (this.#session === session) this.#terminate('expired');
    }, PAIRING_TTL_MS);
    this.#session = session;
    return 'ok';
  }

  claim(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    const session = this.#session;
    const verifier = invitationVerifier(message.reference);
    if (session && this.#expired(session)) {
      const wasClaimant = this.#owns(session.claimant, connection, generation);
      this.#terminate('expired');
      if (!wasClaimant) this.#send(connection, failureForClaimant(message.claimId, 'expired'));
      return 'expired';
    }
    if (session?.claimId) {
      const duplicate = session.claimId === message.claimId
        && session.sessionNonce === message.sessionNonce
        && verifier !== null
        && sameHex(verifier, session.claimVerifier)
        && this.#owns(session.claimant, connection, generation);
      if (duplicate) {
        if (session.activationPromise) return 'activation_in_progress';
        if (session.pendingCredential) this.#sendCredential(session);
        else this.#sendClaimed(session);
        return 'ok';
      }
      this.#send(connection, failureForClaimant(message.claimId, 'used'));
      return 'used';
    }
    if (!session || !verifier || !sameHex(verifier, session.verifier)) {
      this.#send(connection, failureForClaimant(message.claimId, 'used'));
      return 'used';
    }
    const confirmation = this.#randomInt(1_000_000);
    if (!Number.isSafeInteger(confirmation) || confirmation < 0 || confirmation >= 1_000_000) {
      throw new RangeError('randomInt returned an invalid confirmation value');
    }
    session.claimId = message.claimId;
    session.claimVerifier = verifier;
    session.claimant = { connection, generation };
    session.sessionNonce = message.sessionNonce;
    session.clientKind = message.clientKind;
    session.confirmationCode = String(confirmation).padStart(6, '0').replace(/^(...)/, '$1 ');
    this.#sendClaimed(session);
    return 'ok';
  }

  approve(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    if (!this.#mac.pairingCapable) return 'capability_required';
    const session = this.#session;
    if (!session || !this.#matchesClaim(session, message)) return 'invalid_request';
    if (this.#expired(session)) {
      this.#terminate('expired');
      return 'expired';
    }
    if (session.activationPromise) return 'activation_in_progress';
    if (session.pendingCredential) {
      this.#sendCredential(session);
      return 'ok';
    }

    const credential = this.#randomBytes(32);
    if (!Buffer.isBuffer(credential) || credential.length !== 32) {
      throw new TypeError('randomBytes must return 32 bytes');
    }
    const snapshot = this.#authStore.snapshot();
    if (!Number.isSafeInteger(snapshot.activePhoneCredentialVersion)
        || snapshot.activePhoneCredentialVersion < 0
        || snapshot.activePhoneCredentialVersion === Number.MAX_SAFE_INTEGER) {
      this.#terminate('activation_failed');
      return 'activation_failed';
    }
    session.verifier = null;
    session.confirmationCode = null;
    session.pendingCredential = credential.toString('hex');
    session.pendingVerifier = sha256(credential);
    session.expectedVersion = snapshot.activePhoneCredentialVersion;
    session.credentialVersion = snapshot.activePhoneCredentialVersion + 1;
    this.#sendCredential(session);
    return 'ok';
  }

  deny(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    if (!this.#mac.pairingCapable) return 'capability_required';
    if (this.#isActivating()) return 'activation_in_progress';
    if (this.#matchesEndedMac(message, 'denied', true)) return 'ok';
    if (!this.#session || !this.#matchesClaim(this.#session, message)) return 'invalid_request';
    this.#terminate('denied');
    return 'ok';
  }

  cancelByMac(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (!this.#owns(this.#mac, connection, generation)) return 'ignored';
    if (!this.#mac.pairingCapable) return 'capability_required';
    if (this.#isActivating()) return 'activation_in_progress';
    if (this.#matchesEndedMac(message, 'cancelled', false)) return 'ok';
    if (!this.#session || this.#session.requestId !== message.requestId) return 'invalid_request';
    this.#terminate('cancelled', {
      source: 'mac_frame',
      phase: this.#phase(this.#session),
    });
    return 'ok';
  }

  cancelByClaimant(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (this.#ended?.reason === 'cancelled' && this.#ended.claimId === message.claimId
        && this.#owns(this.#ended.claimant, connection, generation)) {
      return 'ok';
    }
    if (this.#isActivating()
        && this.#owns(this.#session.claimant, connection, generation)
        && this.#session.claimId === message.claimId) {
      return 'activation_in_progress';
    }
    if (!this.#session || this.#session.claimId !== message.claimId
        || !this.#owns(this.#session.claimant, connection, generation)) {
      return 'ignored';
    }
    this.#terminate('cancelled', {
      source: 'claimant_frame',
      phase: this.#phase(this.#session),
    });
    return 'ok';
  }

  async acknowledge(connection, generation, message) {
    if (!this.#enabled) return 'unsupported';
    if (this.#completed && this.#completed.claimId === message.claimId
        && this.#completed.credentialVersion === message.credentialVersion
        && this.#owns(this.#completed.claimant, connection, generation)) {
      if (!this.#completed.reconciled && !this.#reconcileCompletion(this.#completed)) {
        return 'reconciliation_failed';
      }
      this.#sendCompleted(this.#completed);
      return 'ok';
    }

    const session = this.#session;
    if (!session || !this.#owns(session.claimant, connection, generation)) return 'ignored';
    if (this.#expired(session)) {
      this.#terminate('expired');
      return 'expired';
    }
    if (message.claimId !== session.claimId || message.credentialVersion !== session.credentialVersion
        || !session.pendingCredential) {
      return 'invalid_request';
    }
    if (session.activationPromise) return session.activationPromise;
    const expectedProof = createHmac('sha256', Buffer.from(session.pendingCredential, 'hex'))
      .update(`${ACTIVATION_CONTEXT}:${session.claimId}:${session.credentialVersion}`, 'utf8')
      .digest('hex');
    if (!sameHex(message.proof, expectedProof)) {
      this.#terminate('activation_failed');
      return 'activation_failed';
    }
    this.#clearTimer(session);
    session.activationPromise = this.#activate(session);
    return session.activationPromise;
  }

  disconnectClaimant(connection, generation) {
    if (!this.#enabled) return 'unsupported';
    if (this.#ended?.reason === 'cancelled'
        && this.#owns(this.#ended.claimant, connection, generation)) {
      return 'ok';
    }
    if (this.#isActivating() && this.#owns(this.#session.claimant, connection, generation)) {
      return 'activation_in_progress';
    }
    if (!this.#session || !this.#owns(this.#session.claimant, connection, generation)) {
      return 'ignored';
    }
    this.#terminate('cancelled', {
      source: 'claimant_disconnect',
      phase: this.#phase(this.#session),
    });
    return 'ok';
  }

  async #activate(session) {
    try {
      await this.#authStore.activate({
        expectedVersion: session.expectedVersion,
        credentialVersion: session.credentialVersion,
        verifier: session.pendingVerifier,
      });
    } catch (error) {
      const reason = error instanceof AuthStoreError
          && (error.code === AUTH_STORE_ERROR_CODES.VERSION_CONFLICT
          || error.code === AUTH_STORE_ERROR_CODES.NEXT_VERSION_INVALID
          || error.code === AUTH_STORE_ERROR_CODES.INVALID_INPUT)
        ? 'activation_failed'
        : 'storage_failed';
      if (this.#session === session) this.#terminate(reason);
      return reason;
    }
    if (this.#session !== session) return 'ignored';

    const completed = {
      requestId: session.requestId,
      claimId: session.claimId,
      credentialVersion: session.credentialVersion,
      claimant: session.claimant,
      reconciled: false,
    };
    this.#clearTimer(session);
    this.#session = null;
    this.#completed = completed;
    this.#ended = null;
    this.#clearSecrets(session);
    if (!this.#reconcileCompletion(completed)) return 'reconciliation_failed';
    this.#sendCompleted(completed);
    return 'ok';
  }

  // Additive pairing: a new phone credential is committed alongside every
  // existing one, so there is nothing here to revoke or close. This step
  // stays in place (rather than being inlined at the call site) purely to
  // preserve the idempotent-retry contract acknowledge() depends on: a
  // retried ack after this returns true re-sends pair.completed instead of
  // re-running activation.
  #reconcileCompletion(completed) {
    completed.reconciled = true;
    return true;
  }

  #sendCompleted(completed) {
    this.#send(completed.claimant.connection, {
      type: 'pair.active',
      v: PROTOCOL_VERSION,
      claimId: completed.claimId,
      activePhoneCredentialVersion: completed.credentialVersion,
    });
    if (this.#mac?.connection && this.#mac.pairingCapable) {
      this.#send(this.#mac.connection, {
        type: 'pair.completed',
        v: PROTOCOL_VERSION,
        requestId: completed.requestId,
        claimId: completed.claimId,
        activePhoneCredentialVersion: completed.credentialVersion,
      });
    }
  }

  #sendClaimed(session) {
    this.#send(session.claimant.connection, {
      type: 'pair.claimed.phone',
      v: PROTOCOL_VERSION,
      claimId: session.claimId,
      confirmationCode: session.confirmationCode,
      expiresAtUnixMs: session.expiresAtUnixMs,
    });
    if (this.#owns(this.#mac, session.mac.connection, session.mac.generation)) {
      this.#send(session.mac.connection, {
        type: 'pair.claimed.mac',
        v: PROTOCOL_VERSION,
        requestId: session.requestId,
        claimId: session.claimId,
        confirmationCode: session.confirmationCode,
        expiresAtUnixMs: session.expiresAtUnixMs,
        clientKind: session.clientKind,
      });
    }
  }

  #sendCredential(session) {
    if (this.#owns(session.claimant, session.claimant.connection, session.claimant.generation)) {
      this.#send(session.claimant.connection, {
        type: 'pair.credential',
        v: PROTOCOL_VERSION,
        claimId: session.claimId,
        credential: session.pendingCredential,
        credentialVersion: session.credentialVersion,
      });
    }
  }

  #matchesClaim(session, message) {
    return session.requestId === message.requestId && session.claimId === message.claimId
      && this.#owns(this.#mac, session.mac.connection, session.mac.generation);
  }

  #matchesEndedMac(message, reason, requireClaim) {
    return this.#ended?.reason === reason
      && this.#ended.requestId === message.requestId
      && (!requireClaim || this.#ended.claimId === message.claimId)
      && this.#owns(this.#ended.mac, this.#mac.connection, this.#mac.generation);
  }

  #terminate(reason, details = {}) {
    const session = this.#session;
    if (!session) return false;
    const mac = session.mac;
    const claimant = session.claimant;
    const macFailure = failureForMac(session, reason);
    const claimantFailure = session.claimId ? failureForClaimant(session.claimId, reason) : null;
    this.#clearTimer(session);
    this.#session = null;
    this.#ended = {
      reason,
      requestId: session.requestId,
      claimId: session.claimId,
      mac,
      claimant,
    };
    this.#clearSecrets(session);
    if (claimantFailure && claimant) this.#send(claimant.connection, claimantFailure);
    if (mac && this.#owns(this.#mac, mac.connection, mac.generation)) {
      this.#send(mac.connection, macFailure);
    }
    this.#log('pairing_terminated', { reason, ...details });
    return true;
  }

  #clearTimer(session) {
    if (session.timer !== null) {
      this.#scheduler.clearTimeout(session.timer);
      session.timer = null;
    }
  }

  #clearSecrets(session) {
    session.verifier = null;
    session.claimVerifier = null;
    session.sessionNonce = null;
    session.confirmationCode = null;
    session.pendingCredential = null;
    session.pendingVerifier = null;
    session.activationPromise = null;
  }

  #expired(session) {
    return this.#now() >= session.expiresAtUnixMs;
  }

  #isActivating() {
    return this.#session?.activationPromise != null;
  }

  #phase(session) {
    if (!session) return 'idle';
    if (session.activationPromise) return 'activating';
    if (session.pendingCredential) return 'awaiting_activation';
    if (session.claimId) return 'awaiting_approval';
    return 'invited';
  }

  observe() {
    const session = this.#session;
    const phase = session
      ? this.#phase(session)
      : (this.#completed ? (this.#completed.reconciled ? 'completed' : 'committed') : 'idle');
    return Object.freeze({
      phase,
      requestId: session?.requestId ?? this.#completed?.requestId ?? null,
      claimId: session?.claimId ?? this.#completed?.claimId ?? null,
      expiresAtUnixMs: session?.expiresAtUnixMs ?? null,
      hasInvitationVerifier: Boolean(session?.verifier),
      hasPendingCredential: Boolean(session?.pendingCredential),
    });
  }

  #owns(owner, connection, generation) {
    return owner?.connection === connection && owner?.generation === generation;
  }

  #send(connection, message) {
    if (!connection) return false;
    try {
      return this.#emit(connection, Object.freeze(message)) !== false;
    } catch {
      this.#log('pairing_emit_failed', { type: message.type });
      return false;
    }
  }
}
