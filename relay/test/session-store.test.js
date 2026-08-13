import assert from 'node:assert/strict';
import * as crypto from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { WebSocket } from 'ws';

import { createSessionStore } from '../src/session-store.js';
import { createServer } from '../src/server.js';

async function withStore(run) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'clickbridge-sessions-'));
  try {
    const store = createSessionStore({
      recordPath: path.join(directory, 'sessions.json'),
      fs,
      crypto,
      maxSessions: 2,
      ttlMs: 60_000,
    });
    await store.initialize();
    await run(store);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}

test('session store creates independent durable desktop and phone credentials', async () => {
  await withStore(async (store) => {
    const first = await store.createSession();
    const second = await store.createSession();
    assert.match(first.id, /^[A-Za-z0-9_-]{22}$/);
    assert.match(first.macToken, /^[0-9a-f]{64}$/);
    assert.notEqual(first.id, second.id);
    assert.equal(store.authenticateMac(first.id, first.macToken), true);
    assert.equal(store.authenticateMac(first.id, second.macToken), false);

    const auth = store.phoneAuthStore(first.id);
    assert.equal(auth.authenticateCredential('0'.repeat(64)), null);
    await auth.activate({
      expectedVersion: 0,
      credentialVersion: 1,
      verifier: crypto.createHash('sha256').update(Buffer.alloc(32, 1)).digest('hex'),
    });
    const descriptor = auth.authenticateCredential('01'.repeat(32));
    assert.equal(descriptor.credentialVersion, 1);
    assert.equal(typeof descriptor.deviceId, 'string');
    assert.notEqual(descriptor.deviceId.length, 0);
    assert.equal(store.phoneAuthStore(second.id).authenticateCredential('01'.repeat(32)), null);
  });
});

test('session store enforces capacity and expires stale sessions', async () => {
  let now = 10_000;
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'clickbridge-sessions-'));
  try {
    const store = createSessionStore({
      recordPath: path.join(directory, 'sessions.json'), fs, crypto,
      maxSessions: 1, ttlMs: 100, now: () => now,
    });
    await store.initialize();
    const created = await store.createSession();
    await assert.rejects(store.createSession(), /capacity/);
    now += 101;
    assert.equal(await store.get(created.id), null);
    const replacement = await store.createSession();
    assert.notEqual(replacement.id, created.id);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test('enrollment returns a session-scoped endpoint that rejects other desktop credentials', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'clickbridge-enrollment-'));
  let server;
  try {
    const store = createSessionStore({ recordPath: path.join(directory, 'sessions.json'), fs, crypto, maxSessions: 2 });
    server = createServer({
      phoneToken: '1'.repeat(64), macToken: '2'.repeat(64), clickBridgeDomain: 'relay.example.test',
      pairingEnabled: '1', appleTeamId: 'ABC123DE45',
      authStore: { async initialize() {}, snapshot: () => ({ activePhoneCredentialVersion: 0 }),
        authenticateCredential: () => null, async activate() {} },
      sessionStore: store, log: { info() {} },
    });
    await server.listen(0, '127.0.0.1');
    const { port } = server.httpServer.address();
    const response = await fetch(`http://127.0.0.1:${port}/v1/sessions`, { method: 'POST' });
    assert.equal(response.status, 201);
    const enrollment = await response.json();
    assert.match(enrollment.relayURL, /^wss:\/\/relay\.example\.test\/ws\/[A-Za-z0-9_-]{22}$/);
    assert.match(enrollment.token, /^[0-9a-f]{64}$/);
    const dynamicURL = enrollment.relayURL.replace('wss://relay.example.test', `ws://127.0.0.1:${port}`);
    const accepted = new WebSocket(dynamicURL);
    await new Promise((resolve, reject) => accepted.once('open', resolve).once('error', reject));
    accepted.send(JSON.stringify({ type: 'hello', v: 1, role: 'mac', token: enrollment.token }));
    const hello = await new Promise((resolve, reject) => accepted.once('message', (data) => resolve(JSON.parse(data.toString())))
      .once('error', reject));
    assert.deepEqual(hello, { type: 'hello.ok', v: 1, role: 'mac' });
    accepted.close();
  } finally {
    await server?.close();
    await fs.rm(directory, { recursive: true, force: true });
  }
});
