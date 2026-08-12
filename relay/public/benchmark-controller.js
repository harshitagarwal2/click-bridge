function terminalStatus(status) {
  if (status === 'posted') return 'Posted';
  if (status === 'Unknown') return 'Unknown';
  return 'Rejected';
}

export class BenchmarkController {
  constructor({ session, requests, scheduler, monotonicNow, createSequence,
    isActionPending = () => false, onRender = () => {} }) {
    this.session = session;
    this.requests = requests;
    this.scheduler = scheduler;
    this.monotonicNow = monotonicNow;
    this.createSequence = createSequence;
    this.isActionPending = isActionPending;
    this.onRender = onRender;
    this.active = false;
    this.refreshing = false;
    this.refreshRequired = false;
    this.sequence = null;
    this.drafts = new Map();
    this.idleStartedMonotonicMs = 0;
    this.eligibilityTimer = null;
  }

  get complete() { return this.sequence?.complete ?? false; }
  get current() { return this.sequence?.current() ?? null; }
  get canActivate() {
    return this.active && !this.refreshing && !this.complete && Boolean(this.current?.eligible);
  }

  async start({ runId, condition }) {
    if (this.active || this.refreshing) throw new Error('benchmark already active');
    this.refreshing = true;
    this.onRender();
    try {
      await this.session.start({ runId, condition });
      this.sequence = this.createSequence();
      this.idleStartedMonotonicMs = this.monotonicNow();
      this.active = true;
      this.refreshRequired = false;
      this.#scheduleEligibilityRender();
    } finally {
      this.refreshing = false;
      this.onRender();
    }
  }

  async handleMetric(metric, context = {}) {
    if (!this.active) return;
    if (metric.type === 'activation') {
      const current = this.current;
      this.drafts.set(metric.actionId, Object.freeze({ ...metric, ...context,
        recorded: current.recorded,
        scheduledIdleSeconds: current.scheduledIdleSeconds ?? '',
        actualIdleMs: this.monotonicNow() - this.idleStartedMonotonicMs,
        sampleIndex: current.sampleIndex ?? '', blockIndex: current.blockIndex ?? '' }));
      return;
    }
    if (metric.type === 'ack') {
      const draft = this.drafts.get(metric.actionId);
      if (draft) this.drafts.set(metric.actionId, Object.freeze({ ...draft, ...metric }));
      return;
    }
    if (metric.type === 'late-result') {
      this.session.recordLateResult(metric.actionId);
      this.onRender();
      return;
    }
    if (metric.type !== 'terminal') return;

    const draft = this.drafts.get(metric.actionId) ?? {};
    this.drafts.delete(metric.actionId);
    const { recorded, ...values } = draft;
    if (recorded) {
      this.session.recordTerminal({ ...values, ...metric, status: terminalStatus(metric.status) });
    } else {
      this.session.recordExcludedTerminal({ status: metric.status });
    }
    this.sequence.terminal();
    this.idleStartedMonotonicMs = this.monotonicNow();
    this.#scheduleEligibilityRender();
    await this.#refresh({ force: this.refreshRequired, resumeOnSuccess: this.sequence.suspended });
  }

  transportLost(reason) {
    this.requests.cancelAll(reason);
    this.drafts.clear();
    if (!this.active) return;
    this.refreshRequired = true;
    this.sequence.suspend();
    this.#clearEligibilityTimer();
    this.onRender();
  }

  async transportReady() {
    if (!this.active || !this.refreshRequired) return false;
    if (this.isActionPending()) {
      this.onRender();
      return false;
    }
    return this.#refresh({ force: true, resumeOnSuccess: true });
  }

  async finish(evidence) {
    if (!this.active || !this.complete) throw new Error('benchmark schedule is incomplete');
    this.refreshing = true;
    this.onRender();
    try {
      await this.session.finish({ ...evidence, logicalActionCount: this.sequence.terminals });
      this.active = false;
      this.refreshRequired = false;
      this.#clearEligibilityTimer();
    } finally {
      this.refreshing = false;
      this.onRender();
    }
  }

  exportCsv() { return this.session.exportCsv(); }

  async #refresh({ force, resumeOnSuccess }) {
    await Promise.resolve();
    if (!this.active || this.refreshing) {
      this.refreshRequired = true;
      this.onRender();
      return false;
    }
    if (this.isActionPending()) {
      this.refreshRequired = true;
      this.sequence.suspend();
      this.#clearEligibilityTimer();
      this.onRender();
      return false;
    }
    this.refreshing = true;
    this.onRender();
    try {
      const refreshed = await this.session.refreshIfDue({ force });
      if (resumeOnSuccess) {
        this.sequence.resume();
        this.idleStartedMonotonicMs = this.monotonicNow();
      }
      this.refreshRequired = false;
      this.#scheduleEligibilityRender();
      this.onRender();
      return refreshed;
    } catch (error) {
      this.refreshRequired = true;
      this.sequence.suspend();
      this.#clearEligibilityTimer();
      this.onRender();
      throw error;
    } finally {
      this.refreshing = false;
      this.onRender();
    }
  }

  #scheduleEligibilityRender() {
    this.#clearEligibilityTimer();
    if (!this.active || this.complete || this.sequence.suspended) {
      this.onRender();
      return;
    }
    const remainingMs = this.current.remainingMs;
    if (remainingMs > 0) {
      this.eligibilityTimer = this.scheduler.setTimeout(() => {
        this.eligibilityTimer = null;
        this.onRender();
      }, remainingMs);
    }
    this.onRender();
  }

  #clearEligibilityTimer() {
    if (this.eligibilityTimer !== null) this.scheduler.clearTimeout(this.eligibilityTimer);
    this.eligibilityTimer = null;
  }
}
