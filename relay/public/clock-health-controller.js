import { PROTOCOL_VERSION } from './wire-protocol.js';
import { bestSample, clockHealthy, clockSample } from './state.js';
import {
  CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS,
  CLOCK_HEALTH_REFRESH_MS,
  CLOCK_HEALTH_SAMPLES,
  CLOCK_SKEW_TOLERANCE_MS,
} from './runtime-constants.js';

const defaultScheduler = Object.freeze({
  setTimeout: (callback, delay) => setTimeout(callback, delay),
  clearTimeout: (timer) => clearTimeout(timer),
});

export class ClockHealthController {
  constructor({
    sendSync,
    getGeneration,
    clock = { now: Date.now },
    scheduler = defaultScheduler,
    idGenerator = () => crypto.randomUUID(),
    dispatch,
    isActionBusy = () => false,
  }) {
    this.sendSync = sendSync;
    this.getGeneration = getGeneration;
    this.clock = clock;
    this.scheduler = scheduler;
    this.idGenerator = idGenerator;
    this.dispatch = dispatch;
    this.isActionBusy = isActionBusy;
    this.batch = 0;
    this.batchGeneration = null;
    this.samples = [];
    this.pending = null;
    this.exchangeTimer = null;
    this.refreshTimer = null;
    this.refreshPending = false;
    this.latest = null;
  }

  get diagnostics() {
    if (!this.latest) return null;
    return Object.freeze({
      offsetMs: this.latest.offsetMs,
      uncertaintyMs: this.latest.uncertaintyMs,
      sampleAgeMs: Math.max(0, this.clock.now() - this.latest.measuredAtUnixMs),
    });
  }

  start() {
    this.#beginBatch();
  }

  retry() {
    this.#beginBatch();
  }

  macNotReady() {
    this.#cancelBatch();
    this.scheduler.clearTimeout(this.refreshTimer);
    this.refreshTimer = null;
    this.refreshPending = false;
    this.latest = null;
    this.dispatch({ type: 'clock.reset' });
  }

  actionStateChanged(busy) {
    if (!busy && this.refreshPending) {
      this.refreshPending = false;
      this.#beginBatch();
    }
  }

  handleMessage(message) {
    if (message.type !== 'time.sync.response' || !this.pending) return false;
    if (this.batchGeneration !== this.getGeneration()) return false;
    if (message.syncId !== this.pending.syncId
      || message.phoneSendUnixMs !== this.pending.phoneSendUnixMs) return false;

    this.scheduler.clearTimeout(this.exchangeTimer);
    this.exchangeTimer = null;
    const pending = this.pending;
    this.pending = null;
    this.samples.push(clockSample({
      t0: pending.phoneSendUnixMs,
      t1: message.macReceiveUnixMs,
      t2: message.macSendUnixMs,
      t3: this.clock.now(),
    }));

    if (this.samples.length === CLOCK_HEALTH_SAMPLES) this.#finishBatch();
    else this.#sendNext();
    return true;
  }

  #beginBatch() {
    this.#cancelBatch();
    this.scheduler.clearTimeout(this.refreshTimer);
    this.refreshTimer = null;
    this.refreshPending = false;
    this.batch += 1;
    this.batchGeneration = this.getGeneration();
    this.samples = [];
    this.dispatch({ type: 'clock.started' });
    this.#sendNext();
  }

  #sendNext() {
    const batch = this.batch;
    const request = Object.freeze({
      type: 'time.sync.request',
      v: PROTOCOL_VERSION,
      syncId: this.idGenerator(),
      phoneSendUnixMs: this.clock.now(),
    });
    this.pending = request;
    if (!this.sendSync(request)) {
      this.#unavailable(batch);
      return;
    }
    this.exchangeTimer = this.scheduler.setTimeout(() => this.#unavailable(batch),
      CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS);
  }

  #unavailable(batch) {
    if (batch !== this.batch || !this.pending) return;
    this.scheduler.clearTimeout(this.exchangeTimer);
    this.exchangeTimer = null;
    this.pending = null;
    this.samples = [];
    this.dispatch({ type: 'clock.unavailable' });
  }

  #finishBatch() {
    const best = bestSample(this.samples);
    if (!best) {
      this.#unavailable(this.batch);
      return;
    }
    const measuredAtUnixMs = this.clock.now();
    this.latest = Object.freeze({
      offsetMs: best.offsetMs,
      uncertaintyMs: best.rttMs / 2,
      measuredAtUnixMs,
    });
    this.dispatch({
      type: 'clock.health',
      healthy: clockHealthy(best.offsetMs, best.rttMs, CLOCK_SKEW_TOLERANCE_MS),
      offsetMs: best.offsetMs,
      uncertaintyMs: best.rttMs / 2,
      measuredAtUnixMs,
    });
    this.samples = [];
    this.pending = null;
    this.#scheduleRefresh();
  }

  #scheduleRefresh() {
    this.scheduler.clearTimeout(this.refreshTimer);
    this.refreshTimer = this.scheduler.setTimeout(() => {
      this.refreshTimer = null;
      if (this.isActionBusy()) {
        this.refreshPending = true;
        return;
      }
      this.#beginBatch();
    }, CLOCK_HEALTH_REFRESH_MS);
  }

  #cancelBatch() {
    this.batch += 1;
    this.scheduler.clearTimeout(this.exchangeTimer);
    this.exchangeTimer = null;
    this.pending = null;
    this.samples = [];
    this.batchGeneration = null;
  }
}
