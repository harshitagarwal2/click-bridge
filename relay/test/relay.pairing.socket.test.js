import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

import { WebSocket } from 'ws';

import { PROTOCOL_VERSION } from '../src/constants.js';
import { AUTH_STORE_ERROR_CODES, AuthStoreError } from '../src/auth-store.js';
import { parseClientMessage } from '../src/protocol.js';
import { createServer } from '../src/server.js';

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const NEXT_TOKEN = '3'.repeat(64);
const DOMAIN = 'relay.example.test';
const TEAM_ID = 'ABC123DE45';
const REFERENCE_BYTES = Buffer.alloc(32, 7);
const REFERENCE = REFERENCE_BYTES.toString('base64url');
const REQUEST_ID = '018f63f5-6f3d-7d21-88bc-9ef561f030e1';
const STATUS_ID = '018f63f5-6f3d-7d21-88bc-9ef561f030e0';
const CLAIM_ID = '018f63f5-6f3d-7d21-88bc-9ef561f030e2';
const NONCE = 'b'.repeat(64);
const silent = { info() {} };
const deployment = JSON.parse(readFileSync(join(
  dirname(fileURLToPath(import.meta.url)),
  '../../contracts/config/deployment.json',
), 'utf8'));

const TEST_DEVICE_ID = 'test-phone';

// Multi-device: activate() adds a new (token, deviceId, credentialVersion)
// entry rather than replacing the existing one, mirroring bridge-registry.js
// so socket-level tests can prove additive pairing keeps every prior phone
// authenticated.
function authStore() {
  let version = 0;
  let nextDeviceSeq = 1;
  const phonesByToken = new Map([[PHONE_TOKEN, { deviceId: TEST_DEVICE_ID, credentialVersion: 0 }]]);
  return {
    initializeCalls: 0,
    async initialize() { this.initializeCalls += 1; },
    snapshot() { return { activePhoneCredentialVersion: version }; },
    authenticateCredential(candidate) {
      const entry = phonesByToken.get(candidate);
      return entry ? Object.freeze({ deviceId: entry.deviceId, credentialVersion: entry.credentialVersion }) : null;
    },
    isDeviceActive(deviceId, credentialVersion) {
      for (const entry of phonesByToken.values()) {
        if (entry.deviceId === deviceId && entry.credentialVersion === credentialVersion) return true;
      }
      return false;
    },
    hasCredentialVersion(credentialVersion) {
      for (const entry of phonesByToken.values()) {
        if (entry.credentialVersion === credentialVersion) return true;
      }
      return false;
    },
    async activate(input) {
      assert.equal(input.expectedVersion, version);
      version = input.credentialVersion;
      const deviceId = `test-phone-${nextDeviceSeq}`;
      nextDeviceSeq += 1;
      phonesByToken.set(NEXT_TOKEN, { deviceId, credentialVersion: version });
    },
  };
}

function peer(url, options) {
  const ws = new WebSocket(url, options);
  const inbox = [];
  const waiters = [];
  const opened = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  let closed;
  const closedPromise = new Promise((resolve) => ws.once('close', (code) => {
    closed = code;
    resolve(code);
  }));
  ws.on('message', (data) => {
    const message = JSON.parse(data.toString());
    inbox.push(message);
    for (const waiter of [...waiters]) {
      if (!waiter.match(message)) continue;
      waiters.splice(waiters.indexOf(waiter), 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    }
  });
  return {
    ws,
    inbox,
    open: () => ws.readyState === WebSocket.OPEN ? Promise.resolve() : opened,
    send: (message) => ws.send(JSON.stringify(message)),
    closed: () => closed === undefined ? closedPromise : Promise.resolve(closed),
    wait(match) {
      const existing = inbox.find(match);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const waiter = {
          match,
          resolve,
          timer: setTimeout(() => reject(new Error('timeout waiting for message')), 1500),
        };
        waiters.push(waiter);
      });
    },
  };
}

async function boot(overrides = {}) {
  const store = overrides.authStore ?? authStore();
  let issuedReference = false;
  const server = createServer({
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
    pairingEnabled: '1',
    appleTeamId: TEAM_ID,
    authStore: store,
    pairingOptions: {
      randomBytes: () => {
        if (!issuedReference) {
          issuedReference = true;
          return REFERENCE_BYTES;
        }
        return Buffer.from(NEXT_TOKEN, 'hex');
      },
      randomInt: () => 123,
    },
    log: silent,
    ...overrides,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  return {
    server,
    store,
    base: `http://127.0.0.1:${port}`,
    url: `ws://127.0.0.1:${port}/ws`,
  };
}

async function hello(client, role, token) {
  await client.open();
  client.send({ type: 'hello', v: PROTOCOL_VERSION, role, token });
  return client.wait((message) => message.type === 'hello.ok');
}

// Proves a connection is still open and its credential is still authorized:
// a stale or revoked phone gets no heartbeat.ack because handlePhoneMessage
// rejects it before the relay ever replies.
async function stillAuthenticated(client) {
  const sequence = Math.floor(Math.random() * 1_000_000);
  client.send({ type: 'heartbeat.request', v: PROTOCOL_VERSION, sequence });
  // Match on sequence, not just type: peer().wait() also matches messages
  // already sitting in the inbox, so a bare type match could resolve against
  // an earlier heartbeat.ack when this helper is called more than once.
  await client.wait((message) => message.type === 'heartbeat.ack' && message.sequence === sequence);
}

test('pairing flag is exact, defaults off, and enabled startup requires configuration', async () => {
  const common = { phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN };
  for (const invalid of ['', 'true', '01', 1, true]) {
    assert.throws(() => createServer({ ...common, pairingEnabled: invalid }), /PAIRING_ENABLED/);
  }
  assert.throws(
    () => createServer({ ...common, pairingEnabled: '1', appleTeamId: 'bad', authStore: authStore() }),
    /APPLE_TEAM_ID/,
  );
  assert.throws(
    () => createServer({ ...common, pairingEnabled: '1', appleTeamId: TEAM_ID }),
    /PHONE_AUTH_RECORD|authStore/,
  );
  const disabled = createServer(common);
  await disabled.close();
});

test('disabled pairing preserves legacy auth and rejects pairing entry points', async () => {
  const server = createServer({
    phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  const url = `ws://127.0.0.1:${port}/ws`;
  try {
    for (const path of ['/pair', '/pair/web']) {
      const response = await fetch(`http://127.0.0.1:${port}${path}`);
      assert.equal(response.status, 404);
      assert.equal(await response.text(), 'not found');
      const head = await fetch(`http://127.0.0.1:${port}${path}`, { method: 'HEAD' });
      assert.equal(head.status, 404);
      assert.equal(await head.text(), '');
    }
    for (const path of ['/', '/index.html']) {
      const response = await fetch(`http://127.0.0.1:${port}${path}`);
      const body = await response.text();
      assert.equal(response.status, 200);
      assert.equal(
        (body.match(/<meta name="clickbridge-pairing" content="off">/g) ?? []).length,
        1,
      );
      assert.equal(body.includes('name="clickbridge-pairing" content="on"'), false);
      const head = await fetch(`http://127.0.0.1:${port}${path}`, { method: 'HEAD' });
      assert.equal(head.status, 200);
      assert.equal(Number(head.headers.get('content-length')), Buffer.byteLength(body));
      assert.equal(await head.text(), '');
    }
    assert.equal((await fetch(
      `http://127.0.0.1:${port}/.well-known/apple-app-site-association`,
    )).status, 404);
    const phone = peer(url);
    await hello(phone, 'phone', PHONE_TOKEN);
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);
    mac.send({ type: 'pair.status.request', v: 1, requestId: STATUS_ID, pairingVersion: 1 });
    assert.equal((await mac.wait((message) => message.type === 'pair.failed')).reason, 'unsupported');

    const claimant = peer(url);
    await claimant.open();
    claimant.send({
      type: 'pair.claim', v: 1, reference: REFERENCE, claimId: CLAIM_ID,
      sessionNonce: NONCE, pairingVersion: 1, clientKind: 'pwa',
    });
    assert.equal(await claimant.closed(), 4003);
  } finally {
    await server.close();
  }
});

test('enabled PWA routes expose pairing without duplicating the canonical index', async () => {
  const { server, base } = await boot();
  try {
    const invitation = `${base}/pair#v=1&r=${REFERENCE}`;
    for (const path of ['/', '/index.html', '/pair', '/pair/web']) {
      const response = await fetch(path === '/pair' ? invitation : `${base}${path}`);
      assert.equal(response.status, 200);
      assert.equal(
        response.headers.get('cache-control'),
        path === '/pair' || path === '/pair/web' ? 'no-store' : 'no-cache',
      );
      assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
      assert.match(response.headers.get('content-security-policy'), /script-src 'self'/);
      const body = await response.text();
      assert.match(body, /<title>Click Bridge<\/title>/);
      assert.equal(
        (body.match(/<meta name="clickbridge-pairing" content="on">/g) ?? []).length,
        1,
      );
      assert.equal(body.includes('name="clickbridge-pairing" content="off"'), false);
      assert.equal(body.includes(REFERENCE), false, 'fragment reference must not enter HTML');
      for (const [, value] of response.headers) {
        assert.equal(value.includes(REFERENCE), false, 'fragment reference must not enter headers');
      }
      assert.equal(Number(response.headers.get('content-length')), Buffer.byteLength(body));

      const head = await fetch(`${base}${path}`, { method: 'HEAD' });
      assert.equal(head.status, 200);
      assert.equal(
        head.headers.get('cache-control'),
        path === '/pair' || path === '/pair/web' ? 'no-store' : 'no-cache',
      );
      assert.equal(head.headers.get('referrer-policy'), 'no-referrer');
      assert.equal(
        head.headers.get('content-security-policy'),
        response.headers.get('content-security-policy'),
      );
      assert.equal(Number(head.headers.get('content-length')), Buffer.byteLength(body));
      assert.equal(await head.text(), '');
    }

    const response = await fetch(`${base}/.well-known/apple-app-site-association`);
    assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), {
      applinks: { details: [{
        appIDs: [`${TEAM_ID}.${deployment.bundleId}`],
        components: [{ '/': '/pair/web*', exclude: true }, { '/': '/pair*' }],
      }] },
    });
    const head = await fetch(`${base}/.well-known/apple-app-site-association`, {
      method: 'HEAD',
    });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get('cache-control'), 'no-store');
    assert.equal(head.headers.get('referrer-policy'), 'no-referrer');
    assert.ok(Number(head.headers.get('content-length')) > 0);
    assert.equal(await head.text(), '');
  } finally {
    await server.close();
  }
});

test('enabled initial hello and claim frames are each parsed exactly once', async () => {
  const calls = [];
  const { server, url } = await boot({
    parseClient: (raw, role) => {
      calls.push(role);
      return parseClientMessage(raw, role);
    },
  });
  try {
    const phone = peer(url);
    await hello(phone, 'phone', PHONE_TOKEN);
    assert.deepEqual(calls, ['pairing.initial']);

    calls.length = 0;
    const claimant = peer(url);
    await claimant.open();
    claimant.send({
      type: 'pair.claim', v: 1, reference: REFERENCE, claimId: CLAIM_ID,
      sessionNonce: NONCE, pairingVersion: 1, clientKind: 'pwa',
    });
    assert.equal((await claimant.wait((message) => message.type === 'pair.failed')).reason, 'used');
    assert.deepEqual(calls, ['pairing.initial']);
  } finally {
    await server.close();
  }
});

test('phone authentication uses its atomic descriptor without a version snapshot', async () => {
  const store = authStore();
  let snapshotCalls = 0;
  const snapshot = store.snapshot;
  store.snapshot = () => {
    snapshotCalls += 1;
    return snapshot();
  };
  const { server, url } = await boot({ authStore: store });
  try {
    const phone = peer(url);
    await hello(phone, 'phone', PHONE_TOKEN);
    assert.equal(snapshotCalls, 0);
  } finally {
    await server.close();
  }
});

test('malformed credential descriptors fail closed without invoking accessors', async () => {
  let accessorReads = 0;
  const malformed = [
    Promise.resolve({ credentialVersion: 0 }),
    Object.create({ credentialVersion: 0 }),
    Object.defineProperty({}, 'credentialVersion', {
      enumerable: true,
      get() { accessorReads += 1; return 0; },
    }),
    { credentialVersion: -1 },
    { credentialVersion: 1.5 },
  ];
  for (const descriptor of malformed) {
    const store = authStore();
    store.authenticateCredential = () => descriptor;
    const { server, url } = await boot({ authStore: store });
    try {
      const phone = peer(url);
      await phone.open();
      phone.send({ type: 'hello', v: 1, role: 'phone', token: PHONE_TOKEN });
      assert.equal(await phone.closed(), 1011);
    } finally {
      await server.close();
    }
  }
  assert.equal(accessorReads, 0);
});

test('auth-store persistence failure is transient while an ordinary wrong credential remains rejected', async () => {
  const unavailable = authStore();
  unavailable.authenticateCredential = () => {
    throw new AuthStoreError(AUTH_STORE_ERROR_CODES.PERSISTENCE_FAILED, 'phone auth store unavailable');
  };
  const unavailableServer = await boot({ authStore: unavailable });
  try {
    const phone = peer(unavailableServer.url);
    await phone.open();
    phone.send({ type: 'hello', v: 1, role: 'phone', token: PHONE_TOKEN });
    assert.equal(await phone.closed(), 1011);
  } finally {
    await unavailableServer.server.close();
  }

  const ordinary = await boot();
  try {
    const phone = peer(ordinary.url);
    await phone.open();
    phone.send({ type: 'hello', v: 1, role: 'phone', token: '9'.repeat(64) });
    assert.equal(await phone.closed(), 4005);
  } finally {
    await ordinary.server.close();
  }
});

test('native absent Origin and exact PWA Origin are allowed while hostile Origin is rejected', async () => {
  const { server, url } = await boot();
  try {
    const native = peer(url);
    await hello(native, 'phone', PHONE_TOKEN);
    const pwa = peer(url, { origin: `https://${DOMAIN}` });
    await hello(pwa, 'phone', PHONE_TOKEN);
    const hostile = peer(url, { origin: 'https://evil.example' });
    await assert.rejects(hostile.open());
  } finally {
    await server.close();
  }
});

test('hostile Origin is rejected before upgrade admission or adapter invocation', async () => {
  let upgrades = 0;
  const server = createServer({
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
    performWebSocketUpgrade() { upgrades += 1; },
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  try {
    for (const origin of [
      'null', 'http://relay.example.test', 'https://relay.example.test:444',
      'https://user@relay.example.test', 'https://evil.example',
    ]) {
      const rejected = peer(`ws://127.0.0.1:${port}/ws`, { origin });
      await assert.rejects(rejected.open(), origin);
    }
    assert.equal(upgrades, 0);
  } finally {
    await server.close();
  }
});

test('hostile Origin floods cannot consume the unauthenticated reservation', async () => {
  const { server, url } = await boot({
    maxTotalWebSocketConnections: 2,
    maxUnauthenticatedWebSocketConnections: 1,
  });
  try {
    await Promise.all(Array.from({ length: 8 }, async () => {
      const rejected = peer(url, { origin: 'https://evil.example' });
      await assert.rejects(rejected.open());
    }));
    const valid = peer(url);
    await hello(valid, 'phone', PHONE_TOKEN);
  } finally {
    await server.close();
  }
});

test('auth initialization failure never binds and close during initialization cannot bind later', async () => {
  let release;
  const gated = authStore();
  gated.initialize = () => new Promise((resolve) => { release = resolve; });
  const server = createServer({
    phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN,
    pairingEnabled: '1', appleTeamId: TEAM_ID, authStore: gated,
  });
  const listening = server.listen(0, '127.0.0.1');
  while (!release) await new Promise((resolve) => setImmediate(resolve));
  await server.close();
  release();
  await assert.rejects(listening, /closing/);
  assert.equal(server.httpServer.listening, false);

  const failed = authStore();
  failed.initialize = async () => { throw new Error(`secret ${PHONE_TOKEN}`); };
  const refused = createServer({
    phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN,
    pairingEnabled: '1', appleTeamId: TEAM_ID, authStore: failed,
  });
  await assert.rejects(refused.listen(0, '127.0.0.1'));
  assert.equal(refused.httpServer.listening, false);
  await refused.close();
});

test('full pairing adds a device without closing or rejecting the prior phone', async () => {
  const { server, url, store } = await boot();
  try {
    assert.equal(store.initializeCalls, 1);
    const oldPhone = peer(url);
    await hello(oldPhone, 'phone', PHONE_TOKEN);
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);
    assert.equal(mac.inbox.some((message) => message.type === 'pair.status'), false);

    mac.send({ type: 'pair.status.request', v: 1, requestId: STATUS_ID, pairingVersion: 1 });
    const status = await mac.wait((message) => message.type === 'pair.status');
    assert.equal(status.activePhoneCredentialVersion, 0);
    mac.send({ type: 'pair.create', v: 1, requestId: REQUEST_ID, pairingVersion: 1 });
    const created = await mac.wait((message) => message.type === 'pair.created');
    assert.equal(created.reference, REFERENCE);

    const claimant = peer(url);
    await claimant.open();
    claimant.send({
      type: 'pair.claim', v: 1, reference: REFERENCE, claimId: CLAIM_ID,
      sessionNonce: NONCE, pairingVersion: 1, clientKind: 'pwa',
    });
    await claimant.wait((message) => message.type === 'pair.claimed.phone');
    await mac.wait((message) => message.type === 'pair.claimed.mac');
    mac.send({ type: 'pair.approve', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID });
    const offered = await claimant.wait((message) => message.type === 'pair.credential');
    assert.equal(offered.credential, NEXT_TOKEN);

    // The old phone stays connected and authorized through the entire
    // approval, well before the new device's credential is even acknowledged.
    await stillAuthenticated(oldPhone);

    claimant.send({
      type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID, credentialVersion: 1,
      proof: createHmac('sha256', Buffer.from(NEXT_TOKEN, 'hex'))
        .update(`clickbridge-pair-activate:v1:${CLAIM_ID}:1`).digest('hex'),
    });
    await claimant.wait((message) => message.type === 'pair.active');
    await mac.wait((message) => message.type === 'pair.completed');

    // Additive: the old socket was never closed by the new pairing, and its
    // credential still authenticates fresh connections (a same-device
    // reconnect below takes over its own prior socket, per the normal
    // single-current-socket-per-device rule — a different rule from the old
    // cross-device close this test used to assert).
    assert.equal(oldPhone.ws.readyState, oldPhone.ws.OPEN);
    await stillAuthenticated(oldPhone);
    const stillOld = peer(url);
    await hello(stillOld, 'phone', PHONE_TOKEN);
    const current = peer(url);
    await hello(current, 'phone', NEXT_TOKEN);
    await stillAuthenticated(stillOld);
    await stillAuthenticated(current);
  } finally {
    await server.close();
  }
});

test('a phone authenticated while activation is pending is undisturbed once activation resumes', async () => {
  const store = authStore();
  let releaseActivation;
  let activationStarted;
  const activationEntered = new Promise((resolve) => { activationStarted = resolve; });
  const activate = store.activate.bind(store);
  store.activate = async (input) => {
    activationStarted();
    await new Promise((resolve) => { releaseActivation = resolve; });
    await activate(input);
  };
  const { server, url } = await boot({ authStore: store });
  try {
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);
    mac.send({ type: 'pair.status.request', v: 1, requestId: STATUS_ID, pairingVersion: 1 });
    await mac.wait((message) => message.type === 'pair.status');
    mac.send({ type: 'pair.create', v: 1, requestId: REQUEST_ID, pairingVersion: 1 });
    await mac.wait((message) => message.type === 'pair.created');

    const claimant = peer(url);
    await claimant.open();
    claimant.send({
      type: 'pair.claim', v: 1, reference: REFERENCE, claimId: CLAIM_ID,
      sessionNonce: NONCE, pairingVersion: 1, clientKind: 'pwa',
    });
    await claimant.wait((message) => message.type === 'pair.claimed.phone');
    await mac.wait((message) => message.type === 'pair.claimed.mac');
    mac.send({ type: 'pair.approve', v: 1, requestId: REQUEST_ID, claimId: CLAIM_ID });
    await claimant.wait((message) => message.type === 'pair.credential');

    claimant.send({
      type: 'pair.credential.ack', v: 1, claimId: CLAIM_ID, credentialVersion: 1,
      proof: createHmac('sha256', Buffer.from(NEXT_TOKEN, 'hex'))
        .update(`clickbridge-pair-activate:v1:${CLAIM_ID}:1`).digest('hex'),
    });
    await activationEntered;

    // A different phone connects with the still-active old credential while
    // the new device's activation is in flight.
    const lateOldPhone = peer(url);
    await hello(lateOldPhone, 'phone', PHONE_TOKEN);
    claimant.send({ type: 'pair.cancel.claim', v: 1, claimId: CLAIM_ID });
    releaseActivation();

    await claimant.wait((message) => message.type === 'pair.active');
    await mac.wait((message) => message.type === 'pair.completed');
    // Additive: activation of the new device never touches lateOldPhone.
    assert.equal(lateOldPhone.ws.readyState, lateOldPhone.ws.OPEN);
    await stillAuthenticated(lateOldPhone);
    assert.equal(claimant.inbox.some((message) => message.type === 'pair.failed'), false);
  } finally {
    await server.close();
  }
});

test('readyz reports a poisoned auth store that healthz cannot see', async () => {
  // The container healthcheck uses /healthz and Caddy gates on
  // `condition: service_healthy`, so /healthz must stay pure liveness — a
  // poisoned auth store breaks pairing while clicking still works, and failing
  // liveness would escalate that into a total outage. /readyz is the surface
  // that can tell the two apart.
  let poisoned = false;
  const store = authStore();
  const base = store.snapshot.bind(store);
  store.snapshot = () => {
    if (poisoned) {
      const error = new Error('phone auth store unavailable');
      error.code = 'persistence_failed';
      throw error;
    }
    return base();
  };

  const { server, base: origin } = await boot({ authStore: store });
  try {
    const healthy = await fetch(`${origin}/readyz`);
    assert.equal(healthy.status, 200);
    assert.deepEqual(await healthy.json(), {
      live: true, pairing: { ready: true, detail: 'ok' },
    });

    poisoned = true;

    const live = await fetch(`${origin}/healthz`);
    assert.equal(live.status, 200, 'liveness must survive a pairing-only failure');
    assert.equal(await live.text(), 'ok');

    const ready = await fetch(`${origin}/readyz`);
    assert.equal(ready.status, 503);
    const body = await ready.json();
    assert.equal(body.pairing.ready, false);
    assert.match(body.pairing.detail, /restart the relay container/);
    assert.equal(body.pairing.detail.includes('phone auth store unavailable'), false,
      'must not echo internal error text, which can carry record paths');
  } finally {
    await server.close();
  }
});

test('readyz fails closed when the configured auth store cannot be probed', async () => {
  const store = authStore();
  delete store.snapshot;
  const { server, base: origin } = await boot({ authStore: store });
  try {
    const ready = await fetch(`${origin}/readyz`);
    assert.equal(ready.status, 503);
    assert.deepEqual(await ready.json(), {
      live: true, pairing: { ready: false, detail: 'unavailable' },
    });

    const live = await fetch(`${origin}/healthz`);
    assert.equal(live.status, 200, 'an invalid readiness probe must not change liveness');
  } finally {
    await server.close();
  }
});
