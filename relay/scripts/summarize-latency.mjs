#!/usr/bin/env node
// Summarise benchmark CSV honestly.
//
//   node scripts/summarize-latency.mjs ../benchmarks/measurements.csv
//
// Rules enforced here, not left to discipline:
//   - latency percentiles include ONLY Posted rows
//   - Rejected and Unknown stay in the reliability totals
//   - no outlier is ever removed
//   - a group under 100 samples gets median/max/count but NO p95 or p99
//   - a derived estimate is dropped when its raw clock fields are missing

export const REQUIRED_COLUMNS = [
  'runId', 'condition', 'blockIndex', 'sampleIndex', 'network',
  'scheduledIdleSeconds', 'actualIdleMs', 'keepWarm', 'normalHeartbeat',
  'tailscaleRoute', 'pathsSent', 'actionId', 'activationUnixMs',
  'mouseDownPostedUnixMs', 'clockOffsetMs', 'clockRttMs', 'clockUncertaintyMs',
  'estimatedActuationMs', 'ackMs', 'confirmationMs', 'relayProcessingUs',
  'macProcessingUs', 'acceptedVia', 'firstResultVia', 'lateResultCount',
  'status', 'reason', 'mouseDownPosts', 'mouseUpPosts',
];

/** Minimum samples before a high percentile may be claimed at all. */
export const PERCENTILE_MIN_SAMPLES = 100;

/** Nearest-rank percentile. `p` in (0,1]. Input need not be sorted. */
export function nearestRank(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil(p * sorted.length);
  return sorted[Math.min(Math.max(rank, 1), sorted.length) - 1];
}

export function parseCSV(text) {
  const lines = text.trim().split(/\r?\n/).filter(Boolean);
  if (!lines.length) return { header: [], rows: [] };
  const header = lines[0].split(',').map((h) => h.trim());
  const rows = lines.slice(1).map((line) => {
    const cells = line.split(',');
    return Object.fromEntries(header.map((h, i) => [h, (cells[i] ?? '').trim()]));
  });
  return { header, rows };
}

const num = (v) => {
  if (v === '' || v === undefined || v === null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/**
 * A derived actuation estimate is only valid when every raw input exists.
 * Never reconstruct it from a partially-filled row.
 */
export function derivedActuation(row) {
  const posted = num(row.mouseDownPostedUnixMs);
  const offset = num(row.clockOffsetMs);
  const activation = num(row.activationUnixMs);
  if (posted === null || offset === null || activation === null) return null;
  return posted - offset - activation;
}

export function summarizeGroup(rows) {
  const total = rows.length;
  const posted = rows.filter((r) => r.status === 'posted');
  const rejected = rows.filter((r) => r.status === 'rejected');
  const unknown = rows.filter((r) => r.status === 'unknown');

  const reasons = {};
  for (const r of [...rejected, ...unknown]) {
    if (!r.reason) continue;
    reasons[r.reason] = (reasons[r.reason] ?? 0) + 1;
  }

  // Only Posted rows may contribute to a latency figure.
  const confirmations = posted.map((r) => num(r.confirmationMs)).filter((v) => v !== null);
  const actuations = posted.map(derivedActuation).filter((v) => v !== null);
  const uncertainties = posted.map((r) => num(r.clockUncertaintyMs)).filter((v) => v !== null);

  const enough = posted.length >= PERCENTILE_MIN_SAMPLES;

  const stat = (values) => {
    if (!values.length) return null;
    return {
      count: values.length,
      median: nearestRank(values, 0.5),
      max: Math.max(...values),
      // Suppressed below the sample floor rather than quietly reported.
      p95: enough ? nearestRank(values, 0.95) : null,
      p99: enough ? nearestRank(values, 0.99) : null,
      percentilesSuppressed: !enough,
    };
  };

  return {
    total,
    postedCount: posted.length,
    rejectedCount: rejected.length,
    unknownCount: unknown.length,
    postedRate: total ? posted.length / total : 0,
    reasons,
    confirmationMs: stat(confirmations),
    estimatedActuationMs: stat(actuations),
    medianClockUncertaintyMs: uncertainties.length ? nearestRank(uncertainties, 0.5) : null,
    lateResults: rows.reduce((a, r) => a + (num(r.lateResultCount) ?? 0), 0),
    mouseDownPosts: rows.reduce((a, r) => a + (num(r.mouseDownPosts) ?? 0), 0),
    mouseUpPosts: rows.reduce((a, r) => a + (num(r.mouseUpPosts) ?? 0), 0),
  };
}

export function summarize(rows) {
  const byCondition = new Map();
  for (const r of rows) {
    const key = r.condition || '(unlabelled)';
    if (!byCondition.has(key)) byCondition.set(key, []);
    byCondition.get(key).push(r);
  }

  const conditions = {};
  for (const [name, group] of byCondition) {
    conditions[name] = summarizeGroup(group);

    // Idle subgroups are always small; they get medians, never a p95 claim.
    const subgroups = {};
    for (const r of group) {
      const k = `${r.scheduledIdleSeconds}s`;
      (subgroups[k] ??= []).push(r);
    }
    conditions[name].idleSubgroups = Object.fromEntries(
      Object.entries(subgroups).map(([k, v]) => [k, summarizeGroup(v)]),
    );
  }
  return { overall: summarizeGroup(rows), conditions };
}

function render(summary) {
  const line = (s) => console.log(s);
  const fmt = (v) => (v === null || v === undefined ? '—' : v.toFixed(1));

  const block = (name, s, indent = '') => {
    line(`${indent}${name}`);
    line(`${indent}  samples ${s.total}  posted ${s.postedCount}  `
      + `rejected ${s.rejectedCount}  unknown ${s.unknownCount}  `
      + `posted-rate ${(s.postedRate * 100).toFixed(1)}%`);

    for (const [key, label] of [['confirmationMs', 'confirmation'], ['estimatedActuationMs', 'actuation']]) {
      const st = s[key];
      if (!st) { line(`${indent}  ${label}: no usable samples`); continue; }
      const tail = st.percentilesSuppressed
        ? `  (p95/p99 suppressed: ${st.count} < ${PERCENTILE_MIN_SAMPLES} samples)`
        : `  p95 ${fmt(st.p95)}  p99 ${fmt(st.p99)}`;
      line(`${indent}  ${label}: n ${st.count}  median ${fmt(st.median)}  max ${fmt(st.max)}${tail}`);
    }

    if (s.medianClockUncertaintyMs !== null) {
      line(`${indent}  clock uncertainty (median): ±${fmt(s.medianClockUncertaintyMs)} ms`);
    }
    const reasons = Object.entries(s.reasons);
    if (reasons.length) {
      line(`${indent}  failures: ${reasons.map(([k, v]) => `${k}=${v}`).join('  ')}`);
    }
    if (s.mouseDownPosts || s.mouseUpPosts) {
      line(`${indent}  mac posts: down ${s.mouseDownPosts}  up ${s.mouseUpPosts}`);
    }
    if (s.lateResults) line(`${indent}  late results (diagnostics): ${s.lateResults}`);
  };

  line('');
  block('OVERALL', summary.overall);
  for (const [name, s] of Object.entries(summary.conditions)) {
    line('');
    block(`CONDITION: ${name}`, s);
    for (const [k, sub] of Object.entries(s.idleSubgroups ?? {})) {
      line('');
      block(`idle ${k}`, sub, '    ');
    }
  }
  line('');
}

// -- CLI ---------------------------------------------------------------------

const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;

if (isMain) {
  const { readFileSync } = await import('node:fs');
  const path = process.argv[2];
  if (!path) {
    console.error('usage: node scripts/summarize-latency.mjs <measurements.csv>');
    process.exit(2);
  }
  const { header, rows } = parseCSV(readFileSync(path, 'utf8'));

  const missing = REQUIRED_COLUMNS.filter((c) => !header.includes(c));
  if (missing.length) {
    console.error(`missing required columns: ${missing.join(', ')}`);
    process.exit(1);
  }
  if (!rows.length) {
    console.error('no data rows');
    process.exit(1);
  }
  render(summarize(rows));
}
