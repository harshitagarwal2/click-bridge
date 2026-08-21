// Pure phone state. No DOM, no timers, no browser APIs — so `node --test` can
// exercise every product state directly.

export const PHASE = Object.freeze({
  MISSING_TOKEN: 'missing_token',
  HIDDEN: 'hidden',
  TAKEN_OVER: 'taken_over',
  CREDENTIAL_REPLACED: 'credential_replaced',
  CONNECTING: 'connecting',
  MAC_OFFLINE: 'mac_offline',
  PERMISSION_REQUIRED: 'permission_required',
  REMOTE_DISABLED: 'remote_disabled',
  CLOCK_UNHEALTHY: 'clock_unhealthy',
  CLOCK_UNAVAILABLE: 'clock_unavailable',
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
    takenOver: false,
    credentialReplaced: false,
    mac: { online: false, remoteEnabled: false, permission: 'unknown' },
    desktops: [],
    desktopCount: 0,
    macCount: 0,
    windowsCount: 0,
    clock: { checked: false, healthy: false, unavailable: false, offsetMs: null, uncertaintyMs: null, measuredAtUnixMs: null },
    /** in-flight logical action: { id, phase: 'sending'|'forwarded' } */
    action: null,
    /** last completed outcome: { outcome, reason, ms } */
    last: null,
    /** a pointer activation is awaiting the synthetic click that belongs to it */
    pointerSequence: null,
    lateResultCount: 0,
  };
}

const clearVolatile = (s) => ({
  ...s,
  connected: false,
  mac: { online: false, remoteEnabled: false, permission: 'unknown' },
  desktops: [],
  desktopCount: 0,
  macCount: 0,
  windowsCount: 0,
  clock: { checked: false, healthy: false, unavailable: false, offsetMs: null, uncertaintyMs: null, measuredAtUnixMs: null },
  pointerSequence: null,
});

export function reduce(state, event) {
  switch (event.type) {
    case 'token.set':
      return { ...state, token: event.token, takenOver: false, credentialReplaced: false };

    case 'token.cleared':
      return { ...clearVolatile(state), token: null, takenOver: false, credentialReplaced: false, action: null, last: null };

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
      return { ...state, connected: true, takenOver: false, credentialReplaced: false };

    case 'transport.taken_over': {
      const s = clearVolatile({ ...state, takenOver: true });
      return state.action
        ? { ...s, action: null, last: { outcome: 'unknown', reason: 'taken_over', ms: null } }
        : s;
    }

    // Distinct from taken_over: this credential is dead, so reconnecting cannot
    // help and the UI must send the user to pairing instead.
    case 'transport.credential_replaced': {
      const s = clearVolatile({ ...state, credentialReplaced: true });
      return state.action
        ? { ...s, action: null, last: { outcome: 'unknown', reason: 'credential_replaced', ms: null } }
        : s;
    }

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
        desktops: Array.isArray(event.desktops) ? event.desktops : [],
        desktopCount: Number.isInteger(event.desktopCount) ? event.desktopCount : (Array.isArray(event.desktops) ? event.desktops.length : 0),
        macCount: Number.isInteger(event.macCount) ? event.macCount : 0,
        windowsCount: Number.isInteger(event.windowsCount) ? event.windowsCount : 0,
      };

    case 'clock.health':
      return {
        ...state,
        clock: {
          checked: true,
          healthy: event.healthy,
          unavailable: false,
          offsetMs: event.offsetMs ?? null,
          uncertaintyMs: event.uncertaintyMs ?? null,
          measuredAtUnixMs: event.measuredAtUnixMs ?? null,
        },
      };

    case 'clock.started':
    case 'clock.reset':
      return { ...state, clock: { checked: false, healthy: false, unavailable: false, offsetMs: null, uncertaintyMs: null, measuredAtUnixMs: null } };

    case 'clock.unavailable':
      return { ...state, clock: { ...state.clock, checked: false, healthy: false, unavailable: true } };

    case 'pointer.armed':
      return {
        ...state,
        pointerSequence: {
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          button: event.button,
          startedAtMonotonicMs: event.startedAtMonotonicMs,
        },
      };

    case 'pointer.consumed':
      return { ...state, pointerSequence: null };

    case 'pointer.cancelled':
      if (!state.pointerSequence || state.pointerSequence.pointerId !== event.pointerId) return state;
      return { ...state, pointerSequence: null };

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
        last: {
          outcome: 'rejected',
          reason: event.reason ?? event.status,
          ms: event.ms ?? null,
          clockDiagnostics: event.clockDiagnostics ?? null,
        },
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
  if (state.credentialReplaced) return PHASE.CREDENTIAL_REPLACED;
  if (state.takenOver) return PHASE.TAKEN_OVER;
  if (state.action) {
    return state.action.phase === 'forwarded' ? PHASE.FORWARDED : PHASE.SENDING;
  }
  if (!state.connected) return PHASE.CONNECTING;
  if (!state.mac.online) return PHASE.MAC_OFFLINE;
  if (state.mac.permission !== 'ready') return PHASE.PERMISSION_REQUIRED;
  if (!state.mac.remoteEnabled) return PHASE.REMOTE_DISABLED;
  if (state.clock.unavailable) return PHASE.CLOCK_UNAVAILABLE;
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

  // Human-readable inventory for multi-desktop fan-out (2 Windows + 1 Mac etc.)
  const desktopLabel = (() => {
    const total = state.desktopCount ?? (state.desktops?.length ?? 0);
    if (total === 0) return null;
    const mc = state.macCount ?? state.desktops?.filter((d) => d.platform === 'mac').length ?? 0;
    const wc = state.windowsCount ?? state.desktops?.filter((d) => d.platform === 'windows').length ?? 0;
    const parts = [];
    if (mc > 0) parts.push(`${mc} Mac${mc>1?'s':''}`);
    if (wc > 0) parts.push(`${wc} Windows`);
    const inventory = parts.length ? parts.join(' + ') : `${total} desktops`;
    // Show per-desktop readiness if any not ready
    const notReady = state.desktops?.filter((d) => d.permission !== 'ready' || !d.remoteEnabled) ?? [];
    if (notReady.length > 0) return `${inventory} — ${notReady.length} needs attention`;
    return inventory;
  })();

  let status;
  switch (phase) {
    case PHASE.MISSING_TOKEN: status = 'Pair this browser'; break;
    case PHASE.HIDDEN: status = 'Paused'; break;
    case PHASE.TAKEN_OVER: status = 'Another device took over. Reload this page to take control back.'; break;
    case PHASE.CREDENTIAL_REPLACED: status = 'This browser was un-paired. Pair again to reconnect.'; break;
    case PHASE.CONNECTING: status = 'Connecting…'; break;
    case PHASE.MAC_OFFLINE: status = desktopLabel ? `Open Click Bridge — ${desktopLabel} online` : 'Open Click Bridge on the Mac'; break;
    case PHASE.PERMISSION_REQUIRED: status = desktopLabel ? `Grant permission — ${desktopLabel}` : 'Grant input permission on the Mac'; break;
    case PHASE.REMOTE_DISABLED: status = desktopLabel ? `Enable remote control — ${desktopLabel}` : 'Enable remote control on the Mac'; break;
    case PHASE.CLOCK_CHECKING: status = 'Checking clock…'; break;
    case PHASE.CLOCK_UNAVAILABLE: status = 'Clock check unavailable — retry'; break;
    case PHASE.CLOCK_UNHEALTHY: status = 'Clock mismatch — enable automatic date and time'; break;
    case PHASE.SENDING: status = desktopLabel ? `Sending to ${desktopLabel}…` : 'Sending…'; break;
    case PHASE.FORWARDED: status = desktopLabel ? `Forwarded to ${desktopLabel}…` : 'Forwarded…'; break;
    case PHASE.POSTED:
      if (desktopLabel) status = state.last.ms == null ? `Posted to ${desktopLabel}` : `Posted to ${desktopLabel} in ${Math.round(state.last.ms)} ms`;
      else status = state.last.ms == null ? 'Posted' : `Posted in ${Math.round(state.last.ms)} ms`;
      break;
    case PHASE.REJECTED:
      status = REASON_TEXT[state.last.reason] ?? `Rejected — ${state.last.reason}`;
      break;
    case PHASE.UNKNOWN:
      status = desktopLabel ? 'Click may have occurred; check desktops before trying again.' : 'Click may have occurred; check the Mac before trying again.';
      break;
    default: status = desktopLabel ? `Tap to click (${desktopLabel})` : 'Tap to click';
  }
  return {
    phase,
    enabled,
    status,
    retryClockVisible: phase === PHASE.CLOCK_UNAVAILABLE,
    desktopLabel,
    desktops: state.desktops ?? [],
    desktopCount: state.desktopCount ?? 0,
    macCount: state.macCount ?? 0,
    windowsCount: state.windowsCount ?? 0,
  };
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
export function activationDecision(activation, state) {
  const event = typeof activation === 'string'
    ? { kind: activation === 'pointer' ? 'pointerdown' : activation }
    : activation;
  const gateOpen = view(state).enabled;
  if (event.kind === 'pointerdown') return gateOpen ? 'send' : 'ignore';
  if (event.kind === 'click') {
    const handled = state.pointerSequence;
    const pointerGenerated = event.detail > 0 || Boolean(event.pointerType);
    const matchingId = event.pointerId == null || event.pointerId === handled?.pointerId;
    if (handled && pointerGenerated && matchingId) return 'consume';
    return gateOpen ? 'send' : 'ignore';
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
