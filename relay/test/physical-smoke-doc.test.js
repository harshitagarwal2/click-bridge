import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const guideURL = new URL('../../docs/physical-smoke-test.md', import.meta.url);

async function guide() {
  return readFile(guideURL, 'utf8');
}

function section(markdown, heading, nextHeading) {
  const start = markdown.indexOf(`## ${heading}`);
  assert.notEqual(start, -1, `missing ${heading} section`);
  const end = nextHeading ? markdown.indexOf(`## ${nextHeading}`, start + 1) : markdown.length;
  assert.notEqual(end, -1, `missing ${nextHeading} section`);
  return markdown.slice(start, end);
}

function scenarios(markdownSection) {
  return [...markdownSection.matchAll(/^\| ([^|]+) \| ([^|]+) \|$/gm)]
    .map(([, scenario, result]) => ({ scenario: scenario.trim(), result: result.trim() }))
    .filter(({ scenario }) => scenario !== 'Scenario' && !/^[-: ]+$/.test(scenario));
}

test('physical clock acceptance requires a fresh five-response gate and explicit retry', async () => {
  const markdown = await guide();
  const physical = scenarios(section(markdown, 'Physical Release-client matrix',
    'Controlled negative-harness matrix'));
  const byName = new Map(physical.map((row) => [row.scenario, row.result]));

  assert.match(byName.get('Initial clock health') ?? '', /Ready only after five valid sync responses/i);
  assert.match(byName.get('Initial clock health') ?? '', /unusable response does not count/i);
  assert.match(byName.get('Clock sync response missing') ?? '', /3\.5 seconds/);
  assert.match(byName.get('Clock sync response missing') ?? '', /Clock check unavailable/);
  assert.match(byName.get('Clock sync response missing') ?? '', /Retry/);
  assert.match(byName.get('Clock sync response missing') ?? '', /no action/i);
  assert.match(byName.get('Retry clock check') ?? '', /fresh five-sample batch/i);
  assert.match(byName.get('Retry clock check') ?? '', /no action/i);
});

test('controlled matrix is isolated from the regular phone and records runner evidence', async () => {
  const markdown = await guide();
  const controlledSection = section(markdown, 'Controlled negative-harness matrix',
    'Automated-only acceptance');
  const controlledRows = scenarios(controlledSection);
  const controlled = controlledRows.map((row) => row.scenario);

  assert.deepEqual(controlled, [
    'Duplicate action ID',
    'Same ID, changed payload',
    'Expired buffered request',
    'Result path drops after forwarding',
  ]);
  assert.match(controlledSection, /regular phone client.*disconnected/i);
  assert.match(controlledSection, /relay\/scripts\/run-negative-matrix\.mjs/);
  assert.match(controlledSection, /CLICK_BRIDGE_URL/);
  assert.match(controlledSection, /PHONE_TOKEN/);
  assert.match(controlledSection,
    /prompts for[\s\S]*before count[\s\S]*runs the scenario[\s\S]*then prompts[\s\S]*after count/i);
  assert.doesNotMatch(controlledSection, /NEGATIVE_MATRIX_OCTO_OBSERVATIONS/);
  assert.match(controlledRows.find((row) => row.scenario === 'Same ID, changed payload')?.result ?? '',
    /setup burst.*\+3.*no second increment/i);
  assert.match(controlledSection, /JSON report/i);
});

test('event creation failure remains automated and the scenario union stays complete', async () => {
  const markdown = await guide();
  const physicalSection = section(markdown, 'Physical Release-client matrix',
    'Controlled negative-harness matrix');
  const controlledSection = section(markdown, 'Controlled negative-harness matrix',
    'Automated-only acceptance');
  const automatedSection = section(markdown, 'Automated-only acceptance',
    'Octo down/up gap calibration');
  const combined = [...scenarios(physicalSection), ...scenarios(controlledSection)];

  assert.equal(combined.length, 21);
  assert.equal(new Set(combined.map((row) => row.scenario)).size, 21);
  assert.doesNotMatch(physicalSection, /event creation fail/i);
  assert.doesNotMatch(controlledSection, /event creation fail/i);
  assert.match(automatedSection, /event creation fail/i);
  assert.match(automatedSection, /ActionProcessorTests/);
  assert.equal((markdown.match(/\*\*NOT RUN\*\*/g) ?? []).length, 2);
});
