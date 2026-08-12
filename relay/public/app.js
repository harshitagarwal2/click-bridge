// DOM wiring only. All decisions live in state.js (pure) and
// transport-coordinator.js (owns the one logical action).

import { initialState, reduce, view, PHASE } from './state.js';
import { TransportController } from './transport-controller.js';
import { TransportCoordinator } from './transport-coordinator.js';
import { PROTOCOL_VERSION, KEEPWARM_INTERVAL_MS } from './constants-lite.js';

const TOKEN_KEY = 'clickbridge.phoneToken';
const KEEPWARM_KEY = 'clickbridge.keepWarm';

const $ = (id) => document.getElementById(id);
const el = {
  dot: $('dot'), conn: $('conn'), status: $('status'), button: $('click-button'),
  settings: $('settings'), open: $('settings-open'),
  tokenInput: $('token-input'), tokenState: $('token-state'),
  save: $('token-save'), clear: $('token-clear'),
  keepwarm: $('keepwarm'), diag: $('diag'), reclaim: $('reclaim'),
};

let state = initialState();

const store = {
  get token() {
    try { return localStorage.getItem(TOKEN_KEY); } catch { return null; }
  },
  set token(v) {
    try { v === null ? localStorage.removeItem(TOKEN_KEY) : localStorage.setItem(TOKEN_KEY, v); }
    catch { /* private mode */ }
  },
  get keepWarm() {
    try { return localStorage.getItem(KEEPWARM_KEY) === '1'; } catch { return false; }
  },
  set keepWarm(v) {
    try { localStorage.setItem(KEEPWARM_KEY, v ? '1' : '0'); } catch { /* ignore */ }
  },
};

// -- transport ---------------------------------------------------------------

const wsUrl = () => `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;

const oci = new TransportController({
  name: 'oci',
  url: wsUrl,
  token: () => state.token,
  onMessage: (msg) => { coordinator.handleMessage('oci', msg); render(); },
  onStatus: (s) => {
    const EVENT = {
      open: 'transport.open',
      closed: 'transport.closed',
      replaced: 'transport.replaced',
    };
    dispatch({ type: EVENT[s] ?? 'transport.closed' });
    if (s !== 'open') coordinator.reset();
  },
});

const coordinator = new TransportCoordinator({
  getState: () => state,
  dispatch: (e) => dispatch(e),
  transports: [{ name: 'oci', controller: oci }],
});

function dispatch(event) {
  state = reduce(state, event);
  render();
}

// -- rendering ---------------------------------------------------------------

const DOT = {
  [PHASE.READY]: 'ready', [PHASE.POSTED]: 'ready',
  [PHASE.SENDING]: 'warn', [PHASE.FORWARDED]: 'warn',
  [PHASE.CLOCK_CHECKING]: 'warn', [PHASE.CLOCK_UNHEALTHY]: 'error',
  [PHASE.REJECTED]: 'error', [PHASE.UNKNOWN]: 'warn',
  [PHASE.REPLACED]: 'error',
};

const CONN = {
  [PHASE.MISSING_TOKEN]: 'Not paired',
  [PHASE.HIDDEN]: 'Paused',
  [PHASE.REPLACED]: 'Taken over',
  [PHASE.CONNECTING]: 'Connecting…',
  [PHASE.MAC_OFFLINE]: 'Mac offline',
  [PHASE.PERMISSION_REQUIRED]: 'Permission needed',
  [PHASE.REMOTE_DISABLED]: 'Remote off',
  [PHASE.CLOCK_CHECKING]: 'Checking clock',
  [PHASE.CLOCK_UNHEALTHY]: 'Clock mismatch',
};

function render() {
  const v = view(state);
  el.button.disabled = !v.enabled;
  el.status.textContent = v.status;
  el.status.className = `result ${
    v.phase === PHASE.POSTED ? 'posted'
      : v.phase === PHASE.REJECTED || v.phase === PHASE.CLOCK_UNHEALTHY
        || v.phase === PHASE.REPLACED ? 'error'
        : v.phase === PHASE.UNKNOWN ? 'warn' : ''}`;
  el.dot.className = `dot ${DOT[v.phase] ?? ''}`;
  el.reclaim.hidden = v.phase !== PHASE.REPLACED;
  el.conn.textContent = CONN[v.phase] ?? 'Mac ready';

  el.tokenState.textContent = state.token
    ? 'Token stored on this device.'
    : 'No token stored.';

  const c = state.clock;
  el.diag.textContent = c.checked
    ? `offset ${c.offsetMs?.toFixed(1)} ms ±${c.uncertaintyMs?.toFixed(1)} ms · late results ${state.lateResultCount}`
    : '—';
}

// -- activation --------------------------------------------------------------
// pointerdown is the fast path. The synthetic click that follows is consumed by
// its POINTER SEQUENCE, not a timer, so a long press still sends exactly once.
// A click with no armed pointer is keyboard / VoiceOver / Switch Control and
// must still work.

el.button.addEventListener('pointerdown', (e) => {
  if (!e.isPrimary || e.button !== 0) return;
  coordinator.activate('pointer');
  render();
}, { passive: true });

el.button.addEventListener('click', () => {
  coordinator.activate('click');
  render();
});

for (const type of ['pointercancel', 'pointerup', 'lostpointercapture']) {
  el.button.addEventListener(type, (e) => {
    if (type === 'pointercancel') { coordinator.cancelPointer(); render(); }
    else if (e.type === 'pointerup' && !e.isPrimary) coordinator.cancelPointer();
  }, { passive: true });
}

// -- settings ----------------------------------------------------------------

el.open.addEventListener('click', () => {
  el.tokenInput.value = '';                       // never echo the stored token
  el.settings.showModal();
});

el.save.addEventListener('click', () => {
  const value = el.tokenInput.value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(value)) {
    el.tokenState.textContent = 'Token must be exactly 64 hex characters.';
    return;
  }
  store.token = value;
  el.tokenInput.value = '';
  dispatch({ type: 'token.set', token: value });
  reclaim();                                      // unconditional: clears a replaced gate too
  el.tokenState.textContent = 'Token saved.';
});

// The only in-page way out of REPLACED. Deliberate, because taking the slot
// back evicts the other phone — which is fine when the user meant it, and a
// permanent ping-pong when it happens automatically.
function reclaim() {
  dispatch({ type: 'transport.reclaim' });
  oci.suspend();
  oci.connect();
}

el.reclaim.addEventListener('click', reclaim);

el.clear.addEventListener('click', () => {
  store.token = null;
  oci.suspend();
  coordinator.reset();
  dispatch({ type: 'token.cleared' });
});

el.keepwarm.addEventListener('change', () => {
  store.keepWarm = el.keepwarm.checked;
  restartKeepWarm();
});

// -- keep-warm (diagnostics; independent of the 20s heartbeat) ---------------

let keepWarmTimer = null;
function restartKeepWarm() {
  clearInterval(keepWarmTimer);
  keepWarmTimer = null;
  if (!store.keepWarm) return;
  keepWarmTimer = setInterval(() => {
    if (document.visibilityState !== 'visible' || !oci.ready) return;
    oci.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 0 });
  }, KEEPWARM_INTERVAL_MS);
}

// -- lifecycle ---------------------------------------------------------------

let wakeLock = null;

async function acquireWakeLock() {
  // Best effort. Prevents dimming only; it does NOT guarantee foreground
  // execution or an unthrottled socket, and on iOS it works in an installed
  // Home Screen app only from 18.4.
  if (!('wakeLock' in navigator)) return;
  try { wakeLock = await navigator.wakeLock.request('screen'); } catch { wakeLock = null; }
}

async function releaseWakeLock() {
  try { await wakeLock?.release(); } catch { /* already gone */ }
  wakeLock = null;
}

function goVisible() {
  dispatch({ type: 'visibility', visible: true });
  if (state.token) oci.connect();
  restartKeepWarm();
  acquireWakeLock();
}

function goHidden() {
  oci.suspend();                 // sets the gate first; no callback can reconnect
  coordinator.reset();
  clearInterval(keepWarmTimer);
  keepWarmTimer = null;
  releaseWakeLock();
  dispatch({ type: 'visibility', visible: false });
}

document.addEventListener('visibilitychange', () => {
  document.visibilityState === 'visible' ? goVisible() : goHidden();
});
window.addEventListener('pagehide', goHidden);
window.addEventListener('pageshow', () => {
  if (document.visibilityState === 'visible') goVisible();
});
window.addEventListener('online', () => {
  if (document.visibilityState === 'visible' && state.token) oci.reconnect();
});

// -- boot --------------------------------------------------------------------

const saved = store.token;
if (saved) state = reduce(state, { type: 'token.set', token: saved });
el.keepwarm.checked = store.keepWarm;
render();
if (saved) goVisible();
else render();
