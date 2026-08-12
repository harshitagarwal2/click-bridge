// Environment-neutral Click Bridge wire contract. This module deliberately
// uses only Web Platform APIs so the relay and the phone import the same strict
// parser instead of maintaining server/browser copies.

export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 4096;
export const ACTION_LIFETIME_MS = 2000;
export const TOKEN_HEX_LENGTH = 64;
export const PHONE_TAKEN_OVER_CLOSE_CODE = 4004;
export const PAIRING_VERSION = 1;
export const PAIRING_TTL_MS = 300_000;
export const LEGACY_PHONE_CREDENTIAL_VERSION = 0;
export const CREDENTIAL_REPLACED_CLOSE_CODE = 4004;
export const CREDENTIAL_REPLACED_CLOSE_REASON = 'credential_replaced';

export const ROLES = Object.freeze(['phone', 'mac']);
export const ACTIONS = Object.freeze(['click']);
export const INGRESSES = Object.freeze(['oci', 'tailscale']);
export const RELAY_ACK_STATUSES = Object.freeze(['forwarded', 'mac_offline', 'rejected']);
export const RESULT_STATUSES = Object.freeze(['posted', 'rejected']);
export const RESULT_REASONS = Object.freeze([
  'ok',
  'permission_required',
  'remote_disabled',
  'expired',
  'capacity_exceeded',
  'id_conflict',
  'event_creation_failed',
  'invalid_request',
]);
export const PERMISSION_STATES = Object.freeze(['ready', 'required', 'unknown']);
export const PAIRING_CLIENT_KINDS = Object.freeze(['ios', 'pwa']);
export const PAIRING_ENROLLMENT_STATES = Object.freeze(['legacy', 'paired']);
export const PAIRING_FAILURE_REASONS = Object.freeze([
  'expired',
  'used',
  'cancelled',
  'denied',
  'mac_offline',
  'storage_failed',
  'activation_failed',
  'invalid_request',
  'replaced',
  'unsupported',
]);

export class ProtocolError extends Error {
  constructor(code, detail) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = 'ProtocolError';
    this.code = code;
  }
}

const fail = (code, detail) => {
  throw new ProtocolError(code, detail);
};

const HEX64 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PAIRING_REFERENCE = /^[A-Za-z0-9_-]{43}$/;
const CONFIRMATION_CODE = /^[0-9]{3} [0-9]{3}$/;
const encoder = new TextEncoder();
const isPlainObject = (value) =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function snapshotOwnDataFields(value) {
  let descriptors;
  try {
    descriptors = Object.getOwnPropertyDescriptors(value);
  } catch {
    fail('invalid_field_descriptor');
  }

  const snapshot = Object.create(null);
  for (const [key, descriptor] of Object.entries(descriptors)) {
    if (!descriptor.enumerable) continue;
    if (!Object.hasOwn(descriptor, 'value')) fail('invalid_field_descriptor', key);
    snapshot[key] = descriptor.value;
  }
  return snapshot;
}

function requireExactFields(message, fields) {
  const allowed = new Set(fields);
  for (const key of Object.keys(message)) {
    if (!allowed.has(key)) fail('unknown_field', key);
  }
  for (const key of fields) {
    if (!Object.hasOwn(message, key)) fail('missing_field', key);
  }
}

function stringField(message, key) {
  const value = message[key];
  if (typeof value !== 'string') fail('invalid_type', key);
  return value;
}

function booleanField(message, key) {
  const value = message[key];
  if (typeof value !== 'boolean') fail('invalid_type', key);
  return value;
}

function numberField(message, key) {
  const value = message[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) fail('invalid_type', key);
  return value;
}

function nonNegativeIntegerField(message, key) {
  const value = numberField(message, key);
  if (!Number.isInteger(value) || value < 0) fail('invalid_value', key);
  return value;
}

function safeNonNegativeIntegerField(message, key) {
  const value = numberField(message, key);
  if (!Number.isSafeInteger(value) || value < 0) fail('invalid_value', key);
  return value;
}

function safePositiveIntegerField(message, key) {
  const value = safeNonNegativeIntegerField(message, key);
  if (value <= 0) fail('invalid_value', key);
  return value;
}

function positiveUnixMillisecondsField(message, key) {
  const value = safeNonNegativeIntegerField(message, key);
  if (value <= 0) fail('invalid_value', key);
  return value;
}

function enumField(message, key, values) {
  const value = stringField(message, key);
  if (!values.includes(value)) fail('invalid_value', `${key}=${value}`);
  return value;
}

function uuidField(message, key) {
  const value = stringField(message, key);
  if (!UUID.test(value)) fail('invalid_uuid', key);
  return value;
}

function referenceField(message, key = 'reference') {
  const value = stringField(message, key);
  if (!PAIRING_REFERENCE.test(value)) fail('invalid_reference', key);
  try {
    const decoded = atob(`${value.replaceAll('-', '+').replaceAll('_', '/')}=`);
    const canonical = btoa(decoded)
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replace(/=+$/, '');
    if (decoded.length !== 32 || canonical !== value) fail('invalid_reference', key);
  } catch (error) {
    if (error instanceof ProtocolError) throw error;
    fail('invalid_reference', key);
  }
  return value;
}

function hex64Field(message, key, errorCode) {
  const value = stringField(message, key);
  if (!HEX64.test(value)) fail(errorCode, key);
  return value;
}

function confirmationCodeField(message, key = 'confirmationCode') {
  const value = stringField(message, key);
  if (!CONFIRMATION_CODE.test(value)) fail('invalid_confirmation_code', key);
  return value;
}

function pairingVersionField(message) {
  const value = safeNonNegativeIntegerField(message, 'pairingVersion');
  if (value !== PAIRING_VERSION) fail('unsupported_pairing_version', 'pairingVersion');
  return value;
}

function validatePairFailed(message) {
  const hasRequest = Object.hasOwn(message, 'requestId');
  const hasClaim = Object.hasOwn(message, 'claimId');
  const fields = ['type', 'v'];
  if (hasRequest) fields.push('requestId');
  if (hasClaim) fields.push('claimId');
  fields.push('reason');
  requireExactFields(message, fields);
  if (!hasRequest && !hasClaim) fail('missing_field', 'requestId or claimId');
  if (hasRequest) uuidField(message, 'requestId');
  if (hasClaim) uuidField(message, 'claimId');
  enumField(message, 'reason', PAIRING_FAILURE_REASONS);
}

const TYPES = {
  hello: {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'role', 'token']);
      enumField(message, 'role', ROLES);
      const value = stringField(message, 'token');
      if (value.length !== TOKEN_HEX_LENGTH || !HEX64.test(value)) {
        fail('invalid_token_shape', 'token');
      }
    },
  },
  'hello.ok': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'role']);
      enumField(message, 'role', ROLES);
    },
  },
  'heartbeat.request': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'sequence']);
      nonNegativeIntegerField(message, 'sequence');
    },
  },
  'heartbeat.ack': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'sequence']);
      nonNegativeIntegerField(message, 'sequence');
    },
  },
  'time.sync.request': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'syncId', 'phoneSendUnixMs']);
      uuidField(message, 'syncId');
      if (numberField(message, 'phoneSendUnixMs') <= 0) {
        fail('invalid_value', 'phoneSendUnixMs');
      }
    },
  },
  'time.sync.response': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'syncId', 'phoneSendUnixMs', 'macReceiveUnixMs', 'macSendUnixMs',
      ]);
      uuidField(message, 'syncId');
      for (const key of ['phoneSendUnixMs', 'macReceiveUnixMs', 'macSendUnixMs']) {
        if (numberField(message, key) <= 0) fail('invalid_value', key);
      }
      if (message.macSendUnixMs < message.macReceiveUnixMs) {
        fail('invalid_value', 'macSendUnixMs before macReceiveUnixMs');
      }
    },
  },
  'diagnostics.request': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId']);
      uuidField(message, 'requestId');
    },
  },
  'diagnostics.counters': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'requestId', 'mouseDownPostCount', 'mouseUpPostCount',
      ]);
      uuidField(message, 'requestId');
      nonNegativeIntegerField(message, 'mouseDownPostCount');
      nonNegativeIntegerField(message, 'mouseUpPostCount');
    },
  },
  'mac.state': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'remoteEnabled', 'permission']);
      booleanField(message, 'remoteEnabled');
      enumField(message, 'permission', PERMISSION_STATES);
    },
  },
  state: {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'macOnline', 'remoteEnabled', 'permission']);
      booleanField(message, 'macOnline');
      booleanField(message, 'remoteEnabled');
      enumField(message, 'permission', PERMISSION_STATES);
    },
  },
  'action.request': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'actionId', 'action', 'issuedAtUnixMs', 'expiresAtUnixMs',
      ]);
      uuidField(message, 'actionId');
      enumField(message, 'action', ACTIONS);
      const issued = numberField(message, 'issuedAtUnixMs');
      const expires = numberField(message, 'expiresAtUnixMs');
      if (issued <= 0) fail('invalid_value', 'issuedAtUnixMs');
      if (expires - issued !== ACTION_LIFETIME_MS) {
        fail('invalid_lifetime', `${expires - issued} != ${ACTION_LIFETIME_MS}`);
      }
    },
  },
  'relay.ack': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'actionId', 'status', 'reason', 'relayProcessingUs',
      ]);
      uuidField(message, 'actionId');
      const status = enumField(message, 'status', RELAY_ACK_STATUSES);
      const reason = enumField(message, 'reason', ['ok', 'mac_offline', 'expired', 'invalid_request']);
      if (numberField(message, 'relayProcessingUs') < 0) {
        fail('invalid_value', 'relayProcessingUs');
      }
      const validPair =
        (status === 'forwarded' && reason === 'ok')
        || (status === 'mac_offline' && reason === 'mac_offline')
        || (status === 'rejected' && ['expired', 'invalid_request'].includes(reason));
      if (!validPair) fail('invalid_value', `status=${status},reason=${reason}`);
    },
  },
  'action.result': {
    validate(message) {
      const status = enumField(message, 'status', RESULT_STATUSES);
      const fields = [
        'type', 'v', 'actionId', 'status', 'reason', 'acceptedVia', 'macProcessingUs',
      ];
      if (status === 'posted') fields.push('mouseDownPostedUnixMs');
      requireExactFields(message, fields);
      uuidField(message, 'actionId');
      const reason = enumField(message, 'reason', RESULT_REASONS);
      enumField(message, 'acceptedVia', INGRESSES);
      if (numberField(message, 'macProcessingUs') < 0) fail('invalid_value', 'macProcessingUs');

      if (status === 'posted') {
        if (reason !== 'ok') fail('invalid_value', 'posted result must carry reason=ok');
        if (numberField(message, 'mouseDownPostedUnixMs') <= 0) {
          fail('invalid_value', 'mouseDownPostedUnixMs');
        }
      } else if (reason === 'ok') {
        fail('invalid_value', 'rejected result must not carry reason=ok');
      }
    },
  },
  'pair.create': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId', 'pairingVersion']);
      uuidField(message, 'requestId');
      pairingVersionField(message);
    },
  },
  'pair.status.request': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId', 'pairingVersion']);
      uuidField(message, 'requestId');
      pairingVersionField(message);
    },
  },
  'pair.created': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId', 'reference', 'expiresAtUnixMs']);
      uuidField(message, 'requestId');
      referenceField(message);
      positiveUnixMillisecondsField(message, 'expiresAtUnixMs');
    },
  },
  'pair.status': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'requestId', 'enrollmentState', 'activePhoneCredentialVersion',
      ]);
      uuidField(message, 'requestId');
      const enrollmentState = enumField(message, 'enrollmentState', PAIRING_ENROLLMENT_STATES);
      const credentialVersion = safeNonNegativeIntegerField(
        message,
        'activePhoneCredentialVersion',
      );
      if (enrollmentState === 'legacy' && credentialVersion !== LEGACY_PHONE_CREDENTIAL_VERSION) {
        fail('invalid_value', 'legacy enrollment must use credential version 0');
      }
      if (enrollmentState === 'paired' && credentialVersion <= LEGACY_PHONE_CREDENTIAL_VERSION) {
        fail('invalid_value', 'paired enrollment must use a rotated credential version');
      }
    },
  },
  'pair.cancel': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId']);
      uuidField(message, 'requestId');
    },
  },
  'pair.claim': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'reference', 'claimId', 'sessionNonce', 'pairingVersion', 'clientKind',
      ]);
      referenceField(message);
      uuidField(message, 'claimId');
      hex64Field(message, 'sessionNonce', 'invalid_nonce');
      pairingVersionField(message);
      enumField(message, 'clientKind', PAIRING_CLIENT_KINDS);
    },
  },
  'pair.claimed.mac': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'requestId', 'claimId', 'confirmationCode', 'expiresAtUnixMs', 'clientKind',
      ]);
      uuidField(message, 'requestId');
      uuidField(message, 'claimId');
      confirmationCodeField(message);
      positiveUnixMillisecondsField(message, 'expiresAtUnixMs');
      enumField(message, 'clientKind', PAIRING_CLIENT_KINDS);
    },
  },
  'pair.claimed.phone': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'claimId', 'confirmationCode', 'expiresAtUnixMs',
      ]);
      uuidField(message, 'claimId');
      confirmationCodeField(message);
      positiveUnixMillisecondsField(message, 'expiresAtUnixMs');
    },
  },
  'pair.approve': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId', 'claimId']);
      uuidField(message, 'requestId');
      uuidField(message, 'claimId');
    },
  },
  'pair.deny': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'requestId', 'claimId']);
      uuidField(message, 'requestId');
      uuidField(message, 'claimId');
    },
  },
  'pair.credential': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'claimId', 'credential', 'credentialVersion']);
      uuidField(message, 'claimId');
      hex64Field(message, 'credential', 'invalid_credential');
      safePositiveIntegerField(message, 'credentialVersion');
    },
  },
  'pair.credential.ack': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'claimId', 'credentialVersion', 'proof']);
      uuidField(message, 'claimId');
      safePositiveIntegerField(message, 'credentialVersion');
      hex64Field(message, 'proof', 'invalid_proof');
    },
  },
  'pair.active': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'claimId', 'activePhoneCredentialVersion']);
      uuidField(message, 'claimId');
      safePositiveIntegerField(message, 'activePhoneCredentialVersion');
    },
  },
  'pair.completed': {
    validate(message) {
      requireExactFields(message, [
        'type', 'v', 'requestId', 'claimId', 'activePhoneCredentialVersion',
      ]);
      uuidField(message, 'requestId');
      uuidField(message, 'claimId');
      safePositiveIntegerField(message, 'activePhoneCredentialVersion');
    },
  },
  'pair.cancel.claim': {
    validate(message) {
      requireExactFields(message, ['type', 'v', 'claimId']);
      uuidField(message, 'claimId');
    },
  },
  'pair.failed': { validate: validatePairFailed },
};

export const MESSAGE_TYPES = Object.freeze(Object.keys(TYPES));

const CLIENT_TYPES = Object.freeze({
  phone: new Set([
    'heartbeat.request', 'action.request', 'diagnostics.request', 'time.sync.request',
  ]),
  mac: new Set([
    'heartbeat.request', 'mac.state', 'action.result', 'diagnostics.counters',
    'time.sync.response', 'pair.status.request', 'pair.create', 'pair.cancel', 'pair.approve',
    'pair.deny',
  ]),
});

const PAIRING_STATE_TYPES = Object.freeze({
  'pairing.initial': new Set(['hello', 'pair.claim']),
  'pairing.claim': new Set(['pair.claim']),
  'pairing.claimed': new Set(['pair.credential.ack', 'pair.cancel.claim']),
});

const SERVER_TYPES = Object.freeze({
  phone: new Set([
    'hello.ok', 'heartbeat.ack', 'state', 'relay.ack', 'action.result',
    'diagnostics.counters', 'time.sync.response',
  ]),
  mac: new Set([
    'hello.ok', 'heartbeat.ack', 'action.request', 'diagnostics.request',
    'time.sync.request', 'pair.created', 'pair.status', 'pair.claimed.mac',
    'pair.completed', 'pair.failed',
  ]),
});

const PAIRING_SERVER_STATE_TYPES = Object.freeze({
  claiming: new Set(['pair.claimed.phone', 'pair.failed']),
  awaiting_credential: new Set(['pair.credential', 'pair.failed']),
  awaiting_activation: new Set(['pair.active', 'pair.failed']),
});

export const SERVER_MESSAGE_TYPES = Object.freeze([
  ...new Set([
    ...SERVER_TYPES.phone,
    ...SERVER_TYPES.mac,
    ...Object.values(PAIRING_SERVER_STATE_TYPES).flatMap((types) => [...types]),
  ]),
]);

function isBinaryFrame(raw) {
  return (typeof ArrayBuffer !== 'undefined' && raw instanceof ArrayBuffer)
    || (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(raw))
    || (typeof Blob !== 'undefined' && raw instanceof Blob);
}

function decodeEnvelope(raw) {
  if (typeof raw !== 'string') {
    if (isBinaryFrame(raw)) fail('binary_frame');
    fail('not_a_string');
  }
  if (encoder.encode(raw).byteLength > MAX_MESSAGE_BYTES) fail('message_too_large');

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    fail('malformed_json');
  }
  if (!isPlainObject(message)) fail('not_an_object');
  if (typeof message.type !== 'string') fail('missing_type');
  if (!Object.hasOwn(TYPES, message.type)) fail('unknown_type', message.type);
  if (message.v !== PROTOCOL_VERSION) fail('unsupported_version', 'v');
  return message;
}

function requireRole(role) {
  if (typeof role !== 'string' || !ROLES.includes(role)) {
    fail('invalid_role', 'authenticatedRole');
  }
}

export function parseClientMessage(raw, authenticatedRole = null) {
  const message = decodeEnvelope(raw);
  if (authenticatedRole !== null && typeof authenticatedRole !== 'string') {
    fail('invalid_role', 'authenticatedRole');
  }

  if (authenticatedRole === null) {
    if (message.type !== 'hello') fail('expected_hello', message.type);
  } else if (Object.hasOwn(PAIRING_STATE_TYPES, authenticatedRole)) {
    if (!PAIRING_STATE_TYPES[authenticatedRole].has(message.type)) {
      fail('message_not_allowed_for_state', `${message.type} in ${authenticatedRole}`);
    }
  } else {
    requireRole(authenticatedRole);
    if (message.type === 'hello') fail('already_authenticated');
    if (!CLIENT_TYPES[authenticatedRole].has(message.type)) {
      fail('message_not_allowed_for_role', `${message.type} from ${authenticatedRole}`);
    }
  }

  TYPES[message.type].validate(message);
  return message;
}

export function parseServerMessage(raw, authenticatedRole = 'phone') {
  const message = decodeEnvelope(raw);
  requireRole(authenticatedRole);
  if (!SERVER_TYPES[authenticatedRole].has(message.type)) {
    fail('message_not_allowed_for_role', `${message.type} to ${authenticatedRole}`);
  }
  if (message.type === 'hello.ok' && message.role !== authenticatedRole) {
    fail('message_not_allowed_for_role', 'hello.ok role mismatch');
  }
  if (message.type === 'pair.failed') {
    const hasRequest = Object.hasOwn(message, 'requestId');
    if ((authenticatedRole === 'mac') !== hasRequest) {
      fail('message_not_allowed_for_role', `pair.failed to ${authenticatedRole}`);
    }
  }
  TYPES[message.type].validate(message);
  return message;
}

export function parsePairingServerMessage(raw, context) {
  const message = decodeEnvelope(raw);
  if (!isPlainObject(context)) fail('invalid_pairing_context');
  const capturedContext = snapshotOwnDataFields(context);
  requireExactFields(capturedContext, [
    'state', 'claimId', 'generation', 'activeGeneration',
  ]);
  const state = enumField(capturedContext, 'state', Object.keys(PAIRING_SERVER_STATE_TYPES));
  uuidField(capturedContext, 'claimId');
  const generation = safeNonNegativeIntegerField(capturedContext, 'generation');
  const activeGeneration = safeNonNegativeIntegerField(capturedContext, 'activeGeneration');
  if (generation !== activeGeneration) fail('stale_generation');
  if (!PAIRING_SERVER_STATE_TYPES[state].has(message.type)) {
    fail('message_not_allowed_for_state', `${message.type} in ${state}`);
  }
  TYPES[message.type].validate(message);
  if (message.type === 'pair.failed' && Object.hasOwn(message, 'requestId')) {
    fail('message_not_allowed_for_role', 'pair.failed with requestId to claimant');
  }
  if (message.claimId !== capturedContext.claimId) fail('claim_mismatch');
  return message;
}

export function encodeMessage(message) {
  if (!isPlainObject(message)) fail('not_an_object');
  const capturedMessage = snapshotOwnDataFields(message);
  if (typeof capturedMessage.type !== 'string') fail('missing_type');
  if (!Object.hasOwn(TYPES, capturedMessage.type)) {
    fail('unknown_type', capturedMessage.type);
  }
  if (typeof capturedMessage.v !== 'number') fail('unsupported_version', 'v');
  if (capturedMessage.v !== PROTOCOL_VERSION) {
    fail('unsupported_version', 'v');
  }
  TYPES[capturedMessage.type].validate(capturedMessage);
  const raw = JSON.stringify(capturedMessage);
  if (encoder.encode(raw).byteLength > MAX_MESSAGE_BYTES) fail('message_too_large');
  return raw;
}

export function actionFingerprint(request) {
  return JSON.stringify([request.action, request.issuedAtUnixMs, request.expiresAtUnixMs]);
}

export function isExpired(request, nowUnixMs, toleranceMs) {
  return nowUnixMs > request.expiresAtUnixMs + toleranceMs;
}
