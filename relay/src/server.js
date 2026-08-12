import { timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { WebSocketServer } from 'ws';

import {
  AUTH_TIMEOUT_MS,
  MAX_MESSAGE_BYTES,
  MAX_TOTAL_WEBSOCKET_CONNECTIONS,
  MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS,
  PROTOCOL_VERSION,
  SERVER_PING_INTERVAL_MS,
  SERVER_PONG_TIMEOUT_MS,
  TERMINAL_CLOSE_DEADLINE_MS,
  TOKEN_HEX_LENGTH,
} from './constants.js';
import { createSecurityHeaders } from './csp.js';
import { encodeMessage, parseClientMessage, ProtocolError } from './protocol.js';
import { RelayState } from './relay.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PUBLIC_DIR = join(HERE, '..', 'public');

function validateAdmissionLimits(maxTotal, maxUnauthenticated) {
  if (!Number.isInteger(maxTotal) || maxTotal < 1
      || maxTotal > MAX_TOTAL_WEBSOCKET_CONNECTIONS) {
    throw new Error(
      `maxTotalWebSocketConnections must be an integer from 1 through ${MAX_TOTAL_WEBSOCKET_CONNECTIONS}`,
    );
  }
  if (!Number.isInteger(maxUnauthenticated) || maxUnauthenticated < 1
      || maxUnauthenticated > MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS
      || maxUnauthenticated > maxTotal) {
    throw new Error(
      'maxUnauthenticatedWebSocketConnections must be a positive integer no greater than '
      + `both ${MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS} and maxTotalWebSocketConnections`,
    );
  }
}

function createAdmissionController(maxTotal, maxUnauthenticated) {
  let total = 0;
  let unauthenticated = 0;

  return {
    reserve() {
      if (total >= maxTotal || unauthenticated >= maxUnauthenticated) return null;
      total += 1;
      unauthenticated += 1;
      let holdsTotal = true;
      let holdsUnauthenticated = true;
      let callbackAccepted = false;

      const releaseUnauthenticated = () => {
        if (!holdsUnauthenticated) return;
        holdsUnauthenticated = false;
        unauthenticated -= 1;
      };
      return Object.freeze({
        acceptCallback() {
          if (!holdsTotal || callbackAccepted) return false;
          callbackAccepted = true;
          return true;
        },
        releaseUnauthenticated,
        releaseAll() {
          releaseUnauthenticated();
          if (!holdsTotal) return;
          holdsTotal = false;
          total -= 1;
        },
      });
    },
  };
}

function rejectUpgradeForCapacity(socket) {
  let fallback;
  const destroy = () => {
    if (fallback) clearTimeout(fallback);
    if (!socket.destroyed) socket.destroy();
  };
  socket.once('close', () => {
    if (fallback) clearTimeout(fallback);
  });
  socket.once('error', destroy);
  socket.end(
    'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n',
    destroy,
  );
  fallback = setTimeout(destroy, 100);
  fallback.unref?.();
}

function destroyRejectedWebSocket(ws) {
  if (ws) ws.__clickBridgeTerminal = true;
  try {
    if (typeof ws?.terminate === 'function') ws.terminate();
    else if (typeof ws?.close === 'function') ws.close();
  } catch {
    // Admission is already revoked; disposal is best-effort.
  }
}

function terminateWebSocket(ws) {
  if (!ws) return;
  ws.__clickBridgeTerminal = true;
  try {
    if (ws.readyState !== ws.CLOSED) ws.terminate();
  } catch {
    // The socket is already terminal; teardown is best-effort.
  }
}

function closeWithDeadline(ws, code, reason, deadlineMs, scheduleDeadline = setTimeout) {
  if (ws.__clickBridgeTerminal || ws.readyState === ws.CLOSED) return;
  ws.__clickBridgeTerminal = true;
  try {
    ws.close(code, reason);
  } catch {
    terminateWebSocket(ws);
    return;
  }
  if (ws.readyState === ws.CLOSED) return;
  const timer = scheduleDeadline(() => {
    ws.__clickBridgeCloseTimer = null;
    terminateWebSocket(ws);
  }, deadlineMs);
  timer.unref?.();
  ws.__clickBridgeCloseTimer = timer;
}

const STATIC_FILES = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/index.html', ['index.html', 'text/html; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/state.js', ['state.js', 'text/javascript; charset=utf-8']],
  ['/wire-protocol.js', ['wire-protocol.js', 'text/javascript; charset=utf-8']],
  ['/runtime-constants.js', ['runtime-constants.js', 'text/javascript; charset=utf-8']],
  ['/runtime-scheduler.js', ['runtime-scheduler.js', 'text/javascript; charset=utf-8']],
  ['/transport-controller.js', ['transport-controller.js', 'text/javascript; charset=utf-8']],
  ['/relay-transport.js', ['relay-transport.js', 'text/javascript; charset=utf-8']],
  ['/transport-coordinator.js', ['transport-coordinator.js', 'text/javascript; charset=utf-8']],
  ['/clock-health-controller.js', ['clock-health-controller.js', 'text/javascript; charset=utf-8']],
  ['/phone-settings-store.js', ['phone-settings-store.js', 'text/javascript; charset=utf-8']],
  ['/wake-lock-controller.js', ['wake-lock-controller.js', 'text/javascript; charset=utf-8']],
  ['/benchmark-session.js', ['benchmark-session.js', 'text/javascript; charset=utf-8']],
  ['/benchmark-controller.js', ['benchmark-controller.js', 'text/javascript; charset=utf-8']],
  ['/manifest.webmanifest', ['manifest.webmanifest', 'application/manifest+json; charset=utf-8']],
  ['/icons/icon-192.png', ['icons/icon-192.png', 'image/png']],
  ['/icons/icon-512.png', ['icons/icon-512.png', 'image/png']],
  ['/icons/apple-touch-icon-180.png', ['icons/apple-touch-icon-180.png', 'image/png']],
]);

function isValidToken(token) {
  return typeof token === 'string'
    && token.length === TOKEN_HEX_LENGTH
    && /^[0-9a-f]{64}$/.test(token);
}

function isValidHostname(hostname) {
  if (typeof hostname !== 'string' || hostname.length === 0 || hostname.length > 253) return false;
  if (hostname !== hostname.trim() || hostname.endsWith('.')) return false;
  const labels = hostname.split('.');
  return labels.every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
}

function constantTimeEquals(left, right) {
  const leftBytes = Buffer.from(left, 'utf8');
  const rightBytes = Buffer.from(right, 'utf8');
  if (leftBytes.length !== rightBytes.length) {
    const padded = Buffer.alloc(Math.max(leftBytes.length, rightBytes.length, 1));
    timingSafeEqual(padded, padded);
    return false;
  }
  return timingSafeEqual(leftBytes, rightBytes);
}

function writeResponse(res, status, headers, body = '') {
  res.writeHead(status, headers);
  res.end(body);
}

export function createHttpHandler({ publicDir = DEFAULT_PUBLIC_DIR, clickBridgeDomain }) {
  const securityHeaders = createSecurityHeaders(clickBridgeDomain);
  return async function handleHttp(req, res) {
    let pathname;
    try {
      pathname = new URL(req.url ?? '/', 'http://relay.invalid').pathname;
    } catch {
      writeResponse(res, 400, securityHeaders);
      return;
    }

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      writeResponse(res, 405, { ...securityHeaders, Allow: 'GET, HEAD' });
      return;
    }
    if (pathname === '/healthz') {
      const body = req.method === 'HEAD' ? '' : 'ok';
      writeResponse(res, 200, {
        ...securityHeaders,
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': 2,
        'Cache-Control': 'no-store',
      }, body);
      return;
    }

    const staticFile = STATIC_FILES.get(pathname);
    if (!staticFile) {
      writeResponse(res, 404, { ...securityHeaders, 'Content-Type': 'text/plain; charset=utf-8' }, 'not found');
      return;
    }
    const [relativePath, contentType] = staticFile;
    try {
      const body = await readFile(join(publicDir, relativePath));
      writeResponse(res, 200, {
        ...securityHeaders,
        'Content-Type': contentType,
        'Content-Length': body.byteLength,
        'Cache-Control': 'no-cache',
      }, req.method === 'HEAD' ? '' : body);
    } catch (error) {
      const status = error?.code === 'ENOENT' ? 404 : 500;
      writeResponse(res, status, {
        ...securityHeaders,
        'Content-Type': 'text/plain; charset=utf-8',
      }, status === 404 ? 'not found' : 'internal error');
    }
  };
}

export function attachWebSocketServer({
  httpServer,
  state,
  connections,
  phoneToken,
  macToken,
  log = console,
  parseClient = parseClientMessage,
  encode = encodeMessage,
  authTimeoutMs = AUTH_TIMEOUT_MS,
  pingIntervalMs = SERVER_PING_INTERVAL_MS,
  pongTimeoutMs = SERVER_PONG_TIMEOUT_MS,
  terminalCloseDeadlineMs = TERMINAL_CLOSE_DEADLINE_MS,
  scheduleAuthTimeout = setTimeout,
  scheduleTerminalClose = setTimeout,
  maxTotalWebSocketConnections = MAX_TOTAL_WEBSOCKET_CONNECTIONS,
  maxUnauthenticatedWebSocketConnections = MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS,
  performWebSocketUpgrade,
}) {
  validateAdmissionLimits(
    maxTotalWebSocketConnections,
    maxUnauthenticatedWebSocketConnections,
  );
  if (!Number.isInteger(terminalCloseDeadlineMs) || terminalCloseDeadlineMs < 1
      || terminalCloseDeadlineMs > AUTH_TIMEOUT_MS) {
    throw new Error(`terminalCloseDeadlineMs must be an integer from 1 through ${AUTH_TIMEOUT_MS}`);
  }
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
  const admissionController = createAdmissionController(
    maxTotalWebSocketConnections,
    maxUnauthenticatedWebSocketConnections,
  );
  const upgrade = performWebSocketUpgrade
    ?? ((req, socket, head, done) => wss.handleUpgrade(req, socket, head, done));
  let nextConnectionId = 0;

  const onUpgrade = (req, socket, head) => {
    let pathname;
    try {
      pathname = new URL(req.url ?? '/', 'http://relay.invalid').pathname;
    } catch {
      pathname = '';
    }
    if (pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const admission = admissionController.reserve();
    if (!admission) {
      rejectUpgradeForCapacity(socket);
      return;
    }
    socket.once('close', () => admission.releaseAll());
    socket.once('error', () => admission.releaseAll());
    socket.setNoDelay?.(true);
    let acceptedWebSocket = null;
    try {
      upgrade(req, socket, head, (ws) => {
        if (!admission.acceptCallback()) {
          destroyRejectedWebSocket(ws);
          return;
        }
        acceptedWebSocket = ws;
        try {
          ws.__clickBridgeAdmission = admission;
          wss.emit('connection', ws, req);
        } catch {
          destroyRejectedWebSocket(ws);
          admission.releaseAll();
          socket.destroy();
          log.info?.(JSON.stringify({
            event: 'upgrade_internal_error', code: 'connection_callback_failure',
          }));
        }
      });
    } catch {
      destroyRejectedWebSocket(acceptedWebSocket);
      admission.releaseAll();
      socket.destroy();
      log.info?.(JSON.stringify({ event: 'upgrade_internal_error', code: 'upgrade_throw' }));
    }
  };
  httpServer.on('upgrade', onUpgrade);

  wss.on('connection', (ws) => {
    const admission = ws.__clickBridgeAdmission;
    let role = null;
    let connection = null;
    ws.__clickBridgePongTimer = null;
    const authTimer = scheduleAuthTimeout(() => {
      if (role === null) {
        log.info?.(JSON.stringify({ event: 'auth_timeout' }));
        closeWithDeadline(
          ws, 4001, 'auth timeout', terminalCloseDeadlineMs, scheduleTerminalClose,
        );
      }
    }, authTimeoutMs);
    authTimer.unref?.();

    ws.on('pong', () => {
      if (ws.__clickBridgePongTimer) clearTimeout(ws.__clickBridgePongTimer);
      ws.__clickBridgePongTimer = null;
    });

    ws.on('message', (data, isBinary) => {
      if (ws.__clickBridgeTerminal) return;
      const raw = isBinary ? data : data.toString('utf8');
      if (role === null) {
        let message;
        try {
          message = parseClient(raw, null);
        } catch (error) {
          if (error instanceof ProtocolError) {
            log.info?.(JSON.stringify({ event: 'auth_rejected', code: error.code }));
            closeWithDeadline(
              ws, 4003, 'bad hello', terminalCloseDeadlineMs, scheduleTerminalClose,
            );
          } else {
            log.info?.(JSON.stringify({ event: 'auth_internal_error', code: 'parser_failure' }));
            closeWithDeadline(
              ws, 1011, 'internal error', terminalCloseDeadlineMs, scheduleTerminalClose,
            );
          }
          return;
        }
        const expectedToken = message.role === 'phone' ? phoneToken : macToken;
        if (!constantTimeEquals(message.token, expectedToken)) {
          log.info?.(JSON.stringify({
            event: 'auth_rejected', code: 'bad_token', role: message.role,
          }));
          closeWithDeadline(
            ws, 4003, 'bad token', terminalCloseDeadlineMs, scheduleTerminalClose,
          );
          return;
        }

        if (ws.__clickBridgeTerminal) return;
        role = message.role;
        clearTimeout(authTimer);
        admission.releaseUnauthenticated();
        connection = Object.freeze({ id: ++nextConnectionId, role });
        connections.set(connection, ws);
        state.replaceRole(role, connection);
        ws.send(encode({ type: 'hello.ok', v: PROTOCOL_VERSION, role }));
        state.publishState();
        log.info?.(JSON.stringify({ event: 'authenticated', role }));
        return;
      }

      let message;
      try {
        message = parseClient(raw, role);
      } catch (error) {
        if (error instanceof ProtocolError) {
          log.info?.(JSON.stringify({
            event: 'message_rejected', role, code: error.code,
          }));
        } else {
          log.info?.(JSON.stringify({
            event: 'message_internal_error', role, code: 'parser_failure',
          }));
          closeWithDeadline(
            ws, 1011, 'internal error', terminalCloseDeadlineMs, scheduleTerminalClose,
          );
        }
        return;
      }
      if (role === 'phone') state.handlePhoneMessage(connection, message);
      else state.handleMacMessage(connection, message);
    });

    ws.on('close', () => {
      admission.releaseAll();
      clearTimeout(authTimer);
      if (ws.__clickBridgeCloseTimer) clearTimeout(ws.__clickBridgeCloseTimer);
      ws.__clickBridgeCloseTimer = null;
      if (ws.__clickBridgePongTimer) clearTimeout(ws.__clickBridgePongTimer);
      ws.__clickBridgePongTimer = null;
      if (connection) {
        connections.delete(connection);
        state.detachIfCurrent(role, connection);
        log.info?.(JSON.stringify({ event: 'disconnected', role }));
      }
    });
    ws.on('error', (error) => {
      ws.__clickBridgeTerminal = true;
      admission.releaseAll();
      log.info?.(JSON.stringify({
        event: 'socket_error', role: role ?? 'unauthenticated',
        code: typeof error?.code === 'string' ? error.code : 'socket_error',
      }));
      terminateWebSocket(ws);
    });
  });

  const pingTimer = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.readyState !== ws.OPEN) continue;
      if (ws.__clickBridgePongTimer) continue;
      try {
        ws.ping();
        const deadline = setTimeout(() => {
          ws.__clickBridgePongTimer = null;
          terminateWebSocket(ws);
        }, pongTimeoutMs);
        deadline.unref?.();
        ws.__clickBridgePongTimer = deadline;
      } catch {
        terminateWebSocket(ws);
      }
    }
  }, pingIntervalMs);
  pingTimer.unref?.();

  return {
    wss,
    async close() {
      clearInterval(pingTimer);
      httpServer.off('upgrade', onUpgrade);
      for (const ws of wss.clients) {
        if (ws.__clickBridgePongTimer) clearTimeout(ws.__clickBridgePongTimer);
        terminateWebSocket(ws);
      }
      await new Promise((resolve) => wss.close(resolve));
    },
  };
}

export function createServer({
  phoneToken,
  macToken,
  clickBridgeDomain,
  publicDir = DEFAULT_PUBLIC_DIR,
  log = console,
  authTimeoutMs = AUTH_TIMEOUT_MS,
  pingIntervalMs = SERVER_PING_INTERVAL_MS,
  pongTimeoutMs = SERVER_PONG_TIMEOUT_MS,
  terminalCloseDeadlineMs = TERMINAL_CLOSE_DEADLINE_MS,
  maxTotalWebSocketConnections = MAX_TOTAL_WEBSOCKET_CONNECTIONS,
  maxUnauthenticatedWebSocketConnections = MAX_UNAUTHENTICATED_WEBSOCKET_CONNECTIONS,
  performWebSocketUpgrade,
  parseClient = parseClientMessage,
  encode = encodeMessage,
  stateOptions = {},
  stateFactory = (options) => new RelayState(options),
} = {}) {
  if (!isValidToken(phoneToken)) {
    throw new Error('PHONE_TOKEN must be 64 lowercase hex characters');
  }
  if (!isValidToken(macToken)) {
    throw new Error('MAC_TOKEN must be 64 lowercase hex characters');
  }
  if (constantTimeEquals(phoneToken, macToken)) {
    throw new Error('PHONE_TOKEN and MAC_TOKEN must differ');
  }
  if (!isValidHostname(clickBridgeDomain)) {
    throw new Error('CLICK_BRIDGE_DOMAIN must be a bare valid hostname');
  }

  const connections = new Map();
  const emit = (connection, event) => {
    const ws = connections.get(connection);
    if (!ws) return false;
    if (event.kind === 'close') {
      closeWithDeadline(ws, event.code, event.reason, terminalCloseDeadlineMs);
      return true;
    }
    if (event.kind === 'message' && ws.readyState === ws.OPEN) {
      ws.send(encode(event.message));
      return true;
    }
    return false;
  };
  const redactedLog = (event, detail = {}) => {
    log.info?.(JSON.stringify({ event, ...detail }));
  };
  const state = stateFactory({ ...stateOptions, emit, log: redactedLog });
  const httpServer = http.createServer(createHttpHandler({ publicDir, clickBridgeDomain }));
  httpServer.on('connection', (socket) => socket.setNoDelay?.(true));
  const attachment = attachWebSocketServer({
    httpServer,
    state,
    connections,
    phoneToken,
    macToken,
    log,
    parseClient,
    encode,
    authTimeoutMs,
    pingIntervalMs,
    pongTimeoutMs,
    terminalCloseDeadlineMs,
    maxTotalWebSocketConnections,
    maxUnauthenticatedWebSocketConnections,
    performWebSocketUpgrade,
  });

  return {
    httpServer,
    wss: attachment.wss,
    state,
    listen: (port, host) => new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      httpServer.once('error', onError);
      httpServer.listen(port, host, () => {
        httpServer.off('error', onError);
        resolve();
      });
    }),
    async close() {
      state.dispose?.();
      await attachment.close();
      if (httpServer.listening) {
        await new Promise((resolve) => httpServer.close(resolve));
      }
    },
  };
}

const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const port = Number(process.env.PORT ?? 8080);
  const host = process.env.HOST ?? '0.0.0.0';
  let server;
  try {
    server = createServer({
      phoneToken: process.env.PHONE_TOKEN,
      macToken: process.env.MAC_TOKEN,
      clickBridgeDomain: process.env.CLICK_BRIDGE_DOMAIN,
    });
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('PORT must be an integer from 1 through 65535');
    }
    await server.listen(port, host);
    console.log(JSON.stringify({ event: 'listening', port, host }));
  } catch (error) {
    console.error(`startup refused: ${error.message}`);
    process.exit(1);
  }

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, async () => {
      await server.close();
      process.exit(0);
    });
  }
}
