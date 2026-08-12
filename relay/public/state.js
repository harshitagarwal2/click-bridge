// Pure phone state. No DOM, no timers, no browser APIs — so `node --test` can
// exercise every product state directly.

export const PHASE = Object.freeze({
  MISSING_TOKEN: 'missing_token',
  HIDDEN: 'hidden',
  CONNECTING: 'connecting',
  MAC_OFFLINE: 'mac_offline',
  PERMISSION_REQUIRED: 'permission_required',
  REMOTE_DISABLED: 'remote_disabled',
  CLOCK_UNHEALTHY: 'clock_unhealthy',
  CLOCK_CHECKING: 'clock_checking',
  READY: 'ready',
  SENDING: 'sending',
  FORWARDED: 'forwarded',
  POSTED: 'posted',
  REJECTED: 'rejected',
  UNKNOWN: 'unknown',
});

/** Outcomes that are absorbing: a late ack or result can never displace them. */
const TERMINAL = new Set(['posted', 'rejected', 'unknown']);

export function initialState() {
  return {
    token: null,
    visible: true,
    connected: false,
    mac: { online: false, remoteEnabled: false, permission: 'unknown' },
    clock: { checked: false, healthy: false, offsetMs: null, uncertaintyMs: null },
    /** in-flight logical action: { id, phase: 'sending'|'forwarded' } */
    action: null,
    /** last completed outcome: { outcome, reason, ms } */
    last: null,
    /** a pointer activation is awaiting the synthetic click that belongs to it */
    pointerArmed: false,
    lateResultCount: 0,
  };
}

const clearVolatile = (s) => ({
  ...s,
  connected: false,
  mac: { online: false, remoteEnabled: false, permission: 'unknown' },
  clock: { checked: false, healthy: false, offsetMs: null, uncertaintyMs: null },
  pointerArmed: false,
});

export function reduce(state, event) {
  switch (event.type) {
    case 'token.set':
      return { ...state, token: event.token };

    case 'token.cleared':
      return { ...clearVolatile(state), token: null, action: null, last: null };

    case 'visibility':
      if (event.visible === state.visible) return state;
      if (!event.visible) {
        // Sockets close on hide; an in-flight action can never be resolved.
        const s = clearVolatile({ ...state, visible: false });
        return state.action
          ? { ...s, action: null, last: { outcome: 'unknown', reason: 'hidden', ms: null } }
          : s;
      }
      return { ...clearVolatile(state), visible: true };

    case 'transport.open':
      return { ...state, connected: true };

    case 'transport.closed': {
      const s = clearVolatile(state);
      return state.action
        ? { ...s, action: null, last: { outcome: 'unknown', reason: 'disconnected', ms: null } }
        : s;
    }

    case 'mac.state':
      return {
        ...state,
        mac: {
          online: event.macOnline,
          remoteEnabled: event.remoteEnabled,
          permission: event.permission,
        },
      };

    case 'clock.health':
      return {
        ...state,
        clock: {
          checked: true,
          healthy: event.healthy,
          offsetMs: event.offsetMs ?? null,
          uncertaintyMs: event.uncertaintyMs ?? null,
        },
      };

    case 'clock.reset':
      return { ...state, clock: { checked: false, healthy: false, offsetMs: null, uncertaintyMs: null } };

    case 'pointer.armed':
      return { ...state, pointerArmed: true };

    case 'pointer.consumed':
    case 'pointer.cancelled':
      return { ...state, pointerArmed: false };

    case 'action.sent':
      if (state.action) return state;                 // one in flight, always
      return { ...state, action: { id: event.actionId, phase: 'sending' }, last: null };

    case 'action.ack':
      if (!state.action || state.action.id !== event.actionId) return state;
      if (event.status === 'forwarded') {
        return { ...state, action: { ...state.action, phase: 'forwarded' } };
      }
      // mac_offline / rejected are terminal for this action.
      return {
        ...state,
        action: null,
        last: { outcome: 'rejected', reason: event.status, ms: event.ms ?? null },
      };

    case 'action.result':
      if (!state.action || state.action.id !== event.actionId) {
        // A late duplicate from a second transport. Diagnostics only.
        return { ...state, lateResultCount: state.lateResultCount + 1 };
      }
      return {
        ...state,
        action: null,
        last: {
          outcome: event.status === 'posted' ? 'posted' : 'rejected',
          reason: event.reason,
          ms: event.ms ?? null,
        },
      };

    case 'action.timeout':
      if (!state.action || state.action.id !== event.actionId) return state;
      return {
        ...state,
        action: null,
        last: { outcome: 'unknown', reason: 'timeout', ms: null },
      };

    default:
      return state;
  }
}

/** The single gate that decides whether a tap may become a request. */
export function phaseOf(state) {
  if (!state.token) return PHASE.MISSING_TOKEN;
  if (!state.visible) return PHASE.HIDDEN;
  if (state.action) {
    return state.action.phase === 'forwarded' ? PHASE.FORWARDED : PHASE.SENDING;
  }
  if (!state.connected) return PHASE.CONNECTING;
  if (!state.mac.online) return PHASE.MAC_OFFLINE;
  if (state.mac.permission !== 'ready') return PHASE.PERMISSION_REQUIRED;
  if (!state.mac.remoteEnabled) return PHASE.REMOTE_DISABLED;
  if (!state.clock.checked) return PHASE.CLOCK_CHECKING;
  if (!state.clock.healthy) return PHASE.CLOCK_UNHEALTHY;
  if (state.last?.outcome === 'posted') return PHASE.POSTED;
  if (state.last?.outcome === 'rejected') return PHASE.REJECTED;
  if (state.last?.outcome === 'unknown') return PHASE.UNKNOWN;
  return PHASE.READY;
}

const REASON_TEXT = {
  permission_required: 'Grant input permission on the Mac',
  remote_disabled: 'Enable remote control on the Mac',
  id_conflict: 'Conflicting request — try again',
  expired: 'Took too long — not clicked',
  capacity_exceeded: 'Mac is saturated — try again',
  event_creation_failed: 'The Mac could not build the click',
  invalid_request: 'Rejected as invalid',
  mac_offline: 'The Mac went offline',
  rejected: 'The relay refused it',
};

export function view(state) {
  const phase = phaseOf(state);
  const enabled = phase === PHASE.READY
    || phase === PHASE.POSTED
    || phase === PHASE.REJECTED
    || phase === PHASE.UNKNOWN;

  let status;
  switch (phase) {
    case PHASE.MISSING_TOKEN: status = 'Enter the phone token'; break;
    case PHASE.HIDDEN: status = 'Paused'; break;
    case PHASE.CONNECTING: status = 'Connecting…'; break;
    case PHASE.MAC_OFFLINE: status = 'Open Click Bridge on the Mac'; break;
    case PHASE.PERMISSION_REQUIRED: status = 'Grant input permission on the Mac'; break;
    case PHASE.REMOTE_DISABLED: status = 'Enable remote control on the Mac'; break;
    case PHASE.CLOCK_CHECKING: status = 'Checking clock…'; break;
    case PHASE.CLOCK_UNHEALTHY: status = 'Clock mismatch — enable automatic date and time'; break;
    case PHASE.SENDING: status = 'Sending…'; break;
    case PHASE.FORWARDED: status = 'Forwarded…'; break;
    case PHASE.POSTED:
      status = state.last.ms == null ? 'Posted' : `Posted in ${Math.round(state.last.ms)} ms`;
      break;
    case PHASE.REJECTED:
      status = REASON_TEXT[state.last.reason] ?? `Rejected — ${state.last.reason}`;
      break;
    case PHASE.UNKNOWN:
      status = 'Click may have occurred — check the Mac before retrying';
      break;
    default: status = 'Tap to click';
  }
  return { phase, enabled, status };
}

/**
 * Decide what an activation event should do.
 *
 * Pointer suppression is tied to the POINTER SEQUENCE, not a stopwatch: a long
 * press still produces exactly one request, which a timer-based window would
 * get wrong once the press outlives the window.
 *
 * @returns {'send'|'consume'|'ignore'}
 */
export function activationDecision(kind, state) {
  const gateOpen = view(state).enabled;
  if (kind === 'pointer') return gateOpen ? 'send' : 'ignore';
  if (kind === 'click') {
    if (state.pointerArmed) return 'consume';       // synthetic click from our own pointerdown
    return gateOpen ? 'send' : 'ignore';            // keyboard / VoiceOver / Switch Control
  }
  return 'ignore';
}

/** Is this measured clock offset acceptable, given its own uncertainty? */
export function clockHealthy(offsetMs, rttMs, toleranceMs) {
  return Math.abs(offsetMs) <= toleranceMs + rttMs / 2;
}

/** NTP four-timestamp offset and round trip. */
export function clockSample({ t0, t1, t2, t3 }) {
  return {
    offsetMs: ((t1 - t0) + (t2 - t3)) / 2,
    rttMs: (t3 - t0) - (t2 - t1),
  };
}

/** Pick the least-contaminated sample: smallest non-negative round trip. */
export function bestSample(samples) {
  const usable = samples.filter((s) => Number.isFinite(s.rttMs) && s.rttMs >= 0);
  if (usable.length === 0) return null;
  return usable.reduce((a, b) => (b.rttMs < a.rttMs ? b : a));
}

export { TERMINAL };
