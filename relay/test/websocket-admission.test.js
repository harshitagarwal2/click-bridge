import http from 'node:http';
import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import assert from 'node:assert/strict';

import { WebSocket } from 'ws';

import { attachWebSocketServer, createServer } from '../src/server.js';
import { PROTOCOL_VERSION } from '../src/constants.js';

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const DOMAIN = 'relay.example.test';
const silent = { info() {}, error() {} };

const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });

function client(url) {
  const ws = new WebSocket(url);
  let closeResolve;
  const closePromise = new Promise((resolve) => { closeResolve = resolve; });
  const openPromise = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  ws.once('close', (code) => closeResolve(code));
  return {
    ws,
    open: () => ws.readyState === WebSocket.OPEN ? Promise.resolve() : openPromise,
    closed: () => closePromise,
    send: (message) => ws.send(JSON.stringify(message)),
    waitForMessage(match, timeoutMs = 500) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout waiting for message')), timeoutMs);
        ws.on('message', function onMessage(data) {
          const message = JSON.parse(data.toString());
          if (!match(message)) return;
          clearTimeout(timer);
          ws.off('message', onMessage);
          resolve(message);
        });
      });
    },
  };
}

async function authenticate(peer, role = 'phone', token = PHONE_TOKEN) {
  await peer.open();
  const accepted = peer.waitForMessage((message) => message.type === 'hello.ok');
  peer.send(hello(role, token));
  await accepted;
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
  return { server, port, url: `ws://127.0.0.1:${port}/ws` };
}

function rawUpgrade(port) {
  const socket = net.createConnection({ host: '127.0.0.1', port });
  let response = '';
  socket.setEncoding('utf8');
  socket.on('data', (chunk) => { response += chunk; });
  const sent = new Promise((resolve, reject) => {
    socket.once('error', reject);
    socket.once('connect', () => {
      const key = randomBytes(16).toString('base64');
      socket.write([
        'GET /ws HTTP/1.1',
        `Host: 127.0.0.1:${port}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        `Sec-WebSocket-Key: ${key}`,
        '',
        '',
      ].join('\r\n'));
      resolve();
    });
  });
  return { socket, sent, response: () => response };
}

function halfOpenRejectedUpgrade(port) {
  const socket = net.createConnection({ host: '127.0.0.1', port, allowHalfOpen: true });
  let response = '';
  socket.setEncoding('utf8');
  socket.on('data', (chunk) => { response += chunk; });
  const ended = new Promise((resolve) => socket.once('end', resolve));
  const sent = new Promise((resolve, reject) => {
    socket.once('error', reject);
    socket.once('connect', () => {
      const key = randomBytes(16).toString('base64');
      socket.write([
        'GET /ws HTTP/1.1',
        `Host: 127.0.0.1:${port}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        `Sec-WebSocket-Key: ${key}`,
        '',
        '',
      ].join('\r\n'));
      resolve();
    });
  });
  return { socket, sent, ended, response: () => response };
}

function connectionCount(server) {
  return new Promise((resolve, reject) => {
    server.getConnections((error, count) => error ? reject(error) : resolve(count));
  });
}

function fakeWebSocket() {
  const ws = new EventEmitter();
  ws.OPEN = WebSocket.OPEN;
  ws.CLOSED = WebSocket.CLOSED;
  ws.readyState = WebSocket.OPEN;
  ws.send = () => {};
  ws.close = () => {
    if (ws.readyState === WebSocket.CLOSED) return;
    ws.readyState = WebSocket.CLOSED;
    ws.emit('close');
  };
  ws.terminate = ws.close;
  return ws;
}

function fakeUpgradeSocket() {
  const socket = new EventEmitter();
  socket.destroyed = false;
  socket.response = '';
  socket.setNoDelay = () => {};
  socket.write = (value) => { socket.response += value; };
  socket.end = (value = '') => {
    socket.response += value;
    socket.destroy();
  };
  socket.destroy = () => {
    if (socket.destroyed) return;
    socket.destroyed = true;
    socket.emit('close');
  };
  return socket;
}

async function waitUntil(predicate, timeoutMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error('condition not reached before timeout');
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

test('pre-upgrade reservation prevents unauthenticated and total cap bypass', async () => {
  const { server, url } = await boot({
    maxTotalWebSocketConnections: 2,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  let relayConnections = 0;
  server.wss.on('connection', () => { relayConnections += 1; });
  try {
    const first = client(url);
    await first.open();

    const rejectedUnauthenticated = client(url);
    await assert.rejects(rejectedUnauthenticated.open(), /Unexpected server response: 503/);
    assert.equal(server.wss.clients.size, 1);
    assert.equal(relayConnections, 1, 'cap rejection never enters the relay connection handler');

    await authenticate(first);
    const second = client(url);
    await second.open();
    assert.equal(server.wss.clients.size, 2, 'authentication releases only the unauthenticated slot');

    const rejectedTotal = client(url);
    await assert.rejects(rejectedTotal.open(), /Unexpected server response: 503/);
    assert.equal(server.wss.clients.size, 2);
    assert.equal(relayConnections, 2, 'total-cap rejection never enters wss.clients');

    second.ws.terminate();
    await second.closed();
    const recovered = client(url);
    await recovered.open();
    recovered.ws.terminate();
  } finally {
    await server.close();
  }
});

test('capacity rejection fully destroys allowHalfOpen TCP clients after flushing 503', async () => {
  const { server, port, url } = await boot({
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  const rejected = [];
  try {
    const admitted = client(url);
    await admitted.open();
    for (let index = 0; index < 20; index += 1) rejected.push(halfOpenRejectedUpgrade(port));
    await Promise.all(rejected.map((attempt) => attempt.sent));
    await Promise.all(rejected.map((attempt) => attempt.ended));
    assert.ok(rejected.every((attempt) => /503 Service Unavailable/.test(attempt.response())));
    await waitUntil(async () => await connectionCount(server.httpServer) === 1);
    assert.equal(await connectionCount(server.httpServer), 1, 'only the admitted WebSocket remains');
    admitted.ws.terminate();
    await admitted.closed();
    await waitUntil(async () => await connectionCount(server.httpServer) === 0);
  } finally {
    for (const attempt of rejected) attempt.socket.destroy();
    await server.close();
  }
});

test('unauthenticated reservation bounds malformed hello floods', async () => {
  const { server, url } = await boot({
    maxTotalWebSocketConnections: 4,
    maxUnauthenticatedWebSocketConnections: 2,
  });
  let relayConnections = 0;
  server.wss.on('connection', () => { relayConnections += 1; });
  try {
    const flood = Array.from({ length: 8 }, () => client(url));
    const opened = await Promise.all(flood.map(async (peer) => {
      try {
        await peer.open();
        return peer;
      } catch {
        return null;
      }
    }));
    const admitted = opened.filter(Boolean);
    assert.equal(admitted.length, 2);
    assert.equal(relayConnections, 2);

    for (const peer of admitted) peer.ws.send('{malformed');
    assert.deepEqual(await Promise.all(admitted.map((peer) => peer.closed())), [4003, 4003]);

    const recovered = client(url);
    await authenticate(recovered);
    recovered.ws.terminate();
  } finally {
    await server.close();
  }
});

test('pending upgrades reserve capacity before handleUpgrade completes', async () => {
  const heldSockets = [];
  let upgradeCalls = 0;
  const performWebSocketUpgrade = (_req, socket) => {
    upgradeCalls += 1;
    heldSockets.push(socket);
  };
  const { server, port } = await boot({
    maxTotalWebSocketConnections: 2,
    maxUnauthenticatedWebSocketConnections: 2,
    performWebSocketUpgrade,
  });
  const attempts = [rawUpgrade(port), rawUpgrade(port), rawUpgrade(port)];
  try {
    await Promise.all(attempts.map((attempt) => attempt.sent));
    await waitUntil(() => upgradeCalls === 2);
    await waitUntil(() => attempts[2].response().includes('503 Service Unavailable'));

    heldSockets[0].destroy();
    const recovered = rawUpgrade(port);
    attempts.push(recovered);
    await recovered.sent;
    await waitUntil(() => upgradeCalls === 3);
  } finally {
    for (const attempt of attempts) attempt.socket.destroy();
    for (const socket of heldSockets) socket.destroy();
    await server.close();
  }
});

test('aborted upgrade permanently revokes a late callback before relay entry', async () => {
  const pending = [];
  let routed = 0;
  const { server, port } = await boot({
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
    performWebSocketUpgrade(_req, socket, _head, done) {
      pending.push({ socket, done });
    },
  });
  server.wss.on('connection', () => { routed += 1; });
  const attempts = [];
  try {
    const aborted = rawUpgrade(port);
    attempts.push(aborted);
    await aborted.sent;
    await waitUntil(() => pending.length === 1);
    pending[0].socket.destroy();

    const current = rawUpgrade(port);
    attempts.push(current);
    await current.sent;
    await waitUntil(() => pending.length === 2);

    const staleWebSocket = fakeWebSocket();
    pending[0].done(staleWebSocket);
    assert.equal(routed, 0, 'revoked callback never enters the relay handler');
    assert.equal(staleWebSocket.readyState, WebSocket.CLOSED, 'stale WebSocket is destroyed');

    const excess = rawUpgrade(port);
    attempts.push(excess);
    await excess.sent;
    await waitUntil(() => excess.response().includes('503 Service Unavailable'));
    assert.equal(pending.length, 2, 'stale callback cannot release the current reservation');

    pending[1].socket.destroy();
    const recovered = rawUpgrade(port);
    attempts.push(recovered);
    await recovered.sent;
    await waitUntil(() => pending.length === 3);
  } finally {
    for (const attempt of attempts) attempt.socket.destroy();
    for (const entry of pending) entry.socket.destroy();
    await server.close();
  }
});

test('completed upgrade accepts only its first callback and preserves cap ownership', async () => {
  const callbacks = [];
  let routed = 0;
  const { server } = await boot({
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
    performWebSocketUpgrade(_req, _socket, _head, done) {
      callbacks.push(done);
    },
  });
  server.wss.on('connection', () => { routed += 1; });
  const acceptedWebSocket = fakeWebSocket();
  try {
    const accepted = fakeUpgradeSocket();
    server.httpServer.emit('upgrade', { url: '/ws' }, accepted, Buffer.alloc(0));
    assert.equal(callbacks.length, 1);

    callbacks[0](acceptedWebSocket);
    const duplicateWebSocket = fakeWebSocket();
    callbacks[0](duplicateWebSocket);
    assert.equal(routed, 1, 'duplicate callback never enters the relay handler');
    assert.equal(duplicateWebSocket.readyState, WebSocket.CLOSED, 'duplicate WebSocket is destroyed');

    const excess = fakeUpgradeSocket();
    server.httpServer.emit('upgrade', { url: '/ws' }, excess, Buffer.alloc(0));
    assert.match(excess.response, /503 Service Unavailable/);
    assert.equal(callbacks.length, 1, 'duplicate callback cannot release the accepted total slot');

    acceptedWebSocket.terminate();
    const recovered = fakeUpgradeSocket();
    server.httpServer.emit('upgrade', { url: '/ws' }, recovered, Buffer.alloc(0));
    assert.equal(callbacks.length, 2);
    recovered.destroy();
  } finally {
    acceptedWebSocket.terminate();
    await server.close();
  }
});

test('timeout and socket error paths release admission capacity', async () => {
  const { server, url } = await boot({
    authTimeoutMs: 20,
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  try {
    const timedOut = client(url);
    await timedOut.open();
    assert.equal(await timedOut.closed(), 4001);

    const errored = client(url);
    await errored.open();
    const serverSocket = [...server.wss.clients][0];
    serverSocket.emit('error', Object.assign(new Error('forced'), { code: 'EIO' }));
    assert.equal(await errored.closed(), 1006);

    const recovered = client(url);
    await recovered.open();
    recovered.ws.terminate();
  } finally {
    await server.close();
  }
});

test('non-reading bad hello and bad token peers cannot retain unauthenticated slots', async (t) => {
  for (const firstMessage of [
    '{malformed',
    JSON.stringify(hello('phone', '9'.repeat(64))),
  ]) {
    await t.test(firstMessage.startsWith('{malformed') ? 'bad hello' : 'bad token', async () => {
      const { server, url } = await boot({
        terminalCloseDeadlineMs: 20,
        maxTotalWebSocketConnections: 1,
        maxUnauthenticatedWebSocketConnections: 1,
      });
      const hostile = client(url);
      try {
        await hostile.open();
        await new Promise((resolve, reject) => {
          hostile.ws.send(firstMessage, (error) => error ? reject(error) : resolve());
        });
        hostile.ws._socket.pause();
        await waitUntil(() => server.wss.clients.size === 0, 150);

        const recovered = client(url);
        await authenticate(recovered);
        recovered.ws.terminate();
      } finally {
        hostile.ws._socket?.destroy();
        await server.close();
      }
    });
  }
});

test('non-reading authentication timeout peer releases its slot within the close deadline', async () => {
  const { server, url } = await boot({
    authTimeoutMs: 10,
    terminalCloseDeadlineMs: 20,
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  const hostile = client(url);
  try {
    await hostile.open();
    hostile.ws._socket.pause();
    await waitUntil(() => server.wss.clients.size === 0, 150);

    const recovered = client(url);
    await authenticate(recovered);
    recovered.ws.terminate();
  } finally {
    hostile.ws._socket?.destroy();
    await server.close();
  }
});

test('non-reading displaced role cannot block a valid replacement sequence', async () => {
  const { server, url } = await boot({
    terminalCloseDeadlineMs: 20,
    maxTotalWebSocketConnections: 2,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  const predecessor = client(url);
  let replacement;
  try {
    await authenticate(predecessor);
    predecessor.ws._socket.pause();
    replacement = client(url);
    await authenticate(replacement);
    await waitUntil(() => server.wss.clients.size === 1, 150);

    const next = client(url);
    await authenticate(next);
    assert.equal(server.wss.clients.size, 2, 'predecessor no longer consumes a total slot');
    next.ws.terminate();
    replacement.ws.terminate();
  } finally {
    predecessor.ws._socket?.destroy();
    replacement?.ws._socket?.destroy();
    await server.close();
  }
});

test('auth-close and timeout-close races cannot underflow admission counts', async () => {
  const { server, url } = await boot({
    authTimeoutMs: 15,
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  try {
    for (let index = 0; index < 4; index += 1) {
      const racing = client(url);
      await racing.open();
      if (index % 2 === 0) racing.send(hello('phone', PHONE_TOKEN));
      setTimeout(() => racing.ws.terminate(), 15);
      await racing.closed();

      const keeper = client(url);
      await keeper.open();
      const excess = client(url);
      await assert.rejects(excess.open(), /Unexpected server response: 503/);
      keeper.ws.terminate();
      await keeper.closed();
    }
  } finally {
    await server.close();
  }
});

test('synchronous upgrade throws release capacity and emit redacted diagnostics', async () => {
  let upgradeCalls = 0;
  const logs = [];
  const { server, port } = await boot({
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
    log: { info(value) { logs.push(value); }, error() {} },
    performWebSocketUpgrade() {
      upgradeCalls += 1;
      throw new Error('upgrade failed with sensitive detail');
    },
  });
  try {
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      const raw = rawUpgrade(port);
      await raw.sent;
      await waitUntil(() => raw.socket.destroyed);
      assert.equal(upgradeCalls, attempt, 'each failed reservation recovers for one next attempt');
    }
    assert.equal(logs.length, 2);
    assert.ok(logs.every((entry) => entry.includes('upgrade_internal_error')));
    assert.ok(logs.every((entry) => !entry.includes('sensitive detail')));
    assert.ok(logs.every((entry) => !entry.includes(PHONE_TOKEN) && !entry.includes(MAC_TOKEN)));
  } finally {
    await server.close();
  }
});

test('pending callback failure admits one contender, rejects one, and repeatedly recovers', async () => {
  const pending = [];
  const logs = [];
  const { server, port } = await boot({
    maxTotalWebSocketConnections: 1,
    maxUnauthenticatedWebSocketConnections: 1,
    log: { info(value) { logs.push(value); }, error() {} },
    performWebSocketUpgrade(_req, _socket, _head, done) { pending.push(done); },
  });
  try {
    for (let cycle = 1; cycle <= 2; cycle += 1) {
      const admitted = rawUpgrade(port);
      await admitted.sent;
      await waitUntil(() => pending.length === cycle);
      const rejected = rawUpgrade(port);
      await rejected.sent;
      await waitUntil(() => /503 Service Unavailable/.test(rejected.response()));
      assert.equal(pending.length, cycle, 'only one contender reaches the upgrade adapter');
      pending.at(-1)({});
      await waitUntil(() => admitted.socket.destroyed);
    }
    assert.equal(logs.length, 2);
    assert.ok(logs.every((entry) => entry.includes('connection_callback_failure')));
    assert.ok(logs.every((entry) => !entry.includes(PHONE_TOKEN) && !entry.includes(MAC_TOKEN)));
  } finally {
    await server.close();
  }
});

test('unsafe admission limit configuration is refused instead of disabling the bound', () => {
  const valid = {
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
  };
  assert.throws(() => createServer({
    ...valid,
    maxTotalWebSocketConnections: 0,
  }), /maxTotalWebSocketConnections/);
  assert.throws(() => createServer({
    ...valid,
    maxTotalWebSocketConnections: 2,
    maxUnauthenticatedWebSocketConnections: 3,
  }), /maxUnauthenticatedWebSocketConnections/);
});
