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
  constructor({ schedule, warmups = 10 }) {
    this.schedule = schedule;
    this.warmups = warmups;
    this.terminals = 0;
  }
  get complete() { return this.terminals >= this.warmups + this.schedule.length; }
  current() {
    if (this.terminals < this.warmups) return Object.freeze({ recorded: false });
    const index = this.terminals - this.warmups;
    return Object.freeze({ recorded: true, sampleIndex: index + 1,
      scheduledIdleSeconds: this.schedule[index] });
  }
  terminal() { if (!this.complete) this.terminals += 1; }
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
  constructor({ exchangeTimeSync, requestCounters, sendAction = null }) {
    this.exchangeTimeSync = exchangeTimeSync;
    this.requestCounters = requestCounters;
    this.sendAction = sendAction;
    this.alignment = null;
    this.rows = [];
    this.evidence = [];
    this.run = null;
    this.actionsSinceAlignment = 0;
  }

  async start({ runId, condition }) {
    const alignment = await this.#collectAlignment();
    if (!alignment) throw new Error('benchmark alignment unavailable');
    this.alignment = alignment;
    const start = await this.requestCounters();
    this.run = { runId, condition, start };
    this.actionsSinceAlignment = 0;
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
    this.rows.push({
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
    });
    this.actionsSinceAlignment += 1;
  }

  recordExcludedTerminal() { this.actionsSinceAlignment += 1; }

  recordLateResult(actionId) {
    const row = this.rows.findLast((candidate) => candidate.actionId === actionId);
    if (!row) return false;
    row.lateResultCount = Number(row.lateResultCount || 0) + 1;
    return true;
  }

  async finish({ octoCounterStart, octoCounterEnd, logicalActionCount }) {
    if (!this.run) throw new Error('benchmark session not started');
    const end = await this.requestCounters();
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
