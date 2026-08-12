// Canonical timing and size constants. Single source of truth for the relay,
// the phone PWA, and (mirrored by hand) the Swift client.

export const PROTOCOL_VERSION = 1;

export const MAX_MESSAGE_BYTES = 4096;
export const AUTH_TIMEOUT_MS = 5000;

export const HEARTBEAT_INTERVAL_MS = 20000;
export const HEARTBEAT_TIMEOUT_MS = 10000;
export const SERVER_PING_INTERVAL_MS = 30000;
export const SERVER_PONG_TIMEOUT_MS = 10000;

export const ACTION_LIFETIME_MS = 2000;
export const CLOCK_SKEW_TOLERANCE_MS = 1000;
export const CLOCK_HEALTH_SAMPLES = 3;
export const CLOCK_HEALTH_REFRESH_MS = 300000;

export const RELAY_PENDING_TTL_MS = 3000;
export const PHONE_RESULT_TIMEOUT_MS = 4000;

export const PHONE_RECONNECT_BASE_MS = 250;
export const PHONE_RECONNECT_CAP_MS = 8000;
export const MAC_RECONNECT_CAP_MS = 5000;

export const COMPLETED_ACTION_TTL_MS = 300000;
export const COMPLETED_ACTION_CAP = 4096;

export const DIRECT_LISTENER_PORT = 8787;
export const CLICK_GAP_MS = 0;
export const KEEPWARM_INTERVAL_MS = 5000;

export const TOKEN_HEX_LENGTH = 64;

export const ROLES = Object.freeze(['phone', 'mac']);
export const ACTIONS = Object.freeze(['click']);
export const INGRESSES = Object.freeze(['oci', 'tailscale']);

export const RELAY_ACK_STATUSES = Object.freeze([
  'forwarded',
  'mac_offline',
  'rejected',
]);

export const RESULT_STATUSES = Object.freeze(['posted', 'rejected']);

export const RESULT_REASONS = Object.freeze([
  'ok',
  'permission_required',
  'remote_disabled',
  'id_conflict',
  'expired',
  'capacity_exceeded',
  'event_creation_failed',
  'invalid_request',
]);

export const PERMISSION_STATES = Object.freeze(['ready', 'required', 'unknown']);

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
