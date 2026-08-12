import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import * as nodeProtocol from '../src/protocol.js';
import * as browserProtocol from '../public/wire-protocol.js';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '../../contracts/fixtures');
const load = (name) => readFileSync(join(FIXTURES, name), 'utf8').trim();

test('the Node protocol entry point is the browser-safe contract, not a duplicate', () => {
  for (const name of [
    'parseClientMessage',
    'parseServerMessage',
    'encodeMessage',
    'actionFingerprint',
    'isExpired',
    'ProtocolError',
  ]) {
    assert.equal(nodeProtocol[name], browserProtocol[name], `${name} must be a direct re-export`);
  }
});

test('the shared browser-safe parser accepts every server-to-phone fixture', () => {
  const accepted = new Set([
    'hello.ok',
    'heartbeat.ack',
    'state',
    'relay.ack',
    'action.result',
    'diagnostics.counters',
    'time.sync.response',
  ]);
  let count = 0;
  for (const name of readdirSync(FIXTURES).filter((entry) => entry.endsWith('.json'))) {
    const raw = load(name);
    if (!accepted.has(JSON.parse(raw).type)) continue;
    const parsed = JSON.parse(raw);
    const role = parsed.type === 'hello.ok' ? parsed.role : 'phone';
    const message = browserProtocol.parseServerMessage(raw, role);
    assert.equal(browserProtocol.encodeMessage(message), raw, name);
    count += 1;
  }
  assert.ok(count >= 15, `expected complete phone-server corpus, checked ${count}`);
});

test('wrong-role inbound messages fail identically through both import paths', () => {
  const raw = load('mac.state.json');
  for (const parser of [nodeProtocol.parseClientMessage, browserProtocol.parseClientMessage]) {
    assert.throws(
      () => parser(raw, 'phone'),
      (error) => error instanceof browserProtocol.ProtocolError
        && error.code === 'message_not_allowed_for_role',
    );
  }
});
