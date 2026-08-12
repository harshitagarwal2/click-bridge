export const MEASUREMENT_COLUMNS = Object.freeze([
  'runId', 'condition', 'blockIndex', 'sampleIndex', 'network', 'scheduledIdleSeconds',
  'actualIdleMs', 'keepWarm', 'normalHeartbeat', 'tailscaleRoute', 'pathsSent', 'actionId',
  'activationUnixMs', 'mouseDownPostedUnixMs', 'clockOffsetMs', 'clockRttMs',
  'clockUncertaintyMs', 'estimatedActuationMs', 'ackMs', 'confirmationMs',
  'relayProcessingUs', 'macProcessingUs', 'acceptedVia', 'firstResultVia',
  'lateResultCount', 'status', 'reason',
]);

export const RUN_EVIDENCE_COLUMNS = Object.freeze([
  'runId', 'startMouseDownPostCount', 'startMouseUpPostCount', 'endMouseDownPostCount',
  'endMouseUpPostCount', 'octoCounterStart', 'octoCounterEnd', 'logicalActionCount',
]);

export function createIdleSchedule({ random = Math.random } = {}) {
  const values = [...Array(70).fill(2), ...Array(20).fill(15), ...Array(10).fill(60)];
  for (let index = values.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(random() * (index + 1));
    [values[index], values[swap]] = [values[swap], values[index]];
  }
  return Object.freeze(values);
}

export class BenchmarkRunSequence {
  constructor({ schedule, warmups = 10, monotonicNow = () => performance.now(), blockIndex = 1 }) {
    this.schedule = schedule;
    this.warmups = warmups;
    this.monotonicNow = monotonicNow;
    this.blockIndex = blockIndex;
    this.terminals = 0;
    this.suspended = false;
    this.eligibleAtMonotonicMs = warmups === 0
      ? this.monotonicNow() + this.schedule[0] * 1_000 : 0;
  }
  get complete() { return this.terminals >= this.warmups + this.schedule.length; }
  current() {
    if (this.terminals < this.warmups) return Object.freeze({ recorded: false,
      eligible: !this.suspended, remainingMs: 0 });
    const index = this.terminals - this.warmups;
    const remainingMs = this.suspended ? this.schedule[index] * 1_000
      : Math.max(0, this.eligibleAtMonotonicMs - this.monotonicNow());
    return Object.freeze({ recorded: true, sampleIndex: index + 1, blockIndex: this.blockIndex,
      scheduledIdleSeconds: this.schedule[index], eligible: remainingMs === 0, remainingMs });
  }
  suspend() { this.suspended = true; }
  resume() {
    if (!this.suspended) return;
    this.suspended = false;
    if (!this.complete && this.terminals >= this.warmups) {
      const index = this.terminals - this.warmups;
      this.eligibleAtMonotonicMs = this.monotonicNow() + this.schedule[index] * 1_000;
    }
  }
  terminal() {
    if (this.complete) return;
    this.terminals += 1;
    if (!this.complete && this.terminals >= this.warmups) {
      const index = this.terminals - this.warmups;
      this.eligibleAtMonotonicMs = this.monotonicNow() + this.schedule[index] * 1_000;
    }
  }
}

export function counterDelta(start, end) {
  const delta = {
    mouseDownPostCount: end.mouseDownPostCount - start.mouseDownPostCount,
    mouseUpPostCount: end.mouseUpPostCount - start.mouseUpPostCount,
  };
  if (delta.mouseDownPostCount < 0 || delta.mouseUpPostCount < 0) {
    throw new Error('diagnostic counter regression');
  }
  return Object.freeze(delta);
}

export class CounterSnapshotRequester {
  constructor({ request }) { this.request = request; }
  async capture() {
    const snapshot = await this.request();
    for (const key of ['mouseDownPostCount', 'mouseUpPostCount']) {
      if (!Number.isSafeInteger(snapshot?.[key]) || snapshot[key] < 0) {
        throw new Error('invalid diagnostic counter snapshot');
      }
    }
    return Object.freeze({ mouseDownPostCount: snapshot.mouseDownPostCount,
      mouseUpPostCount: snapshot.mouseUpPostCount });
  }
  validateExactRun({ start, end, expectedPostCount, octoCounterStart, octoCounterEnd }) {
    const delta = counterDelta(start, end);
    const octoDelta = octoCounterEnd - octoCounterStart;
    if (!Number.isSafeInteger(expectedPostCount) || expectedPostCount < 0
      || !Number.isSafeInteger(octoCounterStart) || !Number.isSafeInteger(octoCounterEnd)
      || delta.mouseDownPostCount !== expectedPostCount
      || delta.mouseUpPostCount !== expectedPostCount || octoDelta !== expectedPostCount) {
      throw new Error('exact post evidence does not match logical actions');
    }
    return delta;
  }
}

export class BenchmarkRequestRouter {
  constructor({ send, getGeneration, scheduler, epochNow, idGenerator = () => crypto.randomUUID(), timeoutMs = 3_500 }) {
    this.send = send;
    this.getGeneration = getGeneration;
    this.scheduler = scheduler;
    this.epochNow = epochNow;
    this.idGenerator = idGenerator;
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
  }
  get pendingCount() { return this.pending.size; }
  exchangeTimeSync() {
    const syncId = this.idGenerator();
    const phoneSendUnixMs = this.epochNow();
    return this.#request(syncId, 'time.sync.response',
      { type: 'time.sync.request', v: 1, syncId, phoneSendUnixMs },
      (message) => ({ t0: phoneSendUnixMs, t1: message.macReceiveUnixMs,
        t2: message.macSendUnixMs, t3: this.epochNow() }));
  }
  requestCounters() {
    const requestId = this.idGenerator();
    return this.#request(requestId, 'diagnostics.counters',
      { type: 'diagnostics.request', v: 1, requestId }, (message) => message);
  }
  handle(message, generation) {
    const id = message.syncId ?? message.requestId;
    const pending = this.pending.get(id);
    if (!pending || pending.type !== message.type || pending.generation !== generation
      || this.getGeneration() !== generation) return false;
    this.pending.delete(id);
    this.scheduler.clearTimeout(pending.timer);
    pending.resolve(pending.transform(message));
    return true;
  }
  cancelGeneration(generation, reason = 'transport changed') {
    for (const [id, pending] of this.pending) {
      if (pending.generation !== generation) continue;
      this.pending.delete(id);
      this.scheduler.clearTimeout(pending.timer);
      pending.reject(new Error(`benchmark request canceled: ${reason}`));
    }
  }
  cancelAll(reason = 'transport changed') {
    for (const generation of new Set([...this.pending.values()].map((value) => value.generation))) {
      this.cancelGeneration(generation, reason);
    }
  }
  #request(id, type, message, transform) {
    const generation = this.getGeneration();
    return new Promise((resolve, reject) => {
      const timer = this.scheduler.setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('benchmark diagnostic response timed out'));
      }, this.timeoutMs);
      this.pending.set(id, { generation, type, timer, resolve, reject, transform });
      if (!this.send(message)) {
        this.pending.delete(id);
        this.scheduler.clearTimeout(timer);
        reject(new Error('benchmark transport unavailable'));
      }
    });
  }
}

function csvCell(value) {
  if (value === null || value === undefined) return '';
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export function rowsToCsv(rows, columns) {
  return `${[columns.join(','), ...rows.map((row) => columns.map((key) => csvCell(row[key])).join(','))].join('\n')}\n`;
}

export function alignmentFromExchange({ t0, t1, t2, t3 }) {
  if (![t0, t1, t2, t3].every(Number.isFinite) || t3 < t0 || t2 < t1) return null;
  const rttMs = (t3 - t0) - (t2 - t1);
  if (rttMs < 0) return null;
  return Object.freeze({
    offsetMs: ((t1 - t0) + (t2 - t3)) / 2,
    rttMs,
    uncertaintyMs: rttMs / 2,
  });
}

export class BenchmarkSession {
  constructor({ exchangeTimeSync, counterSnapshots, isActionPending = () => false,
    expectedRecordedActions = 100 }) {
    this.exchangeTimeSync = exchangeTimeSync;
    this.counterSnapshots = counterSnapshots;
    this.isActionPending = isActionPending;
    this.expectedRecordedActions = expectedRecordedActions;
    this.alignment = null;
    this.rows = [];
    this.evidence = [];
    this.run = null;
    this.actionsSinceAlignment = 0;
    this.excludedActions = 0;
    this.excludedPosted = 0;
  }

  async start({ runId, condition }) {
    if (this.isActionPending()) throw new Error('cannot start benchmark with a pending action');
    const alignment = await this.#collectAlignment();
    if (!alignment) throw new Error('benchmark alignment unavailable');
    this.alignment = alignment;
    const start = await this.counterSnapshots.capture();
    this.run = { runId, condition, start, rowStart: this.rows.length };
    this.actionsSinceAlignment = 0;
    this.excludedActions = 0;
    this.excludedPosted = 0;
  }

  async refreshIfDue({ force = false } = {}) {
    if (!force && this.actionsSinceAlignment < 25) return false;
    const alignment = await this.#collectAlignment();
    if (!alignment) throw new Error('benchmark alignment unavailable');
    this.alignment = alignment;
    this.actionsSinceAlignment = 0;
    return true;
  }

  recordTerminal(values) {
    if (!this.run) throw new Error('benchmark session not started');
    const alignment = this.alignment;
    const activation = Number(values.activationUnixMs);
    const posted = Number(values.mouseDownPostedUnixMs);
    const canEstimate = values.status === 'Posted' && Number.isFinite(activation)
      && Number.isFinite(posted) && alignment;
    this.rows.push(Object.freeze({
      ...Object.fromEntries(MEASUREMENT_COLUMNS.map((key) => [key, ''])),
      ...values,
      runId: this.run.runId,
      condition: this.run.condition,
      sampleIndex: values.sampleIndex ?? this.rows.length + 1,
      clockOffsetMs: alignment?.offsetMs ?? '',
      clockRttMs: alignment?.rttMs ?? '',
      clockUncertaintyMs: alignment?.uncertaintyMs ?? '',
      estimatedActuationMs: canEstimate ? posted - alignment.offsetMs - activation : '',
      lateResultCount: values.lateResultCount ?? 0,
    }));
    this.actionsSinceAlignment += 1;
  }

  recordExcludedTerminal({ status }) {
    this.actionsSinceAlignment += 1;
    this.excludedActions += 1;
    if (status === 'posted' || status === 'Posted') this.excludedPosted += 1;
  }

  recordLateResult(actionId) {
    const index = this.rows.findLastIndex((candidate) => candidate.actionId === actionId);
    if (index < 0) return false;
    const row = this.rows[index];
    this.rows[index] = Object.freeze({ ...row,
      lateResultCount: Number(row.lateResultCount || 0) + 1 });
    return true;
  }

  async finish({ octoCounterStart, octoCounterEnd, logicalActionCount }) {
    if (!this.run) throw new Error('benchmark session not started');
    const end = await this.counterSnapshots.capture();
    const runRows = this.rows.slice(this.run.rowStart);
    if (runRows.length !== this.expectedRecordedActions) {
      throw new Error(`benchmark requires ${this.expectedRecordedActions} recorded actions`);
    }
    if (logicalActionCount !== runRows.length + this.excludedActions) {
      throw new Error('logical action evidence mismatch');
    }
    const expectedPostCount = this.excludedPosted
      + runRows.filter((row) => row.status === 'Posted').length;
    this.counterSnapshots.validateExactRun({ start: this.run.start, end, expectedPostCount,
      octoCounterStart, octoCounterEnd });
    this.evidence.push({
      runId: this.run.runId,
      startMouseDownPostCount: this.run.start.mouseDownPostCount,
      startMouseUpPostCount: this.run.start.mouseUpPostCount,
      endMouseDownPostCount: end.mouseDownPostCount,
      endMouseUpPostCount: end.mouseUpPostCount,
      octoCounterStart,
      octoCounterEnd,
      logicalActionCount,
    });
    this.run = null;
  }

  exportCsv() {
    return Object.freeze({
      measurements: rowsToCsv(this.rows, MEASUREMENT_COLUMNS),
      evidence: rowsToCsv(this.evidence, RUN_EVIDENCE_COLUMNS),
    });
  }

  async #collectAlignment() {
    const candidates = [];
    for (let index = 0; index < 20; index += 1) {
      const candidate = alignmentFromExchange(await this.exchangeTimeSync());
      if (candidate) candidates.push(candidate);
    }
    return candidates.sort((left, right) => left.rttMs - right.rttMs)[0] ?? null;
  }
}
