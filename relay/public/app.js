import { ClockHealthController } from './clock-health-controller.js';
import { CredentialLifecycleController } from './credential-lifecycle-controller.js';
import {
  BenchmarkRequestRouter, BenchmarkRunSequence, BenchmarkSession,
  CounterSnapshotRequester, createIdleSchedule,
} from './benchmark-session.js';
import { BenchmarkController } from './benchmark-controller.js';
import { PhoneSettingsStore } from './phone-settings-store.js';
import { PairingController } from './pairing-controller.js';
import { parseAndClearPairingFragment } from './pairing-link.js';
import { createPairingUI } from './pairing-ui.js';
import { createRelayTransport } from './relay-transport.js';
import { createRuntimeScheduler } from './runtime-scheduler.js';
import { activationDecision, initialState, PHASE, reduce, view } from './state.js';
import { TransportCoordinator } from './transport-coordinator.js';
import { WakeLockController } from './wake-lock-controller.js';

// Pairing references are URL fragments. Scrub synchronously, before any DOM
// composition, transport, error reporting, or analytics can observe them.
let initialPairingInvitation = parseAndClearPairingFragment(
  window.location, window.history, window.location.host,
);

const byId = (id) => document.getElementById(id);
const element = {
  dot: byId('dot'),
  connection: byId('conn'),
  status: byId('status'),
  button: byId('click-button'),
  retryClock: byId('clock-retry'),
  settings: byId('settings'),
  openSettings: byId('settings-open'),
  tokenInput: byId('token-input'),
  tokenState: byId('token-state'),
  saveToken: byId('token-save'),
  clearToken: byId('token-clear'),
  keepWarm: byId('keepwarm'),
  diagnostics: byId('diag'),
  wakeStatus: byId('wake-status'),
  pairing: {
    panel: byId('pairing-panel'),
    remote: byId('remote-stage'),
    heading: byId('pairing-title'),
    message: byId('pairing-message'),
    alert: byId('pairing-alert'),
    code: byId('pairing-code'),
    paste: byId('pairing-paste'),
    cancel: byId('pairing-cancel'),
    pairedState: byId('pairing-paired-state'),
    pairAgain: byId('pair-again'),
    forget: byId('pairing-forget'),
  },
};

const settings = new PhoneSettingsStore(window.localStorage, navigator.locks);
const credentialSnapshot = settings.getSnapshot();
const scheduler = createRuntimeScheduler(window);
let state = initialState();
let lastMacReadyGeneration = null;
let clockHealth;
let benchmarkSession;
let benchmarkController;
let benchmarkSchedule = [];
let benchmarkBlockIndex = 0;
let benchmarkRequests;
let benchmarkTransportGeneration = null;
let pairingUI;

function dispatch(event) {
  state = reduce(state, event);
  render();
}

function transportPort() {
  return Object.freeze({
    name: oci.name,
    generation: oci.generation,
    ready: oci.ready,
    send: (message) => oci.send(message),
  });
}

const coordinator = new TransportCoordinator({
  getState: () => state,
  dispatch,
  transports: () => [transportPort()],
  selectTransports: (ports) => benchmarkController?.active && !benchmarkController.canActivate
    ? [] : ports.filter((port) => port.name === 'oci').slice(0, 1),
  clock: { now: () => Date.now(), monotonicNow: () => performance.now(),
    epochMonotonicNow: () => performance.timeOrigin + performance.now() },
  scheduler,
  getClockDiagnostics: () => clockHealth?.diagnostics ?? null,
  onBusyChange: (busy) => clockHealth?.actionStateChanged(busy),
  onMetric: (metric) => {
    benchmarkController?.handleMetric(metric, { keepWarm: element.keepWarm.checked,
      normalHeartbeat: '20s', network: navigator.connection?.effectiveType ?? 'unknown' })
      .catch((error) => { element.diagnostics.textContent = error.message; render(); });
  },
});

function handleInbound(message, transport) {
  if (message.type === 'time.sync.response') {
    if (benchmarkRequests.handle(message, transport.generation)) return;
    clockHealth.handleMessage(message);
    render();
    return;
  }

  if (message.type === 'diagnostics.counters') {
    benchmarkRequests.handle(message, transport.generation);
    return;
  }

  if (message.type === 'state') {
    dispatch({
      type: 'mac.state',
      macOnline: message.macOnline,
      remoteEnabled: message.remoteEnabled,
      permission: message.permission,
    });
    const ready = message.macOnline && message.remoteEnabled && message.permission === 'ready';
    if (ready && lastMacReadyGeneration !== transport.generation) {
      lastMacReadyGeneration = transport.generation;
      clockHealth.start();
      benchmarkController?.transportReady()
        .catch((error) => { element.diagnostics.textContent = error.message; render(); });
    } else if (!ready) {
      lastMacReadyGeneration = null;
      clockHealth.macNotReady();
    }
    return;
  }

  if (message.type === 'relay.ack' || message.type === 'action.result') {
    coordinator.handleMessage(transport.name, message);
    render();
  }
}

function handleTransportStatus(status) {
  if (status.state === 'ready') {
    if (benchmarkTransportGeneration !== null && benchmarkTransportGeneration !== oci.generation) {
      benchmarkController.transportLost('socket generation changed');
    }
    benchmarkTransportGeneration = oci.generation;
    dispatch({ type: 'transport.open' });
    return;
  }
  if (!['backoff', 'suspended', 'taken_over'].includes(status.state)) return;
  benchmarkController?.transportLost(status.reason);
  benchmarkTransportGeneration = null;
  lastMacReadyGeneration = null;
  coordinator.abandon(status.reason);
  clockHealth?.macNotReady();
  dispatch({ type: status.state === 'taken_over' ? 'transport.taken_over' : 'transport.closed' });
  if (status.state === 'taken_over') pairingUI?.handleState({ phase: 'replaced' });
}

const oci = createRelayTransport({
  location: window.location,
  token: () => state.token,
  onMessage: handleInbound,
  onStatus: handleTransportStatus,
});

function authenticateCredential(slot, signal) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (result, error = null) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeout);
      probe.close('pairing_probe_complete');
      signal?.removeEventListener('abort', abort);
      if (error) reject(error);
      else resolve(result);
    };
    const abort = () => finish(null, new Error('pairing_probe_cancelled'));
    const probe = createRelayTransport({
      location: window.location,
      token: slot.credential,
      onStatus: ({ state: transportState }) => {
        if (transportState === 'ready') finish(true);
        else if (transportState === 'taken_over') finish(false);
        else if (transportState === 'backoff') finish(null, new Error('pairing_probe_unavailable'));
      },
    });
    const timeout = window.setTimeout(
      () => finish(null, new Error('pairing_probe_timeout')), 10_000,
    );
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) { abort(); return; }
    probe.connect();
  });
}

async function startPairedTransport(slot, signal) {
  return credentialLifecycle.activatePairing(slot, signal);
}

const pairingEnabled = document.querySelector('meta[name="clickbridge-pairing"]')?.content === 'on';
const pairingController = new PairingController({
  location: window.location,
  settings,
  authenticateCredential,
  startTransport: startPairedTransport,
  onState: (pairingState) => pairingUI?.handleState(pairingState),
});

pairingUI = createPairingUI({
  elements: element.pairing,
  enabled: pairingEnabled,
  paired: Boolean(credentialSnapshot?.active),
  expectedHost: window.location.host,
  startPairing: (reference) => pairingController.start(reference),
  cancelPairing: () => pairingController.cancel(),
  forgetPairing: () => {
    pairingController.cancel();
    return credentialLifecycle.clear();
  },
});

if (initialPairingInvitation) {
  pairingUI.start(initialPairingInvitation);
  initialPairingInvitation = null;
}

benchmarkRequests = new BenchmarkRequestRouter({
  send: (message) => oci.send(message),
  getGeneration: () => oci.generation,
  scheduler,
  epochNow: () => performance.timeOrigin + performance.now(),
});

const counterSnapshots = new CounterSnapshotRequester({
  request: () => benchmarkRequests.requestCounters(),
});

benchmarkSession = new BenchmarkSession({
  exchangeTimeSync: () => benchmarkRequests.exchangeTimeSync(),
  counterSnapshots,
  isActionPending: () => coordinator.busy,
});

benchmarkController = new BenchmarkController({
  session: benchmarkSession,
  requests: benchmarkRequests,
  scheduler,
  monotonicNow: () => performance.now(),
  createSequence: () => {
    if (benchmarkSchedule.length === 0) benchmarkSchedule = createIdleSchedule();
    benchmarkBlockIndex += 1;
    return new BenchmarkRunSequence({ schedule: benchmarkSchedule,
      monotonicNow: () => performance.now(), blockIndex: benchmarkBlockIndex });
  },
  isActionPending: () => coordinator.busy,
  onRender: () => render(),
});

clockHealth = new ClockHealthController({
  sendSync: (message) => oci.send(message),
  getGeneration: () => oci.generation,
  clock: { now: () => Date.now() },
  scheduler,
  dispatch,
  isActionBusy: () => coordinator.busy,
});

const dotClass = {
  [PHASE.READY]: 'ready',
  [PHASE.POSTED]: 'ready',
  [PHASE.SENDING]: 'warn',
  [PHASE.FORWARDED]: 'warn',
  [PHASE.CLOCK_CHECKING]: 'warn',
  [PHASE.CLOCK_UNHEALTHY]: 'error',
  [PHASE.CLOCK_UNAVAILABLE]: 'error',
  [PHASE.REJECTED]: 'error',
  [PHASE.UNKNOWN]: 'warn',
};

const connectionText = {
  [PHASE.MISSING_TOKEN]: 'Not paired',
  [PHASE.HIDDEN]: 'Paused',
  [PHASE.TAKEN_OVER]: 'Taken over',
  [PHASE.CONNECTING]: 'Connecting…',
  [PHASE.MAC_OFFLINE]: 'Mac offline',
  [PHASE.PERMISSION_REQUIRED]: 'Permission needed',
  [PHASE.REMOTE_DISABLED]: 'Remote off',
  [PHASE.CLOCK_CHECKING]: 'Checking clock',
  [PHASE.CLOCK_UNHEALTHY]: 'Clock mismatch',
  [PHASE.CLOCK_UNAVAILABLE]: 'Clock unavailable',
};

function render() {
  const model = view(state);
  const benchmarkBlocked = benchmarkController.active && !benchmarkController.canActivate;
  element.button.disabled = !model.enabled || benchmarkBlocked;
  element.retryClock.hidden = !model.retryClockVisible;
  element.status.textContent = model.status;
  element.status.className = `result ${
    model.phase === PHASE.POSTED ? 'posted'
      : [PHASE.REJECTED, PHASE.CLOCK_UNHEALTHY, PHASE.CLOCK_UNAVAILABLE].includes(model.phase) ? 'error'
        : model.phase === PHASE.UNKNOWN ? 'warn' : ''}`;
  element.dot.className = `dot ${dotClass[model.phase] ?? ''}`;
  element.connection.textContent = connectionText[model.phase] ?? 'Mac ready';
  element.tokenState.textContent = state.token
    ? 'Token stored on this device.'
    : 'No token stored.';

  const diagnostics = clockHealth?.diagnostics;
  element.diagnostics.textContent = diagnostics
    ? `offset ${diagnostics.offsetMs.toFixed(1)} ms ±${diagnostics.uncertaintyMs.toFixed(1)} ms · sample ${Math.round(diagnostics.sampleAgeMs)} ms old · late results ${state.lateResultCount}`
    : `late results ${state.lateResultCount}`;
  if (benchmarkController.active) {
    const next = benchmarkController.current;
    element.diagnostics.textContent += benchmarkController.complete
      ? ' · benchmark 100/100; finish and export'
      : next.recorded
        ? ` · benchmark ${next.sampleIndex - 1}/100; ${next.eligible
          ? 'tap now' : `wait ${(next.remainingMs / 1_000).toFixed(1)}s`} (${next.scheduledIdleSeconds}s gap)`
        : ` · warm-up ${benchmarkController.sequence.terminals}/10`;
  }
  benchmarkFinish.disabled = !benchmarkController.active || !benchmarkController.complete
    || benchmarkController.refreshing || coordinator.busy;
  benchmarkStart.disabled = benchmarkController.active || benchmarkController.refreshing;
}

function pointerDescriptor(event) {
  return {
    kind: 'pointerdown',
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    button: event.button,
  };
}

element.button.addEventListener('pointerdown', (event) => {
  if (!event.isPrimary || event.button !== 0) return;
  const descriptor = pointerDescriptor(event);
  if (activationDecision(descriptor, state) !== 'send') return;
  if (coordinator.activate() !== 'sent') return;
  dispatch({
    type: 'pointer.armed',
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    button: event.button,
    startedAtMonotonicMs: performance.now(),
  });
}, { passive: true });

element.button.addEventListener('click', (event) => {
  const decision = activationDecision({
    kind: 'click',
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    detail: event.detail,
  }, state);
  if (decision === 'consume') dispatch({ type: 'pointer.consumed' });
  else if (decision === 'send') coordinator.activate();
  render();
});

element.button.addEventListener('pointercancel', (event) => {
  dispatch({ type: 'pointer.cancelled', pointerId: event.pointerId });
}, { passive: true });

element.openSettings.addEventListener('click', () => {
  element.tokenInput.value = '';
  element.settings.showModal();
});

element.saveToken.addEventListener('click', async () => {
  const token = element.tokenInput.value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(token)) {
    element.tokenState.textContent = 'Token must be exactly 64 lowercase hex characters.';
    return;
  }
  await credentialLifecycle.save(token);
});

element.clearToken.addEventListener('click', async () => {
  await credentialLifecycle.clear();
});

element.keepWarm.addEventListener('change', () => {
  settings.setKeepWarm(element.keepWarm.checked);
  oci.setKeepWarm(element.keepWarm.checked);
});

element.retryClock.addEventListener('click', () => clockHealth.retry());

function legacyIOSWakeLockUnavailable() {
  const match = navigator.userAgent.match(/(?:iPhone|iPad).*OS (\d+)[_.](\d+)/);
  if (!match) return false;
  const major = Number(match[1]);
  const minor = Number(match[2]);
  return major < 18 || (major === 18 && minor < 4);
}

function downloadCsv(name, contents) {
  const link = document.createElement('a');
  link.href = URL.createObjectURL(new Blob([contents], { type: 'text/csv;charset=utf-8' }));
  link.download = name;
  link.click();
  URL.revokeObjectURL(link.href);
}

const benchmarkControls = document.createElement('div');
const benchmarkStart = document.createElement('button');
const benchmarkFinish = document.createElement('button');
const benchmarkExport = document.createElement('button');
benchmarkStart.type = benchmarkFinish.type = benchmarkExport.type = 'button';
benchmarkStart.textContent = 'Start benchmark';
benchmarkFinish.textContent = 'Finish benchmark';
benchmarkExport.textContent = 'Export benchmark CSV';
benchmarkFinish.disabled = true;
benchmarkExport.disabled = true;
benchmarkControls.append(benchmarkStart, benchmarkFinish, benchmarkExport);
element.diagnostics.insertAdjacentElement('afterend', benchmarkControls);

benchmarkStart.addEventListener('click', async () => {
  if (!view(state).enabled) return;
  const condition = window.prompt('Condition label (network-mode-keepwarm-session)');
  if (!condition) return;
  benchmarkStart.disabled = true;
  try {
    await benchmarkController.start({ runId: crypto.randomUUID(), condition });
    benchmarkFinish.disabled = true;
  } catch (error) {
    element.diagnostics.textContent = error.message;
    benchmarkStart.disabled = false;
  }
  render();
});

benchmarkFinish.addEventListener('click', async () => {
  if (coordinator.busy || benchmarkController.refreshing || !benchmarkController.complete) return;
  const octoCounterStart = Number(window.prompt('Octo counter before run', '0'));
  const octoCounterEnd = Number(window.prompt('Octo counter after run', '0'));
  try {
    await benchmarkController.finish({ octoCounterStart, octoCounterEnd });
    benchmarkFinish.disabled = true;
    benchmarkExport.disabled = false;
    benchmarkStart.disabled = false;
  } catch (error) {
    element.diagnostics.textContent = error.message;
  }
  render();
});

benchmarkExport.addEventListener('click', () => {
  const files = benchmarkController.exportCsv();
  downloadCsv('measurements.csv', files.measurements);
  downloadCsv('run-evidence.csv', files.evidence);
});

const wakeLockLegacyUnavailable = legacyIOSWakeLockUnavailable();
const wakeLockController = new WakeLockController({
  requestLock: wakeLockLegacyUnavailable || !navigator.wakeLock?.request
    ? null
    : () => navigator.wakeLock.request('screen'),
  onStatus: ({ state: wakeState }) => {
    const copy = {
      active: 'Wake Lock active while this page is visible.',
      released: 'Wake Lock released.',
      denied: 'Wake Lock was not granted; clicking still works.',
      suspended: 'Wake Lock paused while hidden.',
      pending: 'Requesting Wake Lock…',
      unavailable: wakeLockLegacyUnavailable
        ? 'Wake Lock unavailable on iOS/iPadOS below 18.4.'
        : 'Wake Lock unavailable in this browser.',
    };
    element.wakeStatus.textContent = copy[wakeState] ?? 'Wake Lock status unavailable.';
  },
});

function goHidden() {
  benchmarkController.transportLost('hidden');
  coordinator.abandon('hidden');
  clockHealth.macNotReady();
  dispatch({ type: 'visibility', visible: false });
  oci.close('hidden');
  pairingController.cancel();
  wakeLockController.suspend();
}

let pairingRecoveryNeeded = Boolean(pairingEnabled && credentialSnapshot?.pending);
let pairingRecoveryInFlight = false;

async function recoverPairingIfNeeded() {
  if (!pairingRecoveryNeeded || pairingRecoveryInFlight
    || document.visibilityState !== 'visible') return pairingRecoveryNeeded;
  pairingRecoveryInFlight = true;
  pairingUI.startRecovery();
  const recovered = await pairingController.recover();
  pairingRecoveryInFlight = false;
  if (recovered) pairingRecoveryNeeded = false;
  return pairingRecoveryNeeded;
}

function goVisible() {
  dispatch({ type: 'visibility', visible: true });
  if (pairingRecoveryNeeded) {
    void recoverPairingIfNeeded();
  } else credentialLifecycle.visible();
  wakeLockController.acquire();
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') goVisible();
  else goHidden();
});
window.addEventListener('pagehide', goHidden);
window.addEventListener('pageshow', () => {
  if (document.visibilityState === 'visible') goVisible();
});
window.addEventListener('online', () => {
  benchmarkController.transportLost('network changed');
  credentialLifecycle.online();
});
navigator.connection?.addEventListener?.('change', () => {
  if (!benchmarkController.active) return;
  benchmarkController.transportLost('network changed');
  benchmarkController.transportReady()
    .catch((error) => { element.diagnostics.textContent = error.message; render(); });
});

function applySavedToken(token) {
  element.tokenInput.value = '';
  benchmarkRequests?.cancelAll('token replaced');
  oci.close('token_replaced');
  dispatch({ type: 'token.set', token });
  oci.resume();
}

const credentialLifecycle = new CredentialLifecycleController({
  settings,
  isVisible: () => document.visibilityState === 'visible',
  currentToken: () => state.token,
  transportReady: () => oci.ready,
  applyToken: applySavedToken,
  clearToken: () => {
    coordinator.abandon('token_cleared');
    clockHealth.macNotReady();
    benchmarkRequests.cancelAll('token cleared');
    oci.close('token_cleared');
    dispatch({ type: 'token.cleared' });
  },
  connect: () => oci.connect(),
  reportError: (message) => { element.tokenState.textContent = message; },
});

const savedToken = credentialSnapshot?.active?.credential ?? null;
if (savedToken) state = reduce(state, { type: 'token.set', token: savedToken });
element.keepWarm.checked = settings.getKeepWarm();
oci.setKeepWarm(element.keepWarm.checked);
render();
if (pairingRecoveryNeeded && document.visibilityState === 'visible') {
  void recoverPairingIfNeeded();
} else if (document.visibilityState === 'visible') goVisible();
else goHidden();
