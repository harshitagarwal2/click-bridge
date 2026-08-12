import { pathToFileURL } from 'node:url';
import WebSocket from 'ws';

const lifetime = 2_000;

function request(actionId, issuedAtUnixMs) {
  return Object.freeze({ type: 'action.request', v: 1, actionId, action: 'click',
    issuedAtUnixMs, expiresAtUnixMs: issuedAtUnixMs + lifetime });
}

export async function runNegativeMatrix({ harness, nowUnixMs = Date.now, idGenerator = () => crypto.randomUUID() }) {
  const now = nowUnixMs();
  const duplicateRequest = request(idGenerator(), now);
  const duplicate = await harness.duplicate(duplicateRequest);
  const conflictOriginal = request(idGenerator(), now);
  const conflict = await harness.conflict(conflictOriginal, request(conflictOriginal.actionId, now + 1));
  const expired = await harness.expired(request(idGenerator(), now - lifetime - 1_001));
  const dropped = await harness.resultDrop(request(idGenerator(), now));
  return [
    { scenario: 'exact_duplicate', outcome: duplicate.exactCached && duplicate.increment === 1 ? 'pass' : 'fail', detail: duplicate },
    { scenario: 'id_conflict', outcome: conflict.reason === 'id_conflict' && conflict.increment === 0 ? 'pass' : 'fail', detail: conflict },
    { scenario: 'expired', outcome: expired.reason === 'expired' && expired.increment === 0 ? 'pass' : 'fail', detail: expired },
    { scenario: 'result_drop', outcome: !dropped.lateDelivery && !dropped.replay ? 'pass' : 'fail', detail: dropped },
  ];
}

class PhoneConnection {
  constructor(url, token) { this.url = url; this.token = token; this.socket = null; this.queue = []; this.waiters = []; }
  async connect() {
    this.socket = new WebSocket(this.url);
    this.socket.on('message', (data) => {
      const raw = data.toString();
      const message = JSON.parse(raw);
      Object.defineProperty(message, '__raw', { value: raw });
      this.#deliver(message);
    });
    await new Promise((resolve, reject) => { this.socket.once('open', resolve); this.socket.once('error', reject); });
    this.send({ type: 'hello', v: 1, role: 'phone', token: this.token });
    await this.next((message) => message.type === 'hello.ok');
  }
  send(message) { this.socket.send(JSON.stringify(message)); }
  async next(predicate, timeoutMs = 3_500) {
    const index = this.queue.findIndex(predicate);
    if (index >= 0) return this.queue.splice(index, 1)[0];
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve: (value) => { clearTimeout(waiter.timer); resolve(value); } };
      waiter.timer = setTimeout(() => {
        this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
        reject(new Error('timed out waiting for relay response'));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }
  async counters() {
    const requestId = crypto.randomUUID();
    this.send({ type: 'diagnostics.request', v: 1, requestId });
    return this.next((message) => message.type === 'diagnostics.counters' && message.requestId === requestId);
  }
  async close() {
    if (!this.socket || this.socket.readyState === WebSocket.CLOSED) return;
    await new Promise((resolve) => { this.socket.once('close', resolve); this.socket.close(); });
  }
  #deliver(message) {
    const waiter = this.waiters.find((candidate) => candidate.predicate(message));
    if (!waiter) { this.queue.push(message); return; }
    this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
    waiter.resolve(message);
  }
}

class LiveNegativeHarness {
  constructor(url, token) { this.url = url; this.token = token; }
  async #withConnection(operation) {
    const connection = new PhoneConnection(this.url, this.token);
    await connection.connect();
    try { return await operation(connection); } finally { await connection.close(); }
  }
  async duplicate(action) {
    return this.#withConnection(async (connection) => {
      const before = await connection.counters();
      connection.send(action);
      await connection.next((message) => message.type === 'relay.ack' && message.actionId === action.actionId);
      const first = await connection.next((message) => message.type === 'action.result' && message.actionId === action.actionId);
      connection.send(action);
      await connection.next((message) => message.type === 'relay.ack' && message.actionId === action.actionId);
      const second = await connection.next((message) => message.type === 'action.result' && message.actionId === action.actionId);
      const after = await connection.counters();
      return { exactCached: first.__raw === second.__raw,
        increment: after.mouseDownPostCount - before.mouseDownPostCount };
    });
  }
  async conflict(original, changed) {
    return this.#withConnection(async (connection) => {
      connection.send(original);
      await connection.next((message) => message.type === 'action.result' && message.actionId === original.actionId);
      const before = await connection.counters();
      connection.send(changed);
      const result = await connection.next((message) => message.type === 'action.result' && message.actionId === changed.actionId);
      const after = await connection.counters();
      return { reason: result.reason, increment: after.mouseDownPostCount - before.mouseDownPostCount };
    });
  }
  async expired(action) {
    return this.#withConnection(async (connection) => {
      const before = await connection.counters();
      connection.send(action);
      const ack = await connection.next((message) => message.type === 'relay.ack' && message.actionId === action.actionId);
      const after = await connection.counters();
      return { reason: ack.reason, increment: after.mouseDownPostCount - before.mouseDownPostCount };
    });
  }
  async resultDrop(action) {
    const first = new PhoneConnection(this.url, this.token);
    await first.connect();
    first.send(action);
    await first.next((message) => message.type === 'relay.ack' && message.actionId === action.actionId && message.status === 'forwarded');
    await first.close();
    await new Promise((resolve) => setTimeout(resolve, 500));
    const replacement = new PhoneConnection(this.url, this.token);
    await replacement.connect();
    let lateDelivery = false;
    try { await replacement.next((message) => message.type === 'action.result' && message.actionId === action.actionId, 750); lateDelivery = true; }
    catch (error) { if (!/timed out/.test(error.message)) throw error; }
    await replacement.close();
    return { lateDelivery, replay: lateDelivery };
  }
}

async function main() {
  if (!process.env.CLICK_BRIDGE_URL || !process.env.PHONE_TOKEN) {
    throw new Error('CLICK_BRIDGE_URL and PHONE_TOKEN are required; tokens are never command arguments');
  }
  const report = await runNegativeMatrix({
    harness: new LiveNegativeHarness(process.env.CLICK_BRIDGE_URL, process.env.PHONE_TOKEN),
  });
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (report.some((row) => row.outcome !== 'pass')) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
