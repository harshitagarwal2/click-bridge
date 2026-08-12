import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export function nearestRank(values, percentile) {
  if (values.length === 0) return null;
  const sorted = values.map(Number).filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  return sorted[Math.max(0, Math.ceil(percentile * sorted.length) - 1)];
}

export function parseCsv(text) {
  const records = [];
  let row = [], cell = '', quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quoted && char === '"' && text[index + 1] === '"') { cell += '"'; index += 1; }
    else if (char === '"') quoted = !quoted;
    else if (char === ',' && !quoted) { row.push(cell); cell = ''; }
    else if ((char === '\n' || char === '\r') && !quoted) {
      if (char === '\r' && text[index + 1] === '\n') index += 1;
      row.push(cell); cell = '';
      if (row.some((value) => value !== '')) records.push(row);
      row = [];
    } else cell += char;
  }
  if (cell || row.length) { row.push(cell); records.push(row); }
  const [header = [], ...values] = records;
  return values.map((record) => Object.fromEntries(header.map((key, index) => [key, record[index] ?? ''])));
}

function measuredValue(row) {
  const explicit = Number(row.estimatedActuationMs);
  if (row.estimatedActuationMs !== '' && Number.isFinite(explicit)) return explicit;
  const activation = Number(row.activationUnixMs);
  const posted = Number(row.mouseDownPostedUnixMs);
  const offset = Number(row.clockOffsetMs);
  if ([row.activationUnixMs, row.mouseDownPostedUnixMs, row.clockOffsetMs].some((value) => value === '')) return null;
  return [activation, posted, offset].every(Number.isFinite) ? posted - offset - activation : null;
}

export function summarizeRows(rows) {
  const normalizedStatus = (row) => String(row.status).toLowerCase();
  const totals = {
    attempts: rows.length,
    posted: rows.filter((row) => normalizedStatus(row) === 'posted').length,
    rejected: rows.filter((row) => normalizedStatus(row) === 'rejected').length,
    unknown: rows.filter((row) => normalizedStatus(row) === 'unknown').length,
  };
  const names = [...new Set(rows.map((row) => row.condition))].sort();
  const conditions = names.map((name) => {
    const all = rows.filter((row) => row.condition === name);
    const postedRows = all.filter((row) => normalizedStatus(row) === 'posted');
    const measured = postedRows.map(measuredValue).filter(Number.isFinite);
    const failures = all.filter((row) => normalizedStatus(row) !== 'posted');
    const reasons = {};
    for (const row of failures) reasons[row.reason || 'unspecified'] = (reasons[row.reason || 'unspecified'] ?? 0) + 1;
    const subgroups = Object.fromEntries(['2', '15', '60'].map((seconds) => {
      const raw = postedRows.filter((row) => String(row.scheduledIdleSeconds) === seconds)
        .map(measuredValue).filter(Number.isFinite);
      return [seconds, { count: raw.length, median: nearestRank(raw, 0.5), maximum: raw.length ? Math.max(...raw) : null, raw }];
    }));
    return {
      condition: name, attempts: all.length, posted: postedRows.length, measuredPosted: measured.length,
      rejected: failures.filter((row) => normalizedStatus(row) === 'rejected').length,
      unknown: failures.filter((row) => normalizedStatus(row) === 'unknown').length,
      p50: nearestRank(measured, 0.5),
      p95: postedRows.length >= 95 && measured.length >= 95 ? nearestRank(measured, 0.95) : null,
      p99: postedRows.length >= 95 && measured.length >= 95 ? nearestRank(measured, 0.99) : null,
      maximum: measured.length ? Math.max(...measured) : null,
      reasons, subgroups,
    };
  });
  return { totals, conditions };
}

export function formatSummary(summary) {
  const lines = ['# Latency report', '', `Attempts: ${summary.totals.attempts}; Posted: ${summary.totals.posted}; Rejected: ${summary.totals.rejected}; Unknown: ${summary.totals.unknown}.`, ''];
  if (summary.totals.attempts === 0) {
    lines.push('Physical and latency acceptance: **NOT RUN**. The measurements file is header-only; no latency claim is made.', '');
  }
  for (const condition of summary.conditions) {
    lines.push(`## ${condition.condition}`, '', `Posted denominator: ${condition.posted}/${condition.attempts}.`,
      `p50: ${condition.p50 ?? 'unavailable'} ms; p95: ${condition.p95 ?? 'unavailable'} ms; p99: ${condition.p99 ?? 'unavailable'} ms; maximum: ${condition.maximum ?? 'unavailable'} ms.`,
      `Failures: ${JSON.stringify(condition.reasons)}.`, '');
    for (const seconds of ['2', '15', '60']) {
      const group = condition.subgroups[seconds];
      lines.push(`- ${seconds}s idle: count ${group.count}, median ${group.median ?? 'unavailable'} ms, maximum ${group.maximum ?? 'unavailable'} ms; raw [${group.raw.join(', ')}]`);
    }
    lines.push('');
  }
  return `${lines.join('\n').trimEnd()}\n`;
}

async function main(path) {
  const rows = parseCsv(await readFile(path, 'utf8'));
  process.stdout.write(formatSummary(summarizeRows(rows)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const path = process.argv[2];
  if (!path) throw new Error('usage: summarize-latency.mjs <measurements.csv>');
  await main(path);
}
