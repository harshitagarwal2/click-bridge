// Browser-safe validator for frames arriving FROM a server endpoint.
//
// Deliberately narrow: the phone only ever receives hello.ok, state,
// relay.ack, action.result, heartbeat.ack, and time.sync.response. Anything
// else — including a frame that merely looks close enough — is rejected so it
// can produce no UI or action side effect.
//
// test/browser-parity.test.js checks this agrees with src/protocol.js on every
// canonical fixture.

import { PROTOCOL_VERSION, MAX_MESSAGE_BYTES } from './constants-lite.js';

export class LiteProtocolError extends Error {
  constructor(code) {
    super(code);
    this.name = 'LiteProtocolError';
    this.code = code;
  }
}

const fail = (code) => { throw new LiteProtocolError(code); };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PERMISSIONS = ['ready', 'required', 'unknown'];
const ACK_STATUSES = ['forwarded', 'mac_offline', 'rejected'];
const RESULT_STATUSES = ['posted', 'rejected'];
const RESULT_REASONS = [
  'ok', 'permission_required', 'remote_disabled', 'id_conflict',
  'expired', 'capacity_exceeded', 'event_creation_failed', 'invalid_request',
];
const INGRESSES = ['oci', 'tailscale'];

const byteLength = (s) =>
  (typeof TextEncoder !== 'undefined'
    ? new TextEncoder().encode(s).length
    : Buffer.byteLength(s, 'utf8'));

const isObj = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);

function exact(m, fields) {
  const allowed = new Set(fields);
  for (const k of Object.keys(m)) if (!allowed.has(k)) fail('unknown_field');
  for (const k of fields) if (!(k in m)) fail('missing_field');
}
const bool = (m, k) => { if (typeof m[k] !== 'boolean') fail('invalid_type'); };
const finite = (m, k) => {
  if (typeof m[k] !== 'number' || !Number.isFinite(m[k])) fail('invalid_type');
};
const enumOf = (m, k, list) => {
  if (typeof m[k] !== 'string' || !list.includes(m[k])) fail('invalid_value');
};
const uuid = (m, k) => {
  if (typeof m[k] !== 'string' || !UUID.test(m[k])) fail('invalid_uuid');
};

const VALIDATORS = {
  'hello.ok'(m) {
    exact(m, ['type', 'v', 'role']);
    enumOf(m, 'role', ['phone', 'mac']);
  },
  'heartbeat.ack'(m) {
    exact(m, ['type', 'v', 'sequence']);
    finite(m, 'sequence');
    if (!Number.isInteger(m.sequence) || m.sequence < 0) fail('invalid_value');
  },
  state(m) {
    exact(m, ['type', 'v', 'macOnline', 'remoteEnabled', 'permission']);
    bool(m, 'macOnline');
    bool(m, 'remoteEnabled');
    enumOf(m, 'permission', PERMISSIONS);
  },
  'relay.ack'(m) {
    exact(m, ['type', 'v', 'actionId', 'status', 'relayProcessingUs']);
    uuid(m, 'actionId');
    enumOf(m, 'status', ACK_STATUSES);
    finite(m, 'relayProcessingUs');
    if (m.relayProcessingUs < 0) fail('invalid_value');
  },
  'action.result'(m) {
    exact(m, [
      'type', 'v', 'actionId', 'status', 'reason',
      'acceptedVia', 'macProcessingUs', 'mouseDownPostedUnixMs',
    ]);
    uuid(m, 'actionId');
    enumOf(m, 'status', RESULT_STATUSES);
    enumOf(m, 'reason', RESULT_REASONS);
    enumOf(m, 'acceptedVia', INGRESSES);
    finite(m, 'macProcessingUs');
    if (m.macProcessingUs < 0) fail('invalid_value');
    if (m.status === 'posted') {
      if (m.reason !== 'ok') fail('invalid_value');
      finite(m, 'mouseDownPostedUnixMs');
      if (m.mouseDownPostedUnixMs <= 0) fail('invalid_type');
    } else {
      if (m.reason === 'ok') fail('invalid_value');
      if (m.mouseDownPostedUnixMs !== null) fail('invalid_value');
    }
  },
  'time.sync.response'(m) {
    exact(m, ['type', 'v', 'syncId', 'phoneSendUnixMs', 'macReceiveUnixMs', 'macSendUnixMs']);
    uuid(m, 'syncId');
    for (const k of ['phoneSendUnixMs', 'macReceiveUnixMs', 'macSendUnixMs']) {
      finite(m, k);
      if (m[k] <= 0) fail('invalid_value');
    }
    if (m.macSendUnixMs < m.macReceiveUnixMs) fail('invalid_value');
  },
};

export const SERVER_MESSAGE_TYPES = Object.freeze(Object.keys(VALIDATORS));

export function parseServerMessage(raw) {
  if (typeof raw !== 'string') fail('not_a_string');
  if (byteLength(raw) > MAX_MESSAGE_BYTES) fail('message_too_large');

  let m;
  try {
    m = JSON.parse(raw);
  } catch {
    fail('malformed_json');
  }
  if (!isObj(m)) fail('not_an_object');
  if (typeof m.type !== 'string' || !(m.type in VALIDATORS)) fail('unknown_type');
  if (m.v !== PROTOCOL_VERSION) fail('unsupported_version');

  VALIDATORS[m.type](m);
  return m;
}
