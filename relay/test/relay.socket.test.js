import http from 'node:http';
import { mkdtemp, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { WebSocket } from 'ws';

import {
  attachWebSocketServer,
  createServer,
} from '../src/server.js';
import { createContentSecurityPolicy } from '../src/csp.js';
import { parseClientMessage } from '../src/protocol.js';
import { ACTION_LIFETIME_MS, PROTOCOL_VERSION } from '../src/constants.js';

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const DOMAIN = 'relay.example.test';
const silent = { info() {}, error() {} };

const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });
const action = (overrides = {}) => {
  const issuedAtUnixMs = Date.now();
  return {
    type: 'action.request', v: PROTOCOL_VERSION,
    actionId: randomUUID(), action: 'click',
    issuedAtUnixMs, expiresAtUnixMs: issuedAtUnixMs + ACTION_LIFETIME_MS,
    ...overrides,
  };
};
const result = (actionId) => ({
  type: 'action.result', v: PROTOCOL_VERSION, actionId,
  status: 'posted', reason: 'ok', acceptedVia: 'oci',
  macProcessingUs: 800, mouseDownPostedUnixMs: Date.now(),
});

function client(url, options) {
  const ws = new WebSocket(url, options);
  const inbox = [];
  const waiters = [];
  let closedValue;
  let closeResolve;
  const openPromise = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  const closePromise = new Promise((resolve) => { closeResolve = resolve; });
  ws.on('close', (code) => {
    closedValue = code;
    closeResolve(code);
  });
  ws.on('message', (data) => {
    const message = JSON.parse(data.toString());
    inbox.push(message);
    for (let index = waiters.length - 1; index >= 0; index -= 1) {
      const waiter = waiters[index];
      if (waiter.match(message)) {
        waiters.splice(index, 1);
        waiter.resolve(message);
      }
    }
  });
  return {
    ws,
    inbox,
    open: () => ws.readyState === WebSocket.OPEN ? Promise.resolve() : openPromise,
    send: (message) => ws.send(JSON.stringify(message)),
    closed: () => closedValue === undefined ? closePromise : Promise.resolve(closedValue),
    wait(match, timeoutMs = 1500) {
      const found = inbox.find(match);
      if (found) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout waiting for message')), timeoutMs);
        waiters.push({
          match,
          resolve: (message) => {
            clearTimeout(timer);
            resolve(message);
          },
        });
      });
    },
  };
}

async function boot(overrides = {}) {
  const server = createServer({
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
    log: silent,
    ...overrides,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  return {
    server,
    base: `http://127.0.0.1:${port}`,
    url: `ws://127.0.0.1:${port}/ws`,
  };
}

async function authenticate(peer, role, token) {
  await peer.open();
  peer.send(hello(role, token));
  return peer.wait((message) => message.type === 'hello.ok');
}

test('startup rejects missing, malformed, identical tokens and invalid hostnames', () => {
  const valid = { phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN };
  assert.throws(() => createServer({ ...valid, phoneToken: '' }), /PHONE_TOKEN/);
  assert.throws(() => createServer({ ...valid, macToken: 'ABC' }), /MAC_TOKEN/);
  assert.throws(() => createServer({ ...valid, macToken: PHONE_TOKEN }), /must differ/);
  assert.throws(() => createServer({ ...valid, clickBridgeDomain: '' }), /CLICK_BRIDGE_DOMAIN/);
  for (const bad of ['https://relay.example', 'relay.example:443', 'relay.example/path', '.bad', 'bad..host']) {
    assert.throws(() => createServer({ ...valid, clickBridgeDomain: bad }), /CLICK_BRIDGE_DOMAIN/);
  }
  const localhost = createServer({ ...valid, clickBridgeDomain: 'localhost' });
  return localhost.close();
});

test('health and known static fixtures carry the single canonical CSP', async () => {
  const publicDir = await mkdtemp(join(tmpdir(), 'click-bridge-static-'));
  await mkdir(join(publicDir, 'icons'));
  await writeFile(join(publicDir, 'index.html'), '<script src="/app.js"></script>');
  await writeFile(join(publicDir, 'app.js'), 'globalThis.loaded = true;');
  await writeFile(join(publicDir, 'secret.txt'), 'must not be served');
  const { server, base } = await boot({ publicDir });
  const expected = createContentSecurityPolicy(DOMAIN);
  try {
    for (const path of ['/healthz', '/', '/app.js', '/missing.js']) {
      const response = await fetch(`${base}${path}`);
      assert.equal(response.headers.get('content-security-policy'), expected);
      assert.doesNotMatch(expected, /unsafe-inline|data:/);
    }
    assert.equal((await fetch(`${base}/`)).status, 200);
    assert.equal((await fetch(`${base}/app.js`)).headers.get('content-type'), 'text/javascript; charset=utf-8');
    assert.equal((await fetch(`${base}/secret.txt`)).status, 404, 'unknown files are never served');
  } finally {
    await server.close();
  }
});

test('the completed PWA dependency graph is reachable through the static allowlist', async () => {
  const { server, base } = await boot();
  try {
    for (const path of [
      '/',
      '/app.js',
      '/wire-protocol.js',
      '/runtime-constants.js',
      '/transport-controller.js',
      '/relay-transport.js',
      '/transport-coordinator.js',
      '/clock-health-controller.js',
      '/phone-settings-store.js',
      '/benchmark-session.js',
      '/benchmark-controller.js',
      '/state.js',
      '/styles.css',
      '/manifest.webmanifest',
      '/icons/icon-192.png',
      '/icons/icon-512.png',
      '/icons/apple-touch-icon-180.png',
    ]) {
      assert.equal((await fetch(`${base}${path}`)).status, 200, path);
    }
  } finally {
    await server.close();
  }
});

test('WebSocket upgrade is accepted only at /ws', async () => {
  const { server, base } = await boot();
  try {
    const rejected = client(`${base.replace('http:', 'ws:')}/not-ws`);
    await assert.rejects(rejected.open());
  } finally {
    await server.close();
  }
});

test('hello timeout closes an unauthenticated socket', async () => {
  const { server, url } = await boot({ authTimeoutMs: 25 });
  try {
    const peer = client(url);
    await peer.open();
    assert.equal(await peer.closed(), 4001);
  } finally {
    await server.close();
  }
});

test('wrong token, wrong-role token, and non-hello authentication are closed', async () => {
  const { server, url } = await boot();
  try {
    for (const first of [
      hello('phone', '9'.repeat(64)),
      hello('phone', MAC_TOKEN),
      { type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 1 },
    ]) {
      const peer = client(url);
      await peer.open();
      peer.send(first);
      assert.equal(await peer.closed(), 4003);
    }
  } finally {
    await server.close();
  }
});

test('same-role authentication replaces the old socket without clearing the replacement', async () => {
  const { server, url } = await boot();
  try {
    const first = client(url);
    await authenticate(first, 'phone', PHONE_TOKEN);
    const replacement = client(url);
    await authenticate(replacement, 'phone', PHONE_TOKEN);
    assert.equal(await first.closed(), 4000);
    assert.notEqual(server.state.phone, null);
    replacement.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 5 });
    assert.equal((await replacement.wait((m) => m.type === 'heartbeat.ack')).sequence, 5);
  } finally {
    await server.close();
  }
});

test('state, action ack, exactly-one forwarding, and terminal result complete a round trip', async () => {
  const { server, url } = await boot();
  try {
    const mac = client(url);
    const phone = client(url);
    await authenticate(mac, 'mac', MAC_TOKEN);
    mac.send({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' });
    await authenticate(phone, 'phone', PHONE_TOKEN);
    assert.deepEqual(
      await phone.wait((m) => m.type === 'state' && m.remoteEnabled),
      { type: 'state', v: PROTOCOL_VERSION, macOnline: true, remoteEnabled: true, permission: 'ready' },
    );

    const request = action();
    phone.send(request);
    const ack = await phone.wait((m) => m.type === 'relay.ack');
    assert.deepEqual(
      { actionId: ack.actionId, status: ack.status, reason: ack.reason },
      { actionId: request.actionId, status: 'forwarded', reason: 'ok' },
    );
    assert.ok(ack.relayProcessingUs >= 0);
    assert.equal((await mac.wait((m) => m.type === 'action.request')).actionId, request.actionId);
    assert.equal(mac.inbox.filter((m) => m.type === 'action.request').length, 1);

    mac.send(result(request.actionId));
    const terminal = await phone.wait((m) => m.type === 'action.result');
    assert.equal(terminal.status, 'posted');
    assert.equal(phone.inbox.filter((m) => m.type === 'relay.ack').length, 1);
    assert.equal(server.state.pendingActions.size, 0);

    mac.ws.close();
    assert.deepEqual(
      await phone.wait((m) => m.type === 'state' && !m.macOnline),
      { type: 'state', v: PROTOCOL_VERSION, macOnline: false, remoteEnabled: false, permission: 'unknown' },
    );
  } finally {
    await server.close();
  }
});

test('mac_offline and expired acknowledgements never forward or create a route', async () => {
  const { server, url } = await boot();
  try {
    const phone = client(url);
    await authenticate(phone, 'phone', PHONE_TOKEN);
    const offline = action();
    phone.send(offline);
    assert.deepEqual(
      (({ status, reason }) => ({ status, reason }))(
        await phone.wait((m) => m.type === 'relay.ack' && m.actionId === offline.actionId),
      ),
      { status: 'mac_offline', reason: 'mac_offline' },
    );

    const mac = client(url);
    await authenticate(mac, 'mac', MAC_TOKEN);
    const issuedAtUnixMs = Date.now() - ACTION_LIFETIME_MS - 1001;
    const expired = action({
      issuedAtUnixMs,
      expiresAtUnixMs: issuedAtUnixMs + ACTION_LIFETIME_MS,
    });
    phone.send(expired);
    assert.deepEqual(
      (({ status, reason }) => ({ status, reason }))(
        await phone.wait((m) => m.type === 'relay.ack' && m.actionId === expired.actionId),
      ),
      { status: 'rejected', reason: 'expired' },
    );
    assert.equal(mac.inbox.filter((m) => m.actionId === expired.actionId).length, 0);
    assert.equal(server.state.pendingActions.size, 0);
  } finally {
    await server.close();
  }
});

test('time-sync and diagnostic requests route live and expire', async () => {
  const { server, url } = await boot({ stateOptions: { pendingTtlMs: 30 } });
  try {
    const phone = client(url);
    const mac = client(url);
    await authenticate(phone, 'phone', PHONE_TOKEN);
    await authenticate(mac, 'mac', MAC_TOKEN);

    const syncId = randomUUID();
    const phoneSendUnixMs = Date.now();
    phone.send({ type: 'time.sync.request', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs });
    await mac.wait((m) => m.type === 'time.sync.request' && m.syncId === syncId);
    mac.send({
      type: 'time.sync.response', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs,
      macReceiveUnixMs: phoneSendUnixMs + 1, macSendUnixMs: phoneSendUnixMs + 2,
    });
    await phone.wait((m) => m.type === 'time.sync.response' && m.syncId === syncId);

    const requestId = randomUUID();
    phone.send({ type: 'diagnostics.request', v: PROTOCOL_VERSION, requestId });
    await mac.wait((m) => m.type === 'diagnostics.request' && m.requestId === requestId);
    mac.send({
      type: 'diagnostics.counters', v: PROTOCOL_VERSION, requestId,
      mouseDownPostCount: 1, mouseUpPostCount: 1,
    });
    await phone.wait((m) => m.type === 'diagnostics.counters' && m.requestId === requestId);

    const expiringId = randomUUID();
    phone.send({ type: 'diagnostics.request', v: PROTOCOL_VERSION, requestId: expiringId });
    await mac.wait((m) => m.type === 'diagnostics.request' && m.requestId === expiringId);
    await new Promise((resolve) => setTimeout(resolve, 50));
    mac.send({
      type: 'diagnostics.counters', v: PROTOCOL_VERSION, requestId: expiringId,
      mouseDownPostCount: 2, mouseUpPostCount: 2,
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(phone.inbox.some((m) => m.type === 'diagnostics.counters' && m.requestId === expiringId), false);
  } finally {
    await server.close();
  }
});

test('post-auth parser rejection has no state side effect and socket remains usable', async () => {
  const { server, url } = await boot();
  try {
    const phone = client(url);
    await authenticate(phone, 'phone', PHONE_TOKEN);
    phone.ws.send('{not-json');
    phone.ws.send(JSON.stringify({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' }));
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(server.state.macState.remoteEnabled, false);
    phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 99 });
    assert.equal((await phone.wait((m) => m.type === 'heartbeat.ack')).sequence, 99);
  } finally {
    await server.close();
  }
});

test('unexpected post-auth parser failure is reported and closes with 1011', async () => {
  const logs = [];
  const log = { info: (line) => logs.push(line) };
  const server = createServer({
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
    log,
    parseClient: (raw, role) => {
      if (role !== null) throw new Error('secret internal parser detail');
      return parseClientMessage(raw, role);
    },
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  const phone = client(`ws://127.0.0.1:${port}/ws`);
  try {
    await authenticate(phone, 'phone', PHONE_TOKEN);
    phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 1 });
    assert.equal(await phone.closed(), 1011);
    assert.ok(logs.some((line) => line.includes('message_internal_error')));
    assert.ok(logs.every((line) => !line.includes('secret internal parser detail')));
  } finally {
    await server.close();
  }
});

test('logs never contain tokens or complete hello payloads', async () => {
  const logs = [];
  const { server, url } = await boot({ log: { info: (line) => logs.push(line) } });
  try {
    const rejected = client(url);
    await rejected.open();
    rejected.send(hello('phone', MAC_TOKEN));
    await rejected.closed();

    const accepted = client(url);
    await authenticate(accepted, 'phone', PHONE_TOKEN);
    accepted.ws.send('{not-json');
    accepted.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 4 });
    await accepted.wait((message) => message.type === 'heartbeat.ack');

    const joined = logs.join('\n');
    assert.doesNotMatch(joined, new RegExp(PHONE_TOKEN));
    assert.doesNotMatch(joined, new RegExp(MAC_TOKEN));
    assert.doesNotMatch(joined, /\"type\":\"hello\"/);
    assert.match(joined, /bad_token/);
    assert.match(joined, /malformed_json/);
  } finally {
    await server.close();
  }
});

test('protocol ping timeout deterministically terminates a client that never pongs', async () => {
  const pingIntervalMs = 15;
  const pongTimeoutMs = 35;
  const { server, url } = await boot({ pingIntervalMs, pongTimeoutMs });
  try {
    const phone = client(url, { autoPong: false });
    await authenticate(phone, 'phone', PHONE_TOKEN);
    const startedAt = performance.now();
    assert.equal(await phone.closed(), 1006);
    const elapsedMs = performance.now() - startedAt;
    assert.ok(elapsedMs >= pongTimeoutMs, `terminated before pong deadline: ${elapsedMs}ms`);
    assert.ok(elapsedMs < 250, `ping timeout was not deterministic: ${elapsedMs}ms`);
  } finally {
    await server.close();
  }
});

test('each raw frame is parsed once and dispatched to exactly one role method', async () => {
  const calls = [];
  const stateCalls = [];
  const fakeState = {
    replaceRole(role, connection) { this[role] = connection; },
    detachIfCurrent() {},
    publishState() {},
    handlePhoneMessage(connection, message) { stateCalls.push({ role: 'phone', connection, message }); },
    handleMacMessage(connection, message) { stateCalls.push({ role: 'mac', connection, message }); },
  };
  const server = http.createServer((_req, res) => res.end());
  const attachment = attachWebSocketServer({
    httpServer: server,
    state: fakeState,
    connections: new Map(),
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    log: silent,
    parseClient: (raw, role) => {
      calls.push({ raw, role });
      return parseClientMessage(raw, role);
    },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const phone = client(`ws://127.0.0.1:${port}/ws`);
  try {
    await authenticate(phone, 'phone', PHONE_TOKEN);
    phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 7 });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(calls.map((call) => call.role), [null, 'phone']);
    assert.equal(stateCalls.length, 1);
    assert.equal(stateCalls[0].role, 'phone');
    assert.equal(stateCalls[0].message.sequence, 7);

    phone.ws.send('{bad');
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(calls.length, 3, 'rejected frame is still parsed exactly once');
    assert.equal(stateCalls.length, 1, 'parser failure never reaches RelayState');
  } finally {
    phone.ws.terminate();
    await attachment.close();
    await new Promise((resolve) => server.close(resolve));
  }
});

test('oversized frame is closed while the relay remains healthy', async () => {
  const { server, url, base } = await boot();
  try {
    const phone = client(url);
    await authenticate(phone, 'phone', PHONE_TOKEN);
    phone.ws.send('x'.repeat(5000));
    assert.equal(await phone.closed(), 1009);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  } finally {
    await server.close();
  }
});

test('restart has no route and performs no replay', async () => {
  const first = await boot();
  const phone = client(first.url);
  const mac = client(first.url);
  await authenticate(phone, 'phone', PHONE_TOKEN);
  await authenticate(mac, 'mac', MAC_TOKEN);
  const request = action();
  phone.send(request);
  await phone.wait((m) => m.type === 'relay.ack' && m.actionId === request.actionId);
  assert.equal(first.server.state.pendingActions.size, 1);
  await first.server.close();

  const second = await boot();
  try {
    assert.equal(second.server.state.pendingActions.size, 0);
    const newPhone = client(second.url);
    await authenticate(newPhone, 'phone', PHONE_TOKEN);
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(newPhone.inbox.some((m) => m.type === 'action.request' || m.type === 'action.result'), false);
    newPhone.ws.terminate();
  } finally {
    await second.server.close();
  }
});
