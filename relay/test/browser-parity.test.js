// The browser cannot import src/, so public/ carries its own copies of the
// constants and a narrowed validator. These tests fail the moment the two
// drift apart — which is the only thing that makes duplication safe.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import * as server from '../src/constants.js';
import * as browser from '../public/constants-lite.js';
import { parseServerMessage as parseFull } from '../src/protocol.js';
import { parseServerMessage as parseLite, SERVER_MESSAGE_TYPES } from '../public/protocol-lite.js';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '../../contracts/fixtures');
const files = readdirSync(FIX).filter((f) => f.endsWith('.json'));
const load = (f) => readFileSync(join(FIX, f), 'utf8').trim();

test('every browser constant matches the server value', () => {
  const shared = Object.keys(browser);
  assert.ok(shared.length >= 12, 'expected the browser mirror to be populated');
  for (const key of shared) {
    assert.equal(browser[key], server[key], `${key} drifted`);
  }
});

test('the lite validator accepts every server-originated fixture', () => {
  let checked = 0;
  for (const f of files) {
    const raw = load(f);
    const type = JSON.parse(raw).type;
    if (!SERVER_MESSAGE_TYPES.includes(type)) continue;
    assert.deepEqual(parseLite(raw), parseFull(raw), `${f} disagreed`);
    checked += 1;
  }
  assert.ok(checked >= 5, `expected several server messages, checked ${checked}`);
});

test('the lite validator refuses phone- and mac-originated types', () => {
  for (const f of files) {
    const raw = load(f);
    const type = JSON.parse(raw).type;
    if (SERVER_MESSAGE_TYPES.includes(type)) continue;
    assert.throws(() => parseLite(raw), /unknown_type/, `${type} should not reach the phone`);
  }
});

test('the lite validator rejects the same malformed input as the server', () => {
  const cases = ['{bad', '[]', '"x"', '{"type":"nope","v":1}', '{"type":"state","v":2}'];
  for (const raw of cases) {
    assert.throws(() => parseLite(raw), undefined, `lite accepted ${raw}`);
    assert.throws(() => parseFull(raw), undefined, `server accepted ${raw}`);
  }
});

test('the lite validator rejects unknown and missing fields', () => {
  const base = JSON.parse(load('state.json'));
  assert.throws(() => parseLite(JSON.stringify({ ...base, extra: 1 })), /unknown_field/);
  const missing = { ...base };
  delete missing.permission;
  assert.throws(() => parseLite(JSON.stringify(missing)), /missing_field/);
});

test('the lite validator enforces the posted/rejected result invariants', () => {
  const posted = JSON.parse(load('action.result.posted.json'));
  assert.throws(() => parseLite(JSON.stringify({ ...posted, reason: 'expired' })), /invalid_value/);
  assert.throws(
    () => parseLite(JSON.stringify({ ...posted, mouseDownPostedUnixMs: null })), /invalid_type/);

  const rejected = JSON.parse(load('action.result.rejected.json'));
  assert.throws(() => parseLite(JSON.stringify({ ...rejected, reason: 'ok' })), /invalid_value/);
  assert.throws(
    () => parseLite(JSON.stringify({ ...rejected, mouseDownPostedUnixMs: 5 })), /invalid_value/);
});

test('an oversized frame is rejected without TextEncoder differences', () => {
  const big = JSON.stringify({ ...JSON.parse(load('state.json')), pad: 'x'.repeat(5000) });
  assert.throws(() => parseLite(big), /unknown_field|message_too_large/);
});
