#!/usr/bin/env node
// End-to-end smoke: one phone + one Mac through a full round trip.
//
//   PHONE_TOKEN=<64hex> MAC_TOKEN=<64hex> \
//     node scripts/smoke-relay.mjs ws://127.0.0.1:8080/ws
//
// Asserts: authentication, state propagation, time-sync and diagnostics
// exchanges, one forwarded request, one terminal result, and no fan-out to a
// second unauthenticated Mac connection.

import { WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';
import { PROTOCOL_VERSION, ACTION_LIFETIME_MS } from '../src/constants.js';

const url = process.argv[2] ?? 'ws://127.0.0.1:8080/ws';
const PHONE_TOKEN = process.env.PHONE_TOKEN ?? '';
const MAC_TOKEN = process.env.MAC_TOKEN ?? '';

if (!/^[0-9a-f]{64}$/.test(PHONE_TOKEN) || !/^[0-9a-f]{64}$/.test(MAC_TOKEN)) {
  console.error('PHONE_TOKEN and MAC_TOKEN must each be 64 lowercase hex characters');
  process.exit(2);
}

const checks = [];
const check = (name, ok) => {
  checks.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
};

function connect(label) {
  const ws = new WebSocket(url);
  const inbox = [];
  const waiters = [];
  const openPromise = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].match(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
    }
  });
  return {
    label, ws, inbox,
    open: () => ws.readyState === WebSocket.OPEN ? Promise.resolve() : openPromise,
    send: (m) => ws.send(JSON.stringify(m)),
    wait(match, ms = 5000) {
      const hit = inbox.find(match);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error(`${label}: timeout`)), ms);
        waiters.push({ match, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    close: () => ws.close(),
  };
}

const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });

const phone = connect('phone');
const mac = connect('mac');
let mac2;

try {
  await Promise.all([phone.open(), mac.open()]);

  mac.send(hello('mac', MAC_TOKEN));
  await mac.wait((m) => m.type === 'hello.ok');
  check('mac authenticated', true);

  mac.send({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' });

  phone.send(hello('phone', PHONE_TOKEN));
  await phone.wait((m) => m.type === 'hello.ok');
  check('phone authenticated', true);

  const state = await phone.wait((m) => m.type === 'state' && m.macOnline && m.remoteEnabled);
  check('mac state reached the phone', state.permission === 'ready');

  // Clock alignment exchange.
  const syncId = randomUUID();
  const t0 = Date.now();
  phone.send({ type: 'time.sync.request', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs: t0 });
  const syncFwd = await mac.wait((m) => m.type === 'time.sync.request');
  mac.send({
    type: 'time.sync.response', v: PROTOCOL_VERSION, syncId: syncFwd.syncId,
    phoneSendUnixMs: syncFwd.phoneSendUnixMs,
    macReceiveUnixMs: Date.now(), macSendUnixMs: Date.now(),
  });
  await phone.wait((m) => m.type === 'time.sync.response');
  check('time sync round trip', true);

  // Diagnostic counter exchange.
  const requestId = randomUUID();
  phone.send({ type: 'diagnostics.request', v: PROTOCOL_VERSION, requestId });
  const diagnosticsRequest = await mac.wait(
    (m) => m.type === 'diagnostics.request' && m.requestId === requestId,
  );
  mac.send({
    type: 'diagnostics.counters', v: PROTOCOL_VERSION,
    requestId: diagnosticsRequest.requestId,
    mouseDownPostCount: 0, mouseUpPostCount: 0,
  });
  await phone.wait((m) => m.type === 'diagnostics.counters' && m.requestId === requestId);
  check('diagnostic counters round trip', true);

  // A second connected but unauthenticated Mac is not a relay participant and
  // must never receive authenticated traffic.
  mac2 = connect('mac2');
  await mac2.open();

  const issuedAtUnixMs = Date.now();
  const request = {
    type: 'action.request', v: PROTOCOL_VERSION,
    actionId: randomUUID(), action: 'click',
    issuedAtUnixMs, expiresAtUnixMs: issuedAtUnixMs + ACTION_LIFETIME_MS,
  };
  const sentAt = performance.now();
  phone.send(request);

  const ack = await phone.wait((m) => m.type === 'relay.ack');
  check('relay acknowledged as forwarded', ack.status === 'forwarded');
  check('ack carries the same actionId', ack.actionId === request.actionId);

  const delivered = await mac.wait((m) => m.type === 'action.request');
  check('request reached the current mac', delivered.actionId === request.actionId);
  await new Promise((resolve) => setTimeout(resolve, 100));
  check('second Mac connection received nothing', mac2.inbox.length === 0);

  mac.send({
    type: 'action.result', v: PROTOCOL_VERSION, actionId: request.actionId,
    status: 'posted', reason: 'ok', acceptedVia: 'oci',
    macProcessingUs: 800, mouseDownPostedUnixMs: Date.now(),
  });

  const result = await phone.wait((m) => m.type === 'action.result');
  const ms = performance.now() - sentAt;
  check('phone received a posted result', result.status === 'posted');
  check('result is not an ack', result.type === 'action.result');

  // Nothing replays.
  const before = phone.inbox.length;
  await new Promise((r) => setTimeout(r, 400));
  check('no replay after completion', phone.inbox.length === before);

  console.log(`\nround trip: ${ms.toFixed(1)} ms (loopback)`);
} catch (err) {
  check(`unexpected failure: ${err.message}`, false);
} finally {
  phone.close(); mac.close(); mac2?.close();
}

const failed = checks.filter((c) => !c.ok).length;
console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
process.exit(failed === 0 ? 0 : 1);
