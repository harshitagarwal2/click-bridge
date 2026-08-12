// Relay server-only constants, plus verbatim re-exports of the two shared
// browser modules so server code has a single import site.
//
// This file is NOT the source of truth for anything the phone also needs.
// Protocol values live in public/wire-protocol.js and timing values in
// public/runtime-constants.js; the PWA imports those directly, so a second
// copy here would drift from the PWA with nothing to catch it. Re-export
// them — never redefine them.
//
// The Swift client mirrors both by hand. contracts/config/runtime-constants.json
// is what keeps that mirror honest; see relay/test/runtime-constants-parity.test.js.

import {
  PROTOCOL_VERSION,
  MAX_MESSAGE_BYTES,
  ACTION_LIFETIME_MS,
  TOKEN_HEX_LENGTH,
  AUTHENTICATION_REJECTED_CLOSE_CODE,
  PHONE_TAKEN_OVER_CLOSE_CODE,
  PAIRING_VERSION,
  PAIRING_TTL_MS,
  LEGACY_PHONE_CREDENTIAL_VERSION,
  CREDENTIAL_REPLACED_CLOSE_CODE,
  CREDENTIAL_REPLACED_CLOSE_REASON,
  ROLES,
  ACTIONS,
  INGRESSES,
  RELAY_ACK_STATUSES,
  RESULT_STATUSES,
  RESULT_REASONS,
  PERMISSION_STATES,
  PAIRING_CLIENT_KINDS,
  PAIRING_ENROLLMENT_STATES,
  PAIRING_FAILURE_REASONS,
} from '../public/wire-protocol.js';

import {
  HEARTBEAT_INTERVAL_MS,
  HEARTBEAT_TIMEOUT_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  CLOCK_HEALTH_SAMPLES,
  CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS,
  CLOCK_HEALTH_REFRESH_MS,
  PHONE_RESULT_TIMEOUT_MS,
  PHONE_RECONNECT_BASE_MS,
  PHONE_RECONNECT_CAP_MS,
  KEEPWARM_INTERVAL_MS,
} from '../public/runtime-constants.js';

export {
  HEARTBEAT_INTERVAL_MS,
  HEARTBEAT_TIMEOUT_MS,
  CLOCK_SKEW_TOLERANCE_MS,
  CLOCK_HEALTH_SAMPLES,
  CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS,
  CLOCK_HEALTH_REFRESH_MS,
  PHONE_RESULT_TIMEOUT_MS,
  PHONE_RECONNECT_BASE_MS,
  PHONE_RECONNECT_CAP_MS,
  KEEPWARM_INTERVAL_MS,
};

export {
  PROTOCOL_VERSION,
  MAX_MESSAGE_BYTES,
  ACTION_LIFETIME_MS,
  TOKEN_HEX_LENGTH,
  AUTHENTICATION_REJECTED_CLOSE_CODE,
  PHONE_TAKEN_OVER_CLOSE_CODE,
  PAIRING_VERSION,
  PAIRING_TTL_MS,
  LEGACY_PHONE_CREDENTIAL_VERSION,
  CREDENTIAL_REPLACED_CLOSE_CODE,
  CREDENTIAL_REPLACED_CLOSE_REASON,
  ROLES,
  ACTIONS,
  INGRESSES,
  RELAY_ACK_STATUSES,
  RESULT_STATUSES,
  RESULT_REASONS,
  PERMISSION_STATES,
  PAIRING_CLIENT_KINDS,
  PAIRING_ENROLLMENT_STATES,
  PAIRING_FAILURE_REASONS,
};

export const AUTH_TIMEOUT_MS = 5000;
export const MAX_TOTAL_WEBSOCKET_CONNECTIONS = 64;
export const MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS = 16;
export const TERMINAL_CLOSE_DEADLINE_MS = 250;

// Server-only. Nothing below is shared with the phone clients.
export const SERVER_PING_INTERVAL_MS = 30000;
export const SERVER_PONG_TIMEOUT_MS = 10000;

export const RELAY_PENDING_TTL_MS = 3000;
export const MAC_RECONNECT_CAP_MS = 5000;

export const COMPLETED_ACTION_TTL_MS = 300000;
export const COMPLETED_ACTION_CAP = 4096;

export const DIRECT_LISTENER_PORT = 8787;
export const CLICK_GAP_MS = 0;

// Invariants that must hold for the timing model to be coherent.
// Asserted by test/protocol.test.js so a bad edit fails loudly.
export const INVARIANTS = Object.freeze([
  ['action lifetime < relay pending TTL', ACTION_LIFETIME_MS < RELAY_PENDING_TTL_MS],
  ['relay pending TTL < phone result timeout', RELAY_PENDING_TTL_MS < PHONE_RESULT_TIMEOUT_MS],
  ['heartbeat timeout < heartbeat interval', HEARTBEAT_TIMEOUT_MS < HEARTBEAT_INTERVAL_MS],
  ['server pong timeout < server ping interval', SERVER_PONG_TIMEOUT_MS < SERVER_PING_INTERVAL_MS],
  ['clock health samples >= 1', CLOCK_HEALTH_SAMPLES >= 1],
  ['completed action cap > 0', COMPLETED_ACTION_CAP > 0],
]);
