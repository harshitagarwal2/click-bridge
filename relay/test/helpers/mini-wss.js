// Minimal RFC 6455 server, TEST ONLY.
//
// Production uses `ws`. This exists so the socket-level tests can run in an
// environment with no package registry, driving the real server.js through
// Node's built-in WebSocket client. It implements exactly the surface
// server.js touches — nothing more.
//
// Not a `ws` replacement: no extensions, no fragmentation, no backpressure.

import { createHash, randomBytes } from 'node:crypto';
import { EventEmitter } from 'node:events';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const OPCODE = { CONT: 0x0, TEXT: 0x1, BINARY: 0x2, CLOSE: 0x8, PING: 0x9, PONG: 0xa };

function accept(key) {
  return createHash('sha1').update(key + GUID).digest('base64');
}

function frame(opcode, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload ?? '', 'utf8');
  const len = body.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode;              // FIN + opcode; server frames unmasked
  return Buffer.concat([header, body]);
}

class MiniSocket extends EventEmitter {
  constructor(socket, maxPayload) {
    super();
    this.socket = socket;
    this.maxPayload = maxPayload;
    this.readyState = 1;                  // OPEN
    this.isAlive = true;
    this.buffer = Buffer.alloc(0);

    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.#drain();
    });
    socket.on('close', () => this.#down());
    socket.on('error', (err) => { this.emit('error', err); this.#down(); });
  }

  #down() {
    if (this.readyState === 3) return;
    this.readyState = 3;                  // CLOSED
    this.emit('close');
  }

  #drain() {
    for (;;) {
      const buf = this.buffer;
      if (buf.length < 2) return;

      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) === 0x80;
      let len = buf[1] & 0x7f;
      let offset = 2;

      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2));
        offset = 10;
      }

      let mask;
      if (masked) {
        if (buf.length < offset + 4) return;
        mask = buf.subarray(offset, offset + 4);
        offset += 4;
      }

      if (buf.length < offset + len) return;

      const raw = buf.subarray(offset, offset + len);
      const payload = Buffer.from(raw);
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];

      this.buffer = buf.subarray(offset + len);

      // Enforce the same cap ws does via maxPayload.
      if (this.maxPayload && len > this.maxPayload) {
        this.close(1009, 'too large');
        return;
      }

      switch (opcode) {
        case OPCODE.TEXT:
          this.emit('message', payload, false);
          break;
        case OPCODE.BINARY:
          this.emit('message', payload, true);
          break;
        case OPCODE.PING:
          this.#raw(frame(OPCODE.PONG, payload));
          break;
        case OPCODE.PONG:
          this.isAlive = true;
          this.emit('pong');
          break;
        case OPCODE.CLOSE:
          this.#raw(frame(OPCODE.CLOSE, payload));
          this.socket.end();
          this.#down();
          return;
        default:
          break;
      }
    }
  }

  #raw(buf) {
    if (this.socket.writable) this.socket.write(buf);
  }

  send(data) {
    if (this.readyState !== 1) return;
    this.#raw(frame(OPCODE.TEXT, data));
  }

  ping() {
    if (this.readyState !== 1) return;
    this.#raw(frame(OPCODE.PING, Buffer.alloc(0)));
  }

  close(code = 1000, reason = '') {
    if (this.readyState !== 1) return;
    const body = Buffer.alloc(2 + Buffer.byteLength(reason));
    body.writeUInt16BE(code, 0);
    body.write(reason, 2);
    this.#raw(frame(OPCODE.CLOSE, body));
    this.readyState = 2;                  // CLOSING
    setTimeout(() => { this.socket.end(); this.#down(); }, 5).unref?.();
  }

  terminate() {
    this.socket.destroy();
    this.#down();
  }
}

export class MiniWebSocketServer extends EventEmitter {
  constructor({ maxPayload } = {}) {
    super();
    this.maxPayload = maxPayload;
    this.clients = new Set();
  }

  handleUpgrade(req, socket, _head, callback) {
    const key = req.headers['sec-websocket-key'];
    if (!key || req.headers.upgrade?.toLowerCase() !== 'websocket') {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }
    socket.setNoDelay(true);
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n'
      + 'Upgrade: websocket\r\n'
      + 'Connection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept(key)}\r\n\r\n`,
    );

    const ws = new MiniSocket(socket, this.maxPayload);
    this.clients.add(ws);
    ws.on('close', () => this.clients.delete(ws));
    callback(ws);
  }

  close(cb) {
    for (const ws of this.clients) ws.terminate();
    this.clients.clear();
    cb?.();
  }
}

/** Factory matching the shape server.js expects. */
export const miniWssFactory = (options) => new MiniWebSocketServer(options);

export { randomBytes };
