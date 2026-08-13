import { mkdtemp } from 'node:fs/promises';
import * as fs from 'node:fs/promises';
import * as crypto from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import { WebSocket } from 'ws';

import { CREDENTIAL_REPLACED_CLOSE_CODE, CREDENTIAL_REPLACED_CLOSE_REASON, PROTOCOL_VERSION } from '../src/constants.js';
import { createPhoneAuthStore } from '../src/auth-store.js';
import { createServer } from '../src/server.js';

const PHONE_TOKEN = '1'.repeat(64);
const MAC_TOKEN = '2'.repeat(64);
const DOMAIN = 'relay.example.test';
const TEAM_ID = 'ABC123DE45';
const silent = { info() {} };
let requestSeq = 0;
const requestId = () => `018f63f5-6f3d-7d21-88bc-9ef561f0${(3000 + requestSeq++).toString(16).padStart(4, '0')}`;

function peer(url) {
  const ws = new WebSocket(url);
  const inbox = [];
  const waiters = [];
  const opened = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  let closed;
  const closedPromise = new Promise((resolve) => ws.once('close', (code, reasonBuffer) => {
    closed = { code, reason: reasonBuffer.toString() };
    resolve(closed);
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

async function hello(client, role, token) {
  await client.open();
  client.send({ type: 'hello', v: PROTOCOL_VERSION, role, token });
  return client.wait((message) => message.type === 'hello.ok');
}

async function bootWithRealAuthStore() {
  const directory = await mkdtemp(join(tmpdir(), 'clickbridge-phone-mgmt-'));
  const store = createPhoneAuthStore({
    recordPath: join(directory, 'phone-auth.json'),
    initialPhoneToken: PHONE_TOKEN,
    initialMacToken: MAC_TOKEN,
    fs,
    crypto,
    log: () => {},
  });
  const server = createServer({
    phoneToken: PHONE_TOKEN,
    macToken: MAC_TOKEN,
    clickBridgeDomain: DOMAIN,
    pairingEnabled: '1',
    appleTeamId: TEAM_ID,
    authStore: store,
    log: silent,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  const seededDeviceId = store.snapshot().phones[0].deviceId;
  return { server, store, seededDeviceId, url: `ws://127.0.0.1:${port}/ws` };
}

test('mac lists paired phones and revokes one, closing its live socket additively', async () => {
  const { server, seededDeviceId, url } = await bootWithRealAuthStore();
  try {
    const phone = peer(url);
    await hello(phone, 'phone', PHONE_TOKEN);
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);

    const listRequestId = requestId();
    mac.send({ type: 'phone.list.request', v: PROTOCOL_VERSION, requestId: listRequestId });
    const list = await mac.wait((message) => message.type === 'phone.list'
      && message.requestId === listRequestId);
    assert.equal(list.requestId, listRequestId);
    assert.equal(list.phones.length, 1);
    assert.equal(list.phones[0].deviceId, seededDeviceId);
    assert.equal(list.phones[0].status, 'active');
    assert.equal(list.phones[0].credentialVersion, 0);

    const revokeRequestId = requestId();
    mac.send({
      type: 'phone.revoke.request', v: PROTOCOL_VERSION,
      requestId: revokeRequestId, deviceId: seededDeviceId,
    });
    const [revoked, phoneClose] = await Promise.all([
      mac.wait((message) => message.type === 'phone.revoked' && message.requestId === revokeRequestId),
      phone.closed(),
    ]);
    assert.equal(revoked.requestId, revokeRequestId);
    assert.equal(revoked.deviceId, seededDeviceId);
    assert.equal(revoked.registryRevision, list.registryRevision + 1);
    assert.equal(phoneClose.code, CREDENTIAL_REPLACED_CLOSE_CODE);
    assert.equal(phoneClose.reason, CREDENTIAL_REPLACED_CLOSE_REASON);

    const secondListRequestId = requestId();
    mac.send({ type: 'phone.list.request', v: PROTOCOL_VERSION, requestId: secondListRequestId });
    const secondList = await mac.wait((message) => message.type === 'phone.list'
      && message.requestId === secondListRequestId);
    assert.equal(secondList.phones.length, 0);
  } finally {
    await server.close();
  }
});

test('revoking an already-revoked or unknown device reports a distinct failure reason', async () => {
  const { server, seededDeviceId, url } = await bootWithRealAuthStore();
  try {
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);

    const firstRevoke = requestId();
    mac.send({
      type: 'phone.revoke.request', v: PROTOCOL_VERSION, requestId: firstRevoke, deviceId: seededDeviceId,
    });
    await mac.wait((message) => message.type === 'phone.revoked');

    const secondRevoke = requestId();
    mac.send({
      type: 'phone.revoke.request', v: PROTOCOL_VERSION, requestId: secondRevoke, deviceId: seededDeviceId,
    });
    const alreadyRevoked = await mac.wait((message) => message.type === 'phone.revoke.failed'
      && message.requestId === secondRevoke);
    assert.equal(alreadyRevoked.reason, 'already_revoked');

    const unknownDeviceId = 'unknown-device-000001';
    const thirdRevoke = requestId();
    mac.send({
      type: 'phone.revoke.request', v: PROTOCOL_VERSION, requestId: thirdRevoke, deviceId: unknownDeviceId,
    });
    const unknownDevice = await mac.wait((message) => message.type === 'phone.revoke.failed'
      && message.requestId === thirdRevoke);
    assert.equal(unknownDevice.reason, 'unknown_device');
  } finally {
    await server.close();
  }
});

test('phone management is a no-op when pairing is disabled', async () => {
  const server = createServer({
    phoneToken: PHONE_TOKEN, macToken: MAC_TOKEN, clickBridgeDomain: DOMAIN, log: silent,
  });
  await server.listen(0, '127.0.0.1');
  const { port } = server.httpServer.address();
  const url = `ws://127.0.0.1:${port}/ws`;
  try {
    const mac = peer(url);
    await hello(mac, 'mac', MAC_TOKEN);

    const listReq = requestId();
    mac.send({ type: 'phone.list.request', v: PROTOCOL_VERSION, requestId: listReq });
    const list = await mac.wait((message) => message.type === 'phone.list');
    assert.deepEqual(list.phones, []);
    assert.equal(list.registryRevision, 0);

    const revokeReq = requestId();
    mac.send({
      type: 'phone.revoke.request', v: PROTOCOL_VERSION, requestId: revokeReq, deviceId: 'irrelevant-device01',
    });
    const failed = await mac.wait((message) => message.type === 'phone.revoke.failed');
    assert.equal(failed.reason, 'storage_failed');
  } finally {
    await server.close();
  }
});
