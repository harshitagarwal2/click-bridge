import test from 'node:test';
import assert from 'node:assert/strict';

import { parseAndClearPairingFragment } from '../public/pairing-link.js';

const REFERENCE = '---_---_---_---_---_---_---_---_---_---_--8';

function subject(url) {
  const parsed = new URL(url);
  const calls = [];
  const history = {
    state: { retained: true },
    replaceState(...args) { calls.push(args); },
  };
  return { parsed, calls, history };
}

test('valid pairing links are scrubbed before their reference is returned', () => {
  const { parsed, calls, history } = subject(`https://click.example/pair#v=1&r=${REFERENCE}`);

  const result = parseAndClearPairingFragment(parsed, history, 'click.example');

  assert.deepEqual(calls, [[history.state, '', '/pair']]);
  assert.deepEqual(result, { pairingVersion: 1, reference: REFERENCE });
});

test('pairing link validation starts only after the fragment is scrubbed', () => {
  const calls = [];
  const location = {
    href: `https://click.example/pair#v=1&r=${REFERENCE}`,
    hash: `#v=1&r=${REFERENCE}`,
    get protocol() {
      assert.deepEqual(calls, [[null, '', '/pair']]);
      return 'https:';
    },
    host: 'click.example',
    pathname: '/pair',
    search: '',
  };
  const history = {
    state: null,
    replaceState: (...args) => calls.push(args),
  };

  assert.deepEqual(
    parseAndClearPairingFragment(location, history, 'click.example'),
    { pairingVersion: 1, reference: REFERENCE },
  );
});

test('browser fallback accepts only the exact HTTPS host and pairing paths', () => {
  for (const path of ['/pair', '/pair/web']) {
    const { parsed, history } = subject(`https://click.example${path}#v=1&r=${REFERENCE}`);
    assert.equal(parseAndClearPairingFragment(parsed, history, 'click.example').reference, REFERENCE);
  }

  for (const url of [
    `http://click.example/pair#v=1&r=${REFERENCE}`,
    `https://evil.example/pair#v=1&r=${REFERENCE}`,
    `https://click.example/pair/#v=1&r=${REFERENCE}`,
    `https://click.example/PAIR#v=1&r=${REFERENCE}`,
    `https://click.example/pair?x=1#v=1&r=${REFERENCE}`,
  ]) {
    const { parsed, history } = subject(url);
    assert.equal(parseAndClearPairingFragment(parsed, history, 'click.example'), null);
  }
});

test('userinfo is rejected after the pairing fragment is synchronously scrubbed', () => {
  const { parsed, calls, history } = subject(
    `https://user:pass@click.example/pair#v=1&r=${REFERENCE}`,
  );

  assert.equal(parseAndClearPairingFragment(parsed, history, 'click.example'), null);
  assert.deepEqual(calls, [[history.state, '', '/pair']]);
});

test('an empty query delimiter is rejected after the pairing fragment is synchronously scrubbed', () => {
  const { parsed, calls, history } = subject(`https://click.example/pair?#v=1&r=${REFERENCE}`);

  assert.equal(parseAndClearPairingFragment(parsed, history, 'click.example'), null);
  assert.deepEqual(calls, [[history.state, '', '/pair']]);
});

test('fragment requires exactly v=1 and one canonical reference field', () => {
  for (const fragment of [
    `r=${REFERENCE}&v=1`,
    `v=1&r=${REFERENCE}&extra=1`,
    `v=1&v=1&r=${REFERENCE}`,
    `v=2&r=${REFERENCE}`,
    `v=1&r=${'a'.repeat(42)}`,
    `v=1&r=${'A'.repeat(42)}B`,
    `v=1&r=${'A'.repeat(42)}%2B`,
    `v=1&r=${'A'.repeat(43)}%3D`,
  ]) {
    const { parsed, history } = subject(`https://click.example/pair#${fragment}`);
    assert.equal(parseAndClearPairingFragment(parsed, history, 'click.example'), null);
  }
});

test('512-byte link boundary is measured as UTF-8 and invalid input is still scrubbed', () => {
  const base = `https://click.example/pair#v=1&r=${REFERENCE}`;
  const location = {
    href: `${base}${'x'.repeat(512 - base.length - 2)}é`,
    hash: `#v=1&r=${REFERENCE}`,
    protocol: 'https:',
    host: 'click.example',
    pathname: '/pair',
    search: '',
  };
  const calls = [];
  const history = { state: null, replaceState: (...args) => calls.push(args) };

  assert.deepEqual(
    parseAndClearPairingFragment(location, history, 'click.example'),
    { pairingVersion: 1, reference: REFERENCE },
  );
  location.href += 'x';
  assert.equal(parseAndClearPairingFragment(location, history, 'click.example'), null);
  assert.deepEqual(calls, [[null, '', '/pair'], [null, '', '/pair']]);
});

test('length validation uses the original URL even though history scrubbing mutates location', () => {
  const location = {
    href: `https://click.example/pair#v=1&r=${REFERENCE}${'x'.repeat(512)}`,
    hash: `#v=1&r=${REFERENCE}`,
    protocol: 'https:',
    host: 'click.example',
    pathname: '/pair',
    search: '',
  };
  const history = {
    state: null,
    replaceState() { location.href = 'https://click.example/pair'; },
  };

  assert.equal(parseAndClearPairingFragment(location, history, 'click.example'), null);
});
