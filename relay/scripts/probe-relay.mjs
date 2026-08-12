#!/usr/bin/env node
// Adversarial probes against a LIVE relay. The unit suite tests what the author
// expected; this tests the negative surface — malformed input, wrong roles,
// HTTP methods nobody meant to expose, and the displacement path that no unit
// test can reach because every unit test connects exactly one phone.
//
//   PHONE_TOKEN=<64hex> MAC_TOKEN=<64hex> \
//     node scripts/probe-relay.mjs ws://127.0.0.1:8123/ws [/path/to/relay.log]
//
// Exit 0 only if every probe passes.

import { randomUUID } from 'node:crypto';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PROTOCOL_VERSION, ACTION_LIFETIME_MS, MAX_MESSAGE_BYTES,
  AUTH_TIMEOUT_MS, CLOSE_ROLE_REPLACED,
} from '../src/constants.js';

const wsUrl = process.argv[2] ?? 'ws://127.0.0.1:8123/ws';
const logPath = process.argv[3] ?? null;
const httpBase = wsUrl.replace(/^ws/, 'http').replace(/\/ws$/, '');

const PHONE_TOKEN = process.env.PHONE_TOKEN ?? '';
const MAC_TOKEN = process.env.MAC_TOKEN ?? '';
if (!/^[0-9a-f]{64}$/.test(PHONE_TOKEN) || !/^[0-9a-f]{64}$/.test(MAC_TOKEN)) {
  console.error('PHONE_TOKEN and MAC_TOKEN must each be 64 lowercase hex characters');
  process.exit(2);
}

const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  — ${detail}` : ''}`);
}

const hello = (role, token) => ({ type: 'hello', v: PROTOCOL_VERSION, role, token });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * A socket whose close listener is attached at construction. The obvious
 * version — attach after triggering the event — silently misses a close that
 * has already happened, which reads as a product bug when it is a probe bug.
 */
function open(label) {
  const ws = new WebSocket(wsUrl);
  const inbox = [];
  const waiters = [];
  let closed = null;
  const closeWaiters = [];

  ws.addEventListener('message', (e) => {
    if (typeof e.data !== 'string') return;
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].match(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
    }
  });
  ws.addEventListener('close', (e) => {
    closed = { code: e.code, reason: e.reason };
    while (closeWaiters.length) closeWaiters.pop()(closed);
  });
  ws.addEventListener('error', () => {});

  return {
    label, ws, inbox,
    get closed() { return closed; },
    ready: () => new Promise((res, rej) => {
      if (ws.readyState === 1) return res();
      ws.addEventListener('open', () => res(), { once: true });
      ws.addEventListener('close', () => rej(new Error(`${label}: closed before open`)), { once: true });
    }),
    send: (m) => ws.send(typeof m === 'string' ? m : JSON.stringify(m)),
    raw: (data) => ws.send(data),
    wait(match, ms = 4000) {
      const hit = inbox.find(match);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error(`${label}: timeout waiting for message`)), ms);
        waiters.push({ match, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    /** Resolves with {code} — immediately if the close already happened. */
    waitClose(ms = 4000) {
      if (closed) return Promise.resolve(closed);
      return new Promise((resolve) => {
        const t = setTimeout(() => resolve(null), ms);
        closeWaiters.push((c) => { clearTimeout(t); resolve(c); });
      });
    },
    kill: () => { try { ws.close(); } catch { /* gone */ } },
  };
}

async function authed(label, role, token) {
  const c = open(label);
  await c.ready();
  c.send(hello(role, token));
  await c.wait((m) => m.type === 'hello.ok');
  return c;
}

const live = [];
const track = (c) => { live.push(c); return c; };

try {
  // -- 1. oversized frame ----------------------------------------------------
  {
    const c = track(open('oversize'));
    await c.ready();
    c.send(hello('phone', PHONE_TOKEN));
    await c.wait((m) => m.type === 'hello.ok');
    c.raw(JSON.stringify({ type: 'heartbeat.request', v: 1, sequence: 1, pad: 'x'.repeat(MAX_MESSAGE_BYTES) }));
    const closed = await c.waitClose(3000);
    check('oversized frame closes the socket instead of being processed',
      closed !== null, closed ? `code ${closed.code}` : 'stayed open');
  }

  // -- 2. auth timeout -------------------------------------------------------
  {
    const c = track(open('silent'));
    await c.ready();
    const closed = await c.waitClose(AUTH_TIMEOUT_MS + 2000);
    check('a silent client is dropped at the auth deadline',
      closed?.code === 4001, closed ? `code ${closed.code}` : 'never closed');
  }

  // -- 3/4. cross-role tokens ------------------------------------------------
  for (const [role, token, label] of [
    ['mac', PHONE_TOKEN, "phone token cannot authenticate as mac"],
    ['phone', MAC_TOKEN, "mac token cannot authenticate as phone"],
  ]) {
    const c = track(open(label));
    await c.ready();
    c.send(hello(role, token));
    const closed = await c.waitClose(3000);
    check(label, closed?.code === 4003, closed ? `code ${closed.code}` : 'accepted!');
  }

  // -- 5. binary during auth -------------------------------------------------
  {
    const c = track(open('binary'));
    await c.ready();
    c.raw(new Uint8Array([1, 2, 3, 4]));
    const closed = await c.waitClose(3000);
    check('a binary frame before auth is refused',
      closed?.code === 4002, closed ? `code ${closed.code}` : 'ignored');
  }

  // -- 6. malformed hello ----------------------------------------------------
  {
    const c = track(open('badhello'));
    await c.ready();
    c.send('{not json');
    const closed = await c.waitClose(3000);
    check('a malformed hello is refused', closed?.code === 4003,
      closed ? `code ${closed.code}` : 'ignored');
  }

  // -- 7. HTTP surface -------------------------------------------------------
  {
    const health = await fetch(`${httpBase}/healthz`);
    check('GET /healthz is ok', health.status === 200 && (await health.text()).trim() === 'ok');

    const post = await fetch(`${httpBase}/healthz`, { method: 'POST' });
    check('POST /healthz is not accepted', post.status !== 200, `status ${post.status}`);

    for (const path of ['/../src/server.js', '/..%2fsrc%2fserver.js', '/%2e%2e/src/constants.js']) {
      const r = await fetch(`${httpBase}${path}`);
      const body = await r.text();
      const leaked = r.status === 200 && /RelayState|PROTOCOL_VERSION|import /.test(body);
      check(`path traversal ${path} does not serve src/`, !leaked, `status ${r.status}`);
    }

    const ws404 = await fetch(`${httpBase}/nope`);
    check('an unknown path is 404', ws404.status === 404, `status ${ws404.status}`);
  }

  // -- 8. stale action never reaches the Mac ---------------------------------
  {
    const mac = track(await authed('mac', 'mac', MAC_TOKEN));
    mac.send({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' });
    const phone = track(await authed('phone', 'phone', PHONE_TOKEN));
    await phone.wait((m) => m.type === 'state' && m.macOnline);

    const issued = Date.now() - (ACTION_LIFETIME_MS + 5000);
    const actionId = randomUUID();
    phone.send({
      type: 'action.request', v: PROTOCOL_VERSION, actionId, action: 'click',
      issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS,
    });
    const ack = await phone.wait((m) => m.type === 'relay.ack');
    check('an already-expired action is rejected at the relay',
      ack.status === 'rejected', `status ${ack.status}`);
    await sleep(300);
    check('the expired action never reached the mac',
      mac.inbox.every((m) => m.actionId !== actionId));

    // -- 9. garbage after auth does not kill a working session ---------------
    phone.send('{"type":"nope","v":1}');
    phone.send('{"type":"state","v":2}');
    phone.send('{broken');
    await sleep(200);
    const fresh = Date.now();
    const goodId = randomUUID();
    phone.send({
      type: 'action.request', v: PROTOCOL_VERSION, actionId: goodId, action: 'click',
      issuedAtUnixMs: fresh, expiresAtUnixMs: fresh + ACTION_LIFETIME_MS,
    });
    const ack2 = await phone.wait((m) => m.type === 'relay.ack' && m.actionId === goodId);
    check('the session survives malformed post-auth frames',
      ack2.status === 'forwarded', `status ${ack2.status}`);
    await mac.wait((m) => m.type === 'action.request' && m.actionId === goodId);
    check('a valid action still reaches the mac afterwards', true);

    phone.kill(); mac.kill();
    await sleep(150);
  }

  // -- 10. displacement: the close code is the whole fix ---------------------
  // The listener is attached at construction, BEFORE phone B connects. Attaching
  // it afterwards misses the close and looks like a missing event.
  {
    const mac = track(await authed('mac', 'mac', MAC_TOKEN));
    mac.send({ type: 'mac.state', v: PROTOCOL_VERSION, remoteEnabled: true, permission: 'ready' });

    const phoneA = track(await authed('phoneA', 'phone', PHONE_TOKEN));
    await phoneA.wait((m) => m.type === 'state');

    const phoneB = track(await authed('phoneB', 'phone', PHONE_TOKEN));

    const closed = await phoneA.waitClose(3000);
    check('the displaced phone is closed', closed !== null,
      closed ? `code ${closed.code}` : 'still open');
    check('the displaced phone gets a distinct application close code',
      closed?.code === CLOSE_ROLE_REPLACED,
      `code ${closed?.code} (1005/1006 would be indistinguishable from a drop)`);

    // The replacement must be fully functional, not collateral damage.
    const issued = Date.now();
    const actionId = randomUUID();
    phoneB.send({
      type: 'action.request', v: PROTOCOL_VERSION, actionId, action: 'click',
      issuedAtUnixMs: issued, expiresAtUnixMs: issued + ACTION_LIFETIME_MS,
    });
    const ack = await phoneB.wait((m) => m.type === 'relay.ack' && m.actionId === actionId);
    check('the replacing phone works immediately', ack.status === 'forwarded');

    mac.send({
      type: 'action.result', v: PROTOCOL_VERSION, actionId, status: 'posted', reason: 'ok',
      acceptedVia: 'oci', macProcessingUs: 700, mouseDownPostedUnixMs: Date.now(),
    });
    await phoneB.wait((m) => m.type === 'action.result' && m.actionId === actionId);
    check('the result goes to the replacement, not the displaced phone',
      phoneA.inbox.every((m) => m.type !== 'action.result'));

    phoneB.kill(); mac.kill();
    await sleep(150);
  }

  // -- 11. the PWA import graph actually resolves ----------------------------
  {
    const pub = resolve(dirname(fileURLToPath(import.meta.url)), '../public');
    const files = readdirSync(pub).filter((f) => f.endsWith('.js'));
    const missing = [];
    let edges = 0;
    for (const f of files) {
      const src = readFileSync(join(pub, f), 'utf8');
      for (const m of src.matchAll(/from\s+'(\.[^']+)'/g)) {
        edges += 1;
        if (!existsSync(join(pub, m[1]))) missing.push(`${f} -> ${m[1]}`);
      }
    }
    check(`every PWA import resolves (${files.length} modules, ${edges} edges)`,
      missing.length === 0, missing.join(', '));

    const html = readFileSync(join(pub, 'index.html'), 'utf8');
    const ids = [...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]);
    const app = readFileSync(join(pub, 'app.js'), 'utf8');
    const wanted = [...app.matchAll(/\$\('([^']+)'\)/g)].map((m) => m[1]);
    const absent = wanted.filter((id) => !ids.includes(id));
    check(`every element app.js looks up exists in index.html (${wanted.length} ids)`,
      absent.length === 0, absent.join(', '));

    const inline = /<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>|<style[\s>]/.test(html);
    check('index.html has no inline script or style (CSP would block it)', !inline);
  }

  // -- 12. tokens never reach the log ---------------------------------------
  if (logPath && existsSync(logPath)) {
    const log = readFileSync(logPath, 'utf8');
    const hits = (log.split(PHONE_TOKEN).length - 1) + (log.split(MAC_TOKEN).length - 1);
    check('no token appears anywhere in the relay log', hits === 0, `${hits} occurrences`);
  } else {
    check('relay log was provided for the token-leak check', false,
      'pass the log path as argv[3] — SKIPPED IS NOT PASSED');
  }
} catch (err) {
  check(`probe harness failed: ${err.message}`, false);
} finally {
  for (const c of live) c.kill();
}

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} probes passed`);
process.exit(failed === 0 ? 0 : 1);
