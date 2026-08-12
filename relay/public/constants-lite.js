// Browser-side mirror of src/constants.js.
//
// The relay serves only public/, so the browser cannot import src/. These
// values are duplicated deliberately and test/browser-parity.test.js asserts
// they are identical to the server's — drift fails the suite.

export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 4096;

export const HEARTBEAT_INTERVAL_MS = 20000;
export const HEARTBEAT_TIMEOUT_MS = 10000;

export const ACTION_LIFETIME_MS = 2000;
export const CLOCK_SKEW_TOLERANCE_MS = 1000;
export const CLOCK_HEALTH_SAMPLES = 3;
export const CLOCK_HEALTH_REFRESH_MS = 300000;

export const PHONE_RESULT_TIMEOUT_MS = 4000;
export const PHONE_RECONNECT_BASE_MS = 250;
export const PHONE_RECONNECT_CAP_MS = 8000;

export const KEEPWARM_INTERVAL_MS = 5000;
