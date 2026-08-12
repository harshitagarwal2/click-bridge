import { ClockHealthController } from './clock-health-controller.js';
import { BenchmarkRunSequence, BenchmarkSession, createIdleSchedule } from './benchmark-session.js';
import { PhoneSettingsStore } from './phone-settings-store.js';
import { createRelayTransport } from './relay-transport.js';
import { createRuntimeScheduler } from './runtime-scheduler.js';
import { activationDecision, initialState, PHASE, reduce, view } from './state.js';
import { TransportCoordinator } from './transport-coordinator.js';
import { WakeLockController } from './wake-lock-controller.js';

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
};

const settings = new PhoneSettingsStore(window.localStorage);
const scheduler = createRuntimeScheduler(window);
let state = initialState();
let lastMacReadyGeneration = null;
let clockHealth;
let benchmarkSession;
let benchmarkActive = false;
let benchmarkRefreshing = false;
let benchmarkRefreshRequired = false;
const benchmarkDrafts = new Map();
const pendingBenchmarkSync = new Map();
const pendingBenchmarkCounters = new Map();
let benchmarkSchedule = [];
let benchmarkSequence;
let benchmarkIdleStartedMonotonicMs = 0;

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
  selectTransports: (ports) => benchmarkRefreshing
    || (benchmarkActive && benchmarkSequence.complete)
    ? [] : ports.filter((port) => port.name === 'oci').slice(0, 1),
  clock: { now: () => Date.now(), monotonicNow: () => performance.now(),
    epochMonotonicNow: () => performance.timeOrigin + performance.now() },
  scheduler,
  getClockDiagnostics: () => clockHealth?.diagnostics ?? null,
  onBusyChange: (busy) => clockHealth?.actionStateChanged(busy),
  onMetric: (metric) => {
    if (!benchmarkActive) return;
    if (metric.type === 'activation') {
      const sequence = benchmarkSequence.current();
      benchmarkDrafts.set(metric.actionId, { ...metric, keepWarm: element.keepWarm.checked,
        normalHeartbeat: '20s', network: navigator.connection?.effectiveType ?? 'unknown',
        recorded: sequence.recorded,
        scheduledIdleSeconds: sequence.scheduledIdleSeconds ?? '',
        actualIdleMs: performance.now() - benchmarkIdleStartedMonotonicMs,
        sampleIndex: sequence.sampleIndex ?? '', blockIndex: 1 });
    } else if (metric.type === 'ack') {
      Object.assign(benchmarkDrafts.get(metric.actionId) ?? {}, metric);
    } else if (metric.type === 'terminal') {
      const draft = benchmarkDrafts.get(metric.actionId) ?? {};
      benchmarkDrafts.delete(metric.actionId);
      if (draft.recorded) {
        delete draft.recorded;
        benchmarkSession.recordTerminal({ ...draft, ...metric,
          status: metric.status === 'posted' ? 'Posted'
            : metric.status === 'Unknown' ? 'Unknown' : 'Rejected' });
      } else benchmarkSession.recordExcludedTerminal();
      benchmarkSequence.terminal();
      benchmarkIdleStartedMonotonicMs = performance.now();
      benchmarkRefreshing = true;
      const forceRefresh = benchmarkRefreshRequired;
      benchmarkRefreshRequired = false;
      benchmarkSession.refreshIfDue({ force: forceRefresh })
        .catch((error) => { element.diagnostics.textContent = error.message; })
        .finally(() => { benchmarkRefreshing = false; });
    } else if (metric.type === 'late-result') {
      benchmarkSession.recordLateResult(metric.actionId);
    }
  },
});

function handleInbound(message, transport) {
  if (message.type === 'time.sync.response') {
    const pending = pendingBenchmarkSync.get(message.syncId);
    if (pending) {
      pendingBenchmarkSync.delete(message.syncId);
      pending.resolve({ t0: message.phoneSendUnixMs, t1: message.macReceiveUnixMs,
        t2: message.macSendUnixMs, t3: performance.timeOrigin + performance.now() });
      return;
    }
    clockHealth.handleMessage(message);
    render();
    return;
  }

  if (message.type === 'diagnostics.counters') {
    const pending = pendingBenchmarkCounters.get(message.requestId);
    if (pending) {
      pendingBenchmarkCounters.delete(message.requestId);
      pending.resolve(message);
    }
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
    dispatch({ type: 'transport.open' });
    return;
  }
  if (status.state !== 'backoff' && status.state !== 'suspended') return;
  lastMacReadyGeneration = null;
  coordinator.abandon(status.reason);
  clockHealth?.macNotReady();
  dispatch({ type: 'transport.closed' });
}

const oci = createRelayTransport({
  location: window.location,
  token: () => state.token,
  onMessage: handleInbound,
  onStatus: handleTransportStatus,
});

function requestBenchmarkMessage(map, message, id) {
  return new Promise((resolve, reject) => {
    const timer = scheduler.setTimeout(() => {
      map.delete(id);
      reject(new Error('benchmark diagnostic response timed out'));
    }, 3_500);
    map.set(id, { resolve: (value) => { scheduler.clearTimeout(timer); resolve(value); } });
    if (!oci.send(message)) {
      scheduler.clearTimeout(timer);
      map.delete(id);
      reject(new Error('benchmark transport unavailable'));
    }
  });
}

benchmarkSession = new BenchmarkSession({
  exchangeTimeSync: () => {
    const syncId = crypto.randomUUID();
    const phoneSendUnixMs = performance.timeOrigin + performance.now();
    return requestBenchmarkMessage(pendingBenchmarkSync,
      { type: 'time.sync.request', v: 1, syncId, phoneSendUnixMs }, syncId);
  },
  requestCounters: () => {
    const requestId = crypto.randomUUID();
    return requestBenchmarkMessage(pendingBenchmarkCounters,
      { type: 'diagnostics.request', v: 1, requestId }, requestId);
  },
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
  element.button.disabled = !model.enabled;
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
  if (benchmarkActive) {
    const next = benchmarkSequence.current();
    element.diagnostics.textContent += benchmarkSequence.complete
      ? ' · benchmark 100/100; finish and export'
      : next.recorded
        ? ` · benchmark ${next.sampleIndex - 1}/100; next gap ${next.scheduledIdleSeconds}s`
        : ` · warm-up ${benchmarkSequence.terminals}/10`;
  }
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

element.saveToken.addEventListener('click', () => {
  const token = element.tokenInput.value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(token)) {
    element.tokenState.textContent = 'Token must be exactly 64 lowercase hex characters.';
    return;
  }
  settings.setToken(token);
  element.tokenInput.value = '';
  oci.close('token_replaced');
  dispatch({ type: 'token.set', token });
  oci.connect();
});

element.clearToken.addEventListener('click', () => {
  settings.clearToken();
  coordinator.abandon('token_cleared');
  clockHealth.macNotReady();
  oci.close('token_cleared');
  dispatch({ type: 'token.cleared' });
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
  benchmarkRefreshing = true;
  benchmarkStart.disabled = true;
  try {
    await benchmarkSession.start({ runId: crypto.randomUUID(), condition });
    benchmarkSchedule = createIdleSchedule();
    benchmarkSequence = new BenchmarkRunSequence({ schedule: benchmarkSchedule });
    benchmarkIdleStartedMonotonicMs = performance.now();
    benchmarkActive = true;
    benchmarkFinish.disabled = false;
  } catch (error) {
    element.diagnostics.textContent = error.message;
    benchmarkStart.disabled = false;
  } finally { benchmarkRefreshing = false; }
});

benchmarkFinish.addEventListener('click', async () => {
  if (coordinator.busy || benchmarkRefreshing) return;
  benchmarkRefreshing = true;
  const octoCounterStart = Number(window.prompt('Octo counter before run', '0'));
  const octoCounterEnd = Number(window.prompt('Octo counter after run', '0'));
  try {
    await benchmarkSession.finish({ octoCounterStart, octoCounterEnd,
      logicalActionCount: Math.max(0, benchmarkSequence.terminals - 10) });
    benchmarkActive = false;
    benchmarkFinish.disabled = true;
    benchmarkExport.disabled = false;
    benchmarkStart.disabled = false;
  } finally { benchmarkRefreshing = false; }
});

benchmarkExport.addEventListener('click', () => {
  const files = benchmarkSession.exportCsv();
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
  if (benchmarkActive) benchmarkRefreshRequired = true;
  coordinator.abandon('hidden');
  clockHealth.macNotReady();
  dispatch({ type: 'visibility', visible: false });
  oci.close('hidden');
  wakeLockController.suspend();
}

function goVisible() {
  dispatch({ type: 'visibility', visible: true });
  if (state.token && !oci.ready) oci.connect();
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
  if (benchmarkActive) benchmarkRefreshRequired = true;
  if (document.visibilityState === 'visible' && state.token && !oci.ready) oci.connect();
});
navigator.connection?.addEventListener?.('change', () => {
  if (!benchmarkActive) return;
  if (coordinator.busy || benchmarkRefreshing) { benchmarkRefreshRequired = true; return; }
  benchmarkRefreshing = true;
  benchmarkSession.refreshIfDue({ force: true })
    .catch((error) => { element.diagnostics.textContent = error.message; })
    .finally(() => { benchmarkRefreshing = false; });
});

const savedToken = settings.getToken();
if (savedToken) state = reduce(state, { type: 'token.set', token: savedToken });
element.keepWarm.checked = settings.getKeepWarm();
oci.setKeepWarm(element.keepWarm.checked);
render();
if (document.visibilityState === 'visible') goVisible();
else goHidden();
