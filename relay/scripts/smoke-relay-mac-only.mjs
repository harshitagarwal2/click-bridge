#!/usr/bin/env node
// Public deploy smoke for an installation whose provisioned legacy phone
// credential has been retired. It proves positive Mac authentication and
// verifies that the retired phone credential remains rejected without
// replacing or revoking any paired phone.

import { WebSocket } from 'ws';
import { pathToFileURL } from 'node:url';

import {
  AUTHENTICATION_REJECTED_CLOSE_CODE,
  PROTOCOL_VERSION,
} from '../src/constants.js';

const url = process.argv[2] ?? 'ws://127.0.0.1:8080/ws';
const PHONE_TOKEN = process.env.PHONE_TOKEN ?? '';
const MAC_TOKEN = process.env.MAC_TOKEN ?? '';

function connect(label) {
  const ws = new WebSocket(url);
  const inbox = [];
  let closeValue;
  let closeResolve;
  const closePromise = new Promise((resolve) => { closeResolve = resolve; });
  const openPromise = new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  ws.on('message', (data) => inbox.push(JSON.parse(data.toString())));
  ws.on('close', (code) => {
    closeValue = code;
    closeResolve(code);
  });
  return {
    ws,
    open: () => openPromise,
    closed: () => closeValue === undefined ? closePromise : Promise.resolve(closeValue),
    send: (message) => ws.send(JSON.stringify(message)),
    async wait(match, timeoutMs = 5_000) {
      const existing = inbox.find(match);
      if (existing) return existing;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`${label}: timeout`)), timeoutMs);
        const listener = (data) => {
          const message = JSON.parse(data.toString());
          if (!match(message)) return;
          clearTimeout(timer);
          ws.off('message', listener);
          resolve(message);
        };
        ws.on('message', listener);
      });
    },
    close: () => ws.close(),
  };
}

async function main() {
  if (!/^[0-9a-f]{64}$/.test(PHONE_TOKEN) || !/^[0-9a-f]{64}$/.test(MAC_TOKEN)) {
    console.error('PHONE_TOKEN and MAC_TOKEN must each be 64 lowercase hex characters');
    process.exit(2);
  }

  const checks = [];
  const check = (name, ok) => {
    checks.push({ name, ok });
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
  };
  const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });
  const mac = connect('mac');
  const retiredPhone = connect('retired phone');

  try {
    await Promise.all([mac.open(), retiredPhone.open()]);
    mac.send(hello('mac', MAC_TOKEN));
    const macHello = await mac.wait((message) => message.type === 'hello.ok');
    check('mac authenticated', macHello.role === 'mac');

    retiredPhone.send(hello('phone', PHONE_TOKEN));
    check(
      'retired legacy phone credential rejected',
      await retiredPhone.closed() === AUTHENTICATION_REJECTED_CLOSE_CODE,
    );
  } catch (error) {
    check(`unexpected failure: ${error.message}`, false);
  } finally {
    mac.close();
    retiredPhone.close();
  }

  const failed = checks.filter((checkResult) => !checkResult.ok).length;
  console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
  process.exit(failed === 0 ? 0 : 1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
