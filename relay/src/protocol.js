// Strict wire-protocol validator.
//
// Layering rule (from the plan): the VALIDATOR is strict — any unknown type,
// unknown field, wrong version, or malformed value throws. The SERVER POLICY
// for an invalid message after authentication is to ignore it and continue;
// during authentication it closes. That policy lives in relay.js, not here.

import {
  PROTOCOL_VERSION,
  MAX_MESSAGE_BYTES,
  ACTION_LIFETIME_MS,
  TOKEN_HEX_LENGTH,
  ROLES,
  ACTIONS,
  INGRESSES,
  RELAY_ACK_STATUSES,
  RESULT_STATUSES,
  RESULT_REASONS,
  PERMISSION_STATES,
} from './constants.js';

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

const isPlainObject = (v) =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

function requireExactFields(msg, fields) {
  const allowed = new Set(fields);
  for (const key of Object.keys(msg)) {
    if (!allowed.has(key)) fail('unknown_field', key);
  }
  for (const key of fields) {
    if (!(key in msg)) fail('missing_field', key);
  }
}

function str(msg, key) {
  const v = msg[key];
  if (typeof v !== 'string') fail('invalid_type', key);
  return v;
}

function bool(msg, key) {
  const v = msg[key];
  if (typeof v !== 'boolean') fail('invalid_type', key);
  return v;
}

function num(msg, key) {
  const v = msg[key];
  if (typeof v !== 'number' || !Number.isFinite(v)) fail('invalid_type', key);
  return v;
}

function intNum(msg, key) {
  const v = num(msg, key);
  if (!Number.isInteger(v)) fail('invalid_type', key);
  return v;
}

function oneOf(msg, key, allowed) {
  const v = str(msg, key);
  if (!allowed.includes(v)) fail('invalid_value', `${key}=${v}`);
  return v;
}

function token(msg, key) {
  const v = str(msg, key);
  if (v.length !== TOKEN_HEX_LENGTH || !HEX64.test(v)) fail('invalid_token_shape', key);
  return v;
}

function uuid(msg, key) {
  const v = str(msg, key);
  if (!UUID.test(v)) fail('invalid_uuid', key);
  return v;
}

// ---------------------------------------------------------------------------
// Per-type validators. Each returns the validated message unchanged.
// `sender` is the role that is allowed to originate this type.
// ---------------------------------------------------------------------------

const TYPES = {
  hello: {
    sender: null, // pre-auth, either role
    validate(m) {
      requireExactFields(m, ['type', 'v', 'role', 'token']);
      oneOf(m, 'role', ROLES);
      token(m, 'token');
    },
  },

  'hello.ok': {
    sender: 'server',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'role']);
      oneOf(m, 'role', ROLES);
    },
  },

  'heartbeat.request': {
    sender: 'either',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'sequence']);
      const s = intNum(m, 'sequence');
      if (s < 0) fail('invalid_value', 'sequence');
    },
  },

  'heartbeat.ack': {
    sender: 'either',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'sequence']);
      const s = intNum(m, 'sequence');
      if (s < 0) fail('invalid_value', 'sequence');
    },
  },

  'mac.state': {
    sender: 'mac',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'remoteEnabled', 'permission']);
      bool(m, 'remoteEnabled');
      oneOf(m, 'permission', PERMISSION_STATES);
    },
  },

  state: {
    sender: 'server',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'macOnline', 'remoteEnabled', 'permission']);
      bool(m, 'macOnline');
      bool(m, 'remoteEnabled');
      oneOf(m, 'permission', PERMISSION_STATES);
    },
  },

  'action.request': {
    sender: 'phone',
    validate(m) {
      requireExactFields(m, [
        'type', 'v', 'actionId', 'action', 'issuedAtUnixMs', 'expiresAtUnixMs',
      ]);
      uuid(m, 'actionId');
      oneOf(m, 'action', ACTIONS);
      const issued = num(m, 'issuedAtUnixMs');
      const expires = num(m, 'expiresAtUnixMs');
      if (issued <= 0) fail('invalid_value', 'issuedAtUnixMs');
      if (expires - issued !== ACTION_LIFETIME_MS) {
        fail('invalid_lifetime', `${expires - issued} != ${ACTION_LIFETIME_MS}`);
      }
    },
  },

  'relay.ack': {
    sender: 'server',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'actionId', 'status', 'relayProcessingUs']);
      uuid(m, 'actionId');
      oneOf(m, 'status', RELAY_ACK_STATUSES);
      const us = num(m, 'relayProcessingUs');
      if (us < 0) fail('invalid_value', 'relayProcessingUs');
    },
  },

  'action.result': {
    sender: 'mac',
    validate(m) {
      requireExactFields(m, [
        'type', 'v', 'actionId', 'status', 'reason',
        'acceptedVia', 'macProcessingUs', 'mouseDownPostedUnixMs',
      ]);
      uuid(m, 'actionId');
      const status = oneOf(m, 'status', RESULT_STATUSES);
      const reason = oneOf(m, 'reason', RESULT_REASONS);
      oneOf(m, 'acceptedVia', INGRESSES);
      const us = num(m, 'macProcessingUs');
      if (us < 0) fail('invalid_value', 'macProcessingUs');

      if (status === 'posted' && reason !== 'ok') {
        fail('invalid_value', 'posted result must carry reason=ok');
      }
      if (status === 'rejected' && reason === 'ok') {
        fail('invalid_value', 'rejected result must not carry reason=ok');
      }
      // Only a posted result may report a real post timestamp.
      const posted = m.mouseDownPostedUnixMs;
      if (status === 'posted') {
        if (typeof posted !== 'number' || !Number.isFinite(posted) || posted <= 0) {
          fail('invalid_type', 'mouseDownPostedUnixMs');
        }
      } else if (posted !== null) {
        fail('invalid_value', 'rejected result must carry null mouseDownPostedUnixMs');
      }
    },
  },

  'time.sync.request': {
    sender: 'phone',
    validate(m) {
      requireExactFields(m, ['type', 'v', 'syncId', 'phoneSendUnixMs']);
      uuid(m, 'syncId');
      if (num(m, 'phoneSendUnixMs') <= 0) fail('invalid_value', 'phoneSendUnixMs');
    },
  },

  'time.sync.response': {
    sender: 'mac',
    validate(m) {
      requireExactFields(m, [
        'type', 'v', 'syncId', 'phoneSendUnixMs', 'macReceiveUnixMs', 'macSendUnixMs',
      ]);
      uuid(m, 'syncId');
      if (num(m, 'phoneSendUnixMs') <= 0) fail('invalid_value', 'phoneSendUnixMs');
      const r = num(m, 'macReceiveUnixMs');
      const s = num(m, 'macSendUnixMs');
      if (r <= 0 || s <= 0) fail('invalid_value', 'mac timestamps');
      if (s < r) fail('invalid_value', 'macSendUnixMs before macReceiveUnixMs');
    },
  },
};

export const MESSAGE_TYPES = Object.freeze(Object.keys(TYPES));

function decodeEnvelope(raw) {
  if (typeof raw !== 'string') {
    if (raw instanceof Uint8Array || Buffer.isBuffer?.(raw)) {
      fail('binary_frame');
    }
    fail('not_a_string');
  }
  if (Buffer.byteLength(raw, 'utf8') > MAX_MESSAGE_BYTES) fail('message_too_large');

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail('malformed_json');
  }
  if (!isPlainObject(parsed)) fail('not_an_object');
  if (typeof parsed.type !== 'string') fail('missing_type');
  if (!(parsed.type in TYPES)) fail('unknown_type', parsed.type);
  if (parsed.v !== PROTOCOL_VERSION) fail('unsupported_version', String(parsed.v));
  return parsed;
}

/**
 * Validate a frame arriving at a server endpoint (relay or direct listener).
 * @param {string} raw
 * @param {'phone'|'mac'|null} authenticatedRole  null means pre-authentication
 */
export function parseClientMessage(raw, authenticatedRole = null) {
  const msg = decodeEnvelope(raw);
  const spec = TYPES[msg.type];

  if (authenticatedRole === null) {
    if (msg.type !== 'hello') fail('expected_hello', msg.type);
  } else if (msg.type === 'hello') {
    fail('already_authenticated');
  } else if (spec.sender === 'server') {
    fail('message_not_allowed_for_role', msg.type);
  } else if (spec.sender !== 'either' && spec.sender !== authenticatedRole) {
    fail('message_not_allowed_for_role', `${msg.type} from ${authenticatedRole}`);
  }

  spec.validate(msg);
  return msg;
}

/** Validate a frame arriving at a client (phone or Mac) from a server endpoint. */
export function parseServerMessage(raw) {
  const msg = decodeEnvelope(raw);
  TYPES[msg.type].validate(msg);
  return msg;
}

export function encodeMessage(msg) {
  if (!isPlainObject(msg)) fail('not_an_object');
  if (!(msg.type in TYPES)) fail('unknown_type', String(msg.type));
  if (msg.v !== PROTOCOL_VERSION) fail('unsupported_version', String(msg.v));
  TYPES[msg.type].validate(msg);
  const raw = JSON.stringify(msg);
  if (Buffer.byteLength(raw, 'utf8') > MAX_MESSAGE_BYTES) fail('message_too_large');
  return raw;
}

/**
 * Deterministic fingerprint of an action request, EXCLUDING actionId.
 * Two requests sharing an actionId but differing here are an id_conflict.
 */
export function actionFingerprint(req) {
  return JSON.stringify([req.action, req.issuedAtUnixMs, req.expiresAtUnixMs]);
}

/** True when `nowUnixMs` is past the request deadline plus the skew allowance. */
export function isExpired(req, nowUnixMs, toleranceMs) {
  return nowUnixMs > req.expiresAtUnixMs + toleranceMs;
}
