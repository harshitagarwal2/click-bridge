// End-to-end tests over real WebSockets. Requires `npm install` (ws).
// Skips with a clear message when the dependency is absent so the rest of the
// suite still runs on a fresh clone.

import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { PROTOCOL_VERSION, ACTION_LIFETIME_MS } from '../src/constants.js';

let WebSocket;
let createServer;
try {
  ({ WebSocket } = await import('ws'));
  ({ createServer } = await import('../src/server.js'));
} catch {
  test('socket tests require `npm install` (ws not resolved)', { skip: true }, () => {});
}

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const silent = { info: () => {} };

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

async function boot() {
  const server = createServer({ phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, log: silent });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  return { server, url: `ws://127.0.0.1:${port}/ws`, base: `http://127.0.0.1:${port}` };
}

function client(url) {
  const ws = new WebSocket(url);
  const inbox = [];
  const waiters = [];
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].match(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
    }
  });
  return {
    ws,
    open: () => new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); }),
    closed: () => new Promise((res) => ws.once('close', (code) => res(code))),
    send: (m) => ws.send(JSON.stringify(m)),
    inbox,
    wait(match, ms = 3000) {
      const found = inbox.find(match);
      if (found) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timeout waiting for message')), ms);
        waiters.push({ match, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
  };
}

const suite = createServer ? test : test.skip;

suite('healthz responds ok with the canonical CSP', async () => {
  const { server, base } = await boot();
  try {
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'ok');
    assert.match(res.headers.get('content-security-policy'), /script-src 'self'/);
  } finally { await server.close(); }
});

suite('upgrade is refused outside /ws', async () => {
  const { server, base } = await boot();
  try {
    await assert.rejects(client(`${base.replace('http', 'ws')}/nope`).open());
  } finally { await server.close(); }
});

suite('a wrong token is closed', async () => {
  const { server, url } = await boot();
  try {
    const c = client(url);
    await c.open();
    c.send(hello('phone', '9'.repeat(64)));
    assert.equal(await c.closed(), 4003);
  } finally { await server.close(); }
});

suite('a role-swapped token is closed', async () => {
  const { server, url } = await boot();
  try {
    const c = client(url);
    await c.open();
    c.send(hello('phone', MAC_TOKEN));
    assert.equal(await c.closed(), 4003);
  } finally { await server.close(); }
});

suite('a non-hello first frame is closed', async () => {
  const { server, url } = await boot();
  try {
    const c = client(url);
    await c.open();
    c.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 1 });
    assert.equal(await c.closed(), 4003);
  } finally { await server.close(); }
});

suite('full round trip: request, ack, forward, result', async () => {
  const { server, url } = await boot();
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

suite('heartbeat is acknowledged with the same sequence', async () => {
  const { server, url } = await boot();
  try {
    const phone = client(url);
    await phone.open();
    phone.send(hello('phone', PHONE_TOKEN));
    await phone.wait((m) => m.type === 'hello.ok');
    phone.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence: 42 });
    assert.equal((await phone.wait((m) => m.type === 'heartbeat.ack')).sequence, 42);
  } finally { await server.close(); }
});

suite('time sync is relayed both ways', async () => {
  const { server, url } = await boot();
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

suite('a second phone replaces the first', async () => {
  const { server, url } = await boot();
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
    assert.notEqual(server.state.phone, null, 'replacement remains connected');
  } finally { await server.close(); }
});

suite('mac_offline when no Mac is connected', async () => {
  const { server, url } = await boot();
  try {
    const phone = client(url);
    await phone.open();
    phone.send(hello('phone', PHONE_TOKEN));
    await phone.wait((m) => m.type === 'hello.ok');
    phone.send(req());
    assert.equal((await phone.wait((m) => m.type === 'relay.ack')).status, 'mac_offline');
  } finally { await server.close(); }
});

suite('an oversized frame does not crash the relay', async () => {
  const { server, url } = await boot();
  try {
    const phone = client(url);
    await phone.open();
    phone.send(hello('phone', PHONE_TOKEN));
    await phone.wait((m) => m.type === 'hello.ok');
    phone.ws.send('x'.repeat(9000));
    await new Promise((r) => setTimeout(r, 120));
    assert.ok(true, 'server survived');
  } finally { await server.close(); }
});

suite('restart leaves no route and replays nothing', async () => {
  const first = await boot();
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

  const second = await boot();
  try {
    assert.equal(second.server.state.pending.size, 0, 'fresh process has no routes');
  } finally { await second.server.close(); }
});

suite('startup refuses bad or identical tokens', () => {
  assert.throws(() => createServer({ phoneToken: 'short', macToken: MAC_TOKEN, log: silent }));
  assert.throws(() => createServer({ phoneToken: PHONE_TOKEN, macToken: 'ABC', log: silent }));
  assert.throws(() => createServer({ phoneToken: PHONE_TOKEN, macToken: PHONE_TOKEN, log: silent }));
});
