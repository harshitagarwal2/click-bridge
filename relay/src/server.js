// HTTP + WebSocket front end for the relay.
//
// Serves the phone PWA over plain HTTP (TLS is Caddy's job in production) and
// accepts WebSocket upgrades only at /ws.

import http from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { join, normalize, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';
import { WebSocketServer } from 'ws';

import { RelayState } from './relay.js';
import { CONTENT_SECURITY_POLICY, SECURITY_HEADERS } from './csp.js';
import { parseClientMessage, encodeMessage, ProtocolError } from './protocol.js';
import {
  PROTOCOL_VERSION,
  MAX_MESSAGE_BYTES,
  AUTH_TIMEOUT_MS,
  SERVER_PING_INTERVAL_MS,
  SERVER_PONG_TIMEOUT_MS,
  TOKEN_HEX_LENGTH,
} from './constants.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(HERE, '..', 'public');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function constantTimeEquals(a, b) {
  const ab = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ab.length !== bb.length) {
    // Still burn a comparison so length alone is not a fast path.
    timingSafeEqual(ab, ab);
    return false;
  }
  return timingSafeEqual(ab, bb);
}

function isValidToken(t) {
  return typeof t === 'string' && t.length === TOKEN_HEX_LENGTH && /^[0-9a-f]{64}$/.test(t);
}

export { CONTENT_SECURITY_POLICY };

export function createServer({ phoneToken, macToken, publicDir = PUBLIC_DIR, log = console }) {
  if (!isValidToken(phoneToken)) throw new Error('PHONE_TOKEN must be 64 lowercase hex characters');
  if (!isValidToken(macToken)) throw new Error('MAC_TOKEN must be 64 lowercase hex characters');
  if (constantTimeEquals(phoneToken, macToken)) throw new Error('PHONE_TOKEN and MAC_TOKEN must differ');

  const state = new RelayState({
    log: (event, detail) => log.info?.(JSON.stringify({ event, ...detail })),
  });

  const httpServer = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname;

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, SECURITY_HEADERS).end();
      return;
    }
    if (path === '/healthz') {
      res.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain' }).end('ok');
      return;
    }

    const rel = normalize(path === '/' ? '/index.html' : path).replace(/^(\.\.[/\\])+/, '');
    const file = join(publicDir, rel);
    if (!file.startsWith(publicDir)) {
      res.writeHead(403, SECURITY_HEADERS).end();
      return;
    }

    try {
      const info = await stat(file);
      if (!info.isFile()) throw new Error('not a file');
      res.writeHead(200, {
        ...SECURITY_HEADERS,
        'Content-Type': MIME[extname(file)] ?? 'application/octet-stream',
        'Content-Length': info.size,
        'Cache-Control': 'no-cache',
      });
      if (req.method === 'HEAD') return res.end();
      createReadStream(file).pipe(res);
    } catch {
      res.writeHead(404, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain' }).end('not found');
    }
  });

  httpServer.on('connection', (socket) => socket.setNoDelay(true));

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });

  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    if (url.pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });

  wss.on('connection', (ws) => {
    let role = null;
    ws.isAlive = true;

    const authTimer = setTimeout(() => {
      if (role === null) {
        log.info?.(JSON.stringify({ event: 'auth_timeout' }));
        ws.close(4001, 'auth timeout');
      }
    }, AUTH_TIMEOUT_MS);
    authTimer.unref?.();

    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        if (role === null) return ws.close(4002, 'binary during auth');
        return; // ignore after auth
      }
      const raw = data.toString('utf8');

      if (role === null) {
        let hello;
        try {
          hello = parseClientMessage(raw, null);
        } catch (err) {
          const code = err instanceof ProtocolError ? err.code : 'error';
          log.info?.(JSON.stringify({ event: 'auth_rejected', code }));
          return ws.close(4003, 'bad hello');
        }
        const expected = hello.role === 'phone' ? phoneToken : macToken;
        if (!constantTimeEquals(hello.token, expected)) {
          log.info?.(JSON.stringify({ event: 'auth_rejected', code: 'bad_token', role: hello.role }));
          return ws.close(4003, 'bad token');
        }

        role = hello.role;
        clearTimeout(authTimer);
        state.replaceRole(role, ws);
        ws.send(encodeMessage({ type: 'hello.ok', v: PROTOCOL_VERSION, role }));
        log.info?.(JSON.stringify({ event: 'authenticated', role }));

        if (role === 'phone') state.publishState();
        else state.publishState(); // Mac arrival flips macOnline for the phone
        return;
      }

      state.handleMessage(role, ws, raw);
    });

    ws.on('close', () => {
      clearTimeout(authTimer);
      if (role) {
        state.detachIfCurrent(role, ws);
        log.info?.(JSON.stringify({ event: 'disconnected', role }));
      }
    });

    ws.on('error', () => { /* close handler does the cleanup */ });
  });

  // Server-side liveness, independent of the application heartbeat.
  const pingTimer = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* terminating */ }
    }
  }, SERVER_PING_INTERVAL_MS);
  pingTimer.unref?.();

  // ws has no per-socket pong deadline; the next sweep terminates a silent
  // socket, so the effective bound is one interval plus the timeout budget.
  const pongBudgetMs = SERVER_PING_INTERVAL_MS + SERVER_PONG_TIMEOUT_MS;

  return {
    httpServer,
    wss,
    state,
    pongBudgetMs,
    listen: (port, host) => new Promise((r) => httpServer.listen(port, host, r)),
    close: async () => {
      clearInterval(pingTimer);
      state.dispose();
      for (const ws of wss.clients) ws.terminate();
      await new Promise((r) => wss.close(r));
      await new Promise((r) => httpServer.close(r));
    },
  };
}

// -- CLI ---------------------------------------------------------------------

const isMain = process.argv[1] &&
  import.meta.url === `file://${process.argv[1]}`;

if (isMain) {
  const port = Number(process.env.PORT ?? 8080);
  const host = process.env.HOST ?? '0.0.0.0';
  const phoneToken = process.env.PHONE_TOKEN ?? '';
  const macToken = process.env.MAC_TOKEN ?? '';

  let server;
  try {
    server = createServer({ phoneToken, macToken });
  } catch (err) {
    console.error(`startup refused: ${err.message}`);
    process.exit(1);
  }
  await server.listen(port, host);
  console.log(JSON.stringify({ event: 'listening', port, host }));

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, async () => {
      await server.close();
      process.exit(0);
    });
  }
}
