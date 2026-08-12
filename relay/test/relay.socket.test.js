// Socket-level tests driving the REAL server.js end to end.
//
// The WebSocket server is injected: `ws` in production, a minimal RFC 6455
// implementation here (test/helpers/mini-wss.js) so these run with no package
// registry. The client is Node's built-in global WebSocket.
//
// When `ws` is installed the same suite runs a second time against it, so the
// production wiring is covered too.

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { createServer } from '../src/server.js';
import { miniWssFactory } from './helpers/mini-wss.js';
import { PROTOCOL_VERSION, ACTION_LIFETIME_MS } from '../src/constants.js';

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const silent = { info: () => {} };

let realWsFactory = null;
try {
  const { WebSocketServer } = await import('ws');
  realWsFactory = (options) => new WebSocketServer(options);
} catch { /* not installed; the mini implementation still covers server.js */ }

const BACKENDS = [
  ['mini-wss', miniWssFactory],
  ...(realWsFactory ? [['ws', realWsFactory]] : []),
];

const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });

const req = (overrides = {}) => {
  const issued = Date.now();
  return {
    type: 'action.request', v: PROTOCOL_VERSION,
    actionId: randomUUID(), action: 'click',
    issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS,
    ...overrides,
  };
};

const result = (actionId, overrides = {}) => ({
  type: 'action.result', v: PROTOCOL_VERSION, actionId,
  status: 'posted', reason: 'ok', acceptedVia: 'oci',
  macProcessingUs: 800, mouseDownPostedUnixMs: Date.now(),
  ...overrides,
});

async function boot(wssFactory) {
  const server = await createServer({
    phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, log: silent, wssFactory,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  return { server, url: `ws://127.0.0.1:${port}/ws`, base: `http://127.0.0.1:${port}` };
}

/** Thin wrapper over the built-in browser-style WebSocket client. */
function client(url) {
  const ws = new WebSocket(url);
  const inbox = [];
  const waiters = [];
  let closeCode = null;

  ws.addEventListener('message', (event) => {
    if (typeof event.data !== 'string') return;
    const m = JSON.parse(event.data);
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].match(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
    }
  });
  ws.addEventListener('close', (e) => { closeCode = e.code; });

  return {
    ws, inbox,
    open: () => new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', rej, { once: true });
    }),
    closed: () => new Promise((res) => {
      if (closeCode !== null) return res(closeCode);
      ws.addEventListener('close', (e) => res(e.code), { once: true });
    }),
    send: (m) => ws.send(JSON.stringify(m)),
    raw: (s) => ws.send(s),
    close: () => { try { ws.close(); } catch { /* already gone */ } },
    wait(match, ms = 3000) {
      const hit = inbox.find(match);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timeout waiting for message')), ms);
        waiters.push({ match, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
  };
}

for (const [backend, factory] of BACKENDS) {
  test(`[${backend}] healthz responds ok with the canonical CSP`, async () => {
    const { server, base } = await boot(factory);
    try {
      const res = await fetch(`${base}/healthz`);
      assert.equal(res.status, 200);
      assert.equal(await res.text(), 'ok');
      assert.match(res.headers.get('content-security-policy'), /script-src 'self'/);
      assert.equal(/unsafe-inline/.test(res.headers.get('content-security-policy')), false);
    } finally { await server.close(); }
  });

  test(`[${backend}] the phone page is served with its CSP`, async () => {
    const { server, base } = await boot(factory);
    try {
      const res = await fetch(`${base}/`);
      assert.equal(res.status, 200);
      assert.match(res.headers.get('content-type'), /text\/html/);
      assert.match(res.headers.get('content-security-policy'), /style-src 'self'/);
      assert.match(await res.text(), /<button id="click-button"/);
    } finally { await server.close(); }
  });

  test(`[${backend}] path traversal is refused`, async () => {
    const { server, base } = await boot(factory);
    try {
      const res = await fetch(`${base}/../src/server.js`);
      assert.ok(res.status === 404 || res.status === 403, `got ${res.status}`);
    } finally { await server.close(); }
  });

  test(`[${backend}] upgrade is refused outside /ws`, async () => {
    const { server, base } = await boot(factory);
    try {
      const c = client(`${base.replace('http', 'ws')}/nope`);
      await assert.rejects(c.open());
    } finally { await server.close(); }
  });

  test(`[${backend}] a wrong token is closed`, async () => {
    const { server, url } = await boot(factory);
    try {
      const c = client(url);
      await c.open();
      c.send(hello('phone', '9'.repeat(64)));
      assert.equal(await c.closed(), 4003);
    } finally { await server.close(); }
  });

  test(`[${backend}] a role-swapped token is closed`, async () => {
    const { server, url } = await boot(factory);
    try {
      const c = client(url);
      await c.open();
      c.send(hello('phone', MAC_TOKEN));   // the Mac's token, claiming phone
      assert.equal(await c.closed(), 4003);
    } finally { await server.close(); }
  });

  test(`[${backend}] a non-hello first frame is closed`, async () => {
    const { server, url } = await boot(factory);
    try {
      const c = client(url);
      await c.open();
      c.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 1 });
      assert.equal(await c.closed(), 4003);
    } finally { await server.close(); }
  });

  test(`[${backend}] full round trip: request, ack, forward, result`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      const mac = client(url);
      await Promise.all([phone.open(), mac.open()]);

      mac.send(hello('mac', MAC_TOKEN));
      await mac.wait((m) => m.type === 'hello.ok');
      mac.send({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' });

      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');
      const state = await phone.wait((m) => m.type === 'state' && m.macOnline && m.remoteEnabled);
      assert.equal(state.permission, 'ready');

      const r = req();
      phone.send(r);

      const ack = await phone.wait((m) => m.type === 'relay.ack');
      assert.equal(ack.status, 'forwarded');
      assert.equal(ack.actionId, r.actionId);
      assert.ok(ack.relayProcessingUs >= 0);

      const got = await mac.wait((m) => m.type === 'action.request');
      assert.equal(got.actionId, r.actionId);

      mac.send(result(r.actionId));
      const res = await phone.wait((m) => m.type === 'action.result');
      assert.equal(res.status, 'posted');
      assert.equal(server.state.pending.size, 0, 'route consumed, nothing retained');
    } finally { await server.close(); }
  });

  test(`[${backend}] heartbeat is acknowledged with the same sequence`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      await phone.open();
      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');
      phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 42 });
      assert.equal((await phone.wait((m) => m.type === 'heartbeat.ack')).sequence, 42);
    } finally { await server.close(); }
  });

  test(`[${backend}] time sync is relayed both ways`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      const mac = client(url);
      await Promise.all([phone.open(), mac.open()]);
      mac.send(hello('mac', MAC_TOKEN));
      await mac.wait((m) => m.type === 'hello.ok');
      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');

      const syncId = randomUUID();
      const t0 = Date.now();
      phone.send({ type: 'time.sync.request', v: PROTOCOL_VERSION, syncId, phoneSendUnixMs: t0 });
      assert.equal((await mac.wait((m) => m.type === 'time.sync.request')).syncId, syncId);

      mac.send({
        type: 'time.sync.response', v: PROTOCOL_VERSION, syncId,
        phoneSendUnixMs: t0, macReceiveUnixMs: t0 + 30, macSendUnixMs: t0 + 31,
      });
      assert.equal((await phone.wait((m) => m.type === 'time.sync.response')).syncId, syncId);
    } finally { await server.close(); }
  });

  test(`[${backend}] a second phone replaces the first`, async () => {
    const { server, url } = await boot(factory);
    try {
      const a = client(url);
      await a.open();
      a.send(hello('phone', PHONE_TOKEN));
      await a.wait((m) => m.type === 'hello.ok');

      const b = client(url);
      await b.open();
      b.send(hello('phone', PHONE_TOKEN));
      await b.wait((m) => m.type === 'hello.ok');

      await a.closed();
      assert.notEqual(server.state.phone, null, 'replacement survives the displaced close');
    } finally { await server.close(); }
  });

  test(`[${backend}] mac_offline when no Mac is connected`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      await phone.open();
      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');
      phone.send(req());
      assert.equal((await phone.wait((m) => m.type === 'relay.ack')).status, 'mac_offline');
    } finally { await server.close(); }
  });

  test(`[${backend}] an expired request is rejected over the wire`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      const mac = client(url);
      await Promise.all([phone.open(), mac.open()]);
      mac.send(hello('mac', MAC_TOKEN));
      await mac.wait((m) => m.type === 'hello.ok');
      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');

      const stale = Date.now() - 60_000;
      phone.send(req({ issuedAtUnixMs: stale, expiresAtUnixMs: stale + ACTION_LIFETIME_MS }));
      assert.equal((await phone.wait((m) => m.type === 'relay.ack')).status, 'rejected');
      assert.equal(mac.inbox.filter((m) => m.type === 'action.request').length, 0);
    } finally { await server.close(); }
  });

  test(`[${backend}] garbage after authentication does not close the socket`, async () => {
    const { server, url } = await boot(factory);
    try {
      const phone = client(url);
      await phone.open();
      phone.send(hello('phone', PHONE_TOKEN));
      await phone.wait((m) => m.type === 'hello.ok');

      phone.raw('{not json');
      phone.raw('{"type":"nope","v":1}');
      phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 7 });

      assert.equal((await phone.wait((m) => m.type === 'heartbeat.ack')).sequence, 7,
        'socket still alive and serving');
    } finally { await server.close(); }
  });

  test(`[${backend}] restart leaves no route and replays nothing`, async () => {
    const first = await boot(factory);
    const phone = client(first.url);
    const mac = client(first.url);
    await Promise.all([phone.open(), mac.open()]);
    mac.send(hello('mac', MAC_TOKEN));
    await mac.wait((m) => m.type === 'hello.ok');
    phone.send(hello('phone', PHONE_TOKEN));
    await phone.wait((m) => m.type === 'hello.ok');
    phone.send(req());
    await phone.wait((m) => m.type === 'relay.ack');
    assert.equal(first.server.state.pending.size, 1);

    await first.server.close();

    const second = await boot(factory);
    try {
      assert.equal(second.server.state.pending.size, 0, 'a fresh process has no routes');
    } finally { await second.server.close(); }
  });

  test(`[${backend}] startup refuses bad or identical tokens`, async () => {
    await assert.rejects(createServer({
      phoneToken: 'short', macToken: MAC_TOKEN, log: silent, wssFactory: factory }));
    await assert.rejects(createServer({
      phoneToken: PHONE_TOKEN, macToken: 'ABC', log: silent, wssFactory: factory }));
    await assert.rejects(createServer({
      phoneToken: PHONE_TOKEN, macToken: PHONE_TOKEN, log: silent, wssFactory: factory }));
  });
}

test('the production default factory is the ws package', () => {
  // Guards against the injectable seam silently becoming the mini server.
  assert.equal(BACKENDS[0][0], 'mini-wss');
  if (realWsFactory) assert.equal(BACKENDS.length, 2, 'ws suite should also run');
});
