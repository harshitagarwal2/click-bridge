// Environment-neutral Click Bridge wire contract. This module deliberately
// uses only Web Platform APIs so the relay and the phone import the same strict
// parser instead of maintaining server/browser copies.

export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 4096;
export const ACTION_LIFETIME_MS = 2000;
export const TOKEN_HEX_LENGTH = 64;

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
const encoder = new TextEncoder();
const isPlainObject = (value) =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function requireExactFields(message, fields) {
  const allowed = new Set(fields);
  for (const key of Object.keys(message)) {
    if (!allowed.has(key)) fail('unknown_field', key);
  }
  for (const key of fields) {
    if (!(key in message)) fail('missing_field', key);
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
};

export const MESSAGE_TYPES = Object.freeze(Object.keys(TYPES));

const CLIENT_TYPES = Object.freeze({
  phone: new Set([
    'heartbeat.request', 'action.request', 'diagnostics.request', 'time.sync.request',
  ]),
  mac: new Set([
    'heartbeat.request', 'mac.state', 'action.result', 'diagnostics.counters',
    'time.sync.response',
  ]),
});

const SERVER_TYPES = Object.freeze({
  phone: new Set([
    'hello.ok', 'heartbeat.ack', 'state', 'relay.ack', 'action.result',
    'diagnostics.counters', 'time.sync.response',
  ]),
  mac: new Set([
    'hello.ok', 'heartbeat.ack', 'action.request', 'diagnostics.request',
    'time.sync.request',
  ]),
});

export const SERVER_MESSAGE_TYPES = Object.freeze([
  ...new Set([...SERVER_TYPES.phone, ...SERVER_TYPES.mac]),
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
  if (!(message.type in TYPES)) fail('unknown_type', message.type);
  if (message.v !== PROTOCOL_VERSION) fail('unsupported_version', String(message.v));
  return message;
}

function requireRole(role) {
  if (!ROLES.includes(role)) fail('invalid_role', String(role));
}

export function parseClientMessage(raw, authenticatedRole = null) {
  const message = decodeEnvelope(raw);

  if (authenticatedRole === null) {
    if (message.type !== 'hello') fail('expected_hello', message.type);
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
  if (authenticatedRole !== null) {
    requireRole(authenticatedRole);
    if (!SERVER_TYPES[authenticatedRole].has(message.type)) {
      fail('message_not_allowed_for_role', `${message.type} to ${authenticatedRole}`);
    }
    if (message.type === 'hello.ok' && message.role !== authenticatedRole) {
      fail('message_not_allowed_for_role', `hello.ok for ${message.role}`);
    }
  }
  TYPES[message.type].validate(message);
  return message;
}

export function encodeMessage(message) {
  if (!isPlainObject(message)) fail('not_an_object');
  if (typeof message.type !== 'string' || !(message.type in TYPES)) {
    fail('unknown_type', String(message.type));
  }
  if (message.v !== PROTOCOL_VERSION) fail('unsupported_version', String(message.v));
  TYPES[message.type].validate(message);
  const raw = JSON.stringify(message);
  if (encoder.encode(raw).byteLength > MAX_MESSAGE_BYTES) fail('message_too_large');
  return raw;
}

export function actionFingerprint(request) {
  return JSON.stringify([request.action, request.issuedAtUnixMs, request.expiresAtUnixMs]);
}

export function isExpired(request, nowUnixMs, toleranceMs) {
  return nowUnixMs > request.expiresAtUnixMs + toleranceMs;
}
