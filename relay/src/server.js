import * as crypto from 'node:crypto';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import * as fs from 'node:fs/promises';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { WebSocketServer } from 'ws';

import {
  AUTH_TIMEOUT_MS,
  AUTHENTICATION_REJECTED_CLOSE_CODE,
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
import { createPhoneAuthStore } from './auth-store.js';
import { PairingCoordinator } from './pairing.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PUBLIC_DIR = join(HERE, '..', 'public');
const DEFAULT_PHONE_AUTH_RECORD = '/var/lib/click-bridge/auth/phone-auth.json';

function parsePairingEnabled(value = '0') {
  if (value !== '0' && value !== '1') {
    throw new Error('PAIRING_ENABLED must be exactly 0 or 1');
  }
  return value === '1';
}

function isValidAppleTeamId(value) {
  return typeof value === 'string' && /^[A-Z0-9]{10}$/.test(value);
}

function validWebSocketOrigin(req, clickBridgeDomain) {
  const headers = req.headers ?? Object.create(null);
  const origin = headers.origin;
  if (origin === undefined) return true;
  if (typeof origin !== 'string') return false;
  if (origin === `https://${clickBridgeDomain}`) return true;
  try {
    const parsed = new URL(origin);
    return parsed.protocol === 'http:'
      && (parsed.hostname === '127.0.0.1' || parsed.hostname === 'localhost')
      && typeof headers.host === 'string'
      && parsed.host === headers.host
      && parsed.username === '' && parsed.password === ''
      && origin === parsed.origin;
  } catch {
    return false;
  }
}

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
  if (!ws) return;
  try {
    ws.__clickBridgeTerminal = true;
  } catch {
    // Continue with best-effort disposal even if the candidate rejects bookkeeping.
  }
  let terminate;
  try {
    terminate = ws.terminate;
  } catch {
    // Fall through to close when property access itself is hostile.
  }
  if (typeof terminate === 'function') {
    try {
      terminate.call(ws);
    } catch {
      // Admission is already revoked; disposal is best-effort.
    }
    return;
  }
  try {
    const close = ws.close;
    if (typeof close === 'function') close.call(ws);
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
  ['/app-composition.js', ['app-composition.js', 'text/javascript; charset=utf-8']],
  ['/state.js', ['state.js', 'text/javascript; charset=utf-8']],
  ['/wire-protocol.js', ['wire-protocol.js', 'text/javascript; charset=utf-8']],
  ['/runtime-constants.js', ['runtime-constants.js', 'text/javascript; charset=utf-8']],
  ['/runtime-scheduler.js', ['runtime-scheduler.js', 'text/javascript; charset=utf-8']],
  ['/transport-controller.js', ['transport-controller.js', 'text/javascript; charset=utf-8']],
  ['/relay-transport.js', ['relay-transport.js', 'text/javascript; charset=utf-8']],
  ['/transport-coordinator.js', ['transport-coordinator.js', 'text/javascript; charset=utf-8']],
  ['/clock-health-controller.js', ['clock-health-controller.js', 'text/javascript; charset=utf-8']],
  ['/phone-settings-store.js', ['phone-settings-store.js', 'text/javascript; charset=utf-8']],
  ['/credential-lifecycle-controller.js', ['credential-lifecycle-controller.js',
    'text/javascript; charset=utf-8']],
  ['/pairing-link.js', ['pairing-link.js', 'text/javascript; charset=utf-8']],
  ['/pairing-controller.js', ['pairing-controller.js', 'text/javascript; charset=utf-8']],
  ['/pairing-ui.js', ['pairing-ui.js', 'text/javascript; charset=utf-8']],
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

function captureCredentialDescriptor(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  let descriptor;
  try {
    descriptor = Object.getOwnPropertyDescriptor(value, 'credentialVersion');
  } catch {
    return null;
  }
  if (!descriptor || Object.hasOwn(descriptor, 'get') || Object.hasOwn(descriptor, 'set')) {
    return null;
  }
  const credentialVersion = descriptor.value;
  if (!Number.isSafeInteger(credentialVersion) || credentialVersion < 0) return null;
  return Object.freeze({ credentialVersion });
}

function writeResponse(res, status, headers, body = '') {
  res.writeHead(status, headers);
  res.end(body);
}

export function createHttpHandler({
  publicDir = DEFAULT_PUBLIC_DIR,
  clickBridgeDomain,
  pairingEnabled = false,
  appleTeamId,
}) {
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
    if (pairingEnabled && (pathname === '/pair' || pathname === '/pair/web')) {
      try {
        const body = await readFile(join(publicDir, 'pair.html'));
        writeResponse(res, 200, {
          ...securityHeaders,
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Length': body.byteLength,
          'Cache-Control': 'no-store',
          'Referrer-Policy': 'no-referrer',
        }, req.method === 'HEAD' ? '' : body);
      } catch {
        writeResponse(res, 500, securityHeaders);
      }
      return;
    }
    if (pairingEnabled && pathname === '/.well-known/apple-app-site-association') {
      const body = Buffer.from(JSON.stringify({
        applinks: {
          details: [{
            appIDs: [`${appleTeamId}.com.clickbridge.phone`],
            components: [{ '/': '/pair/web', exclude: true }, { '/': '/pair' }],
          }],
        },
      }));
      writeResponse(res, 200, {
        ...securityHeaders,
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': body.byteLength,
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
      }, req.method === 'HEAD' ? '' : body);
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
  authorizedPhones = new Set(),
  phoneToken,
  macToken,
  authStore,
  pairing,
  pairingEnabled = false,
  clickBridgeDomain,
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
  const credentialStore = authStore ?? Object.freeze({
    authenticateCredential: (credential) => constantTimeEquals(credential, phoneToken)
      ? Object.freeze({ credentialVersion: 0 }) : null,
  });
  const pairingCoordinator = pairing ?? Object.freeze({
    acknowledge: async () => 'unsupported',
    cancelByClaimant: () => 'unsupported',
    claim: () => 'unsupported',
    macConnected: () => 'unsupported',
    macDisconnected: () => 'unsupported',
    disconnectClaimant: () => 'unsupported',
    requestStatus: () => 'unsupported',
    create: () => 'unsupported',
    cancelByMac: () => 'unsupported',
    approve: () => 'unsupported',
    deny: () => 'unsupported',
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
  const admissionController = createAdmissionController(
    maxTotalWebSocketConnections,
    maxUnauthenticatedWebSocketConnections,
  );
  const upgrade = performWebSocketUpgrade
    ?? ((req, socket, head, done) => wss.handleUpgrade(req, socket, head, done));
  let nextConnectionId = 0;
  let closing = false;
  const pendingAttempts = new Set();

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
    if (!validWebSocketOrigin(req, clickBridgeDomain)) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const admission = admissionController.reserve();
    if (!admission) {
      rejectUpgradeForCapacity(socket);
      return;
    }
    socket.setNoDelay?.(true);
    let phase = 'invoking';
    let acceptedWebSocket = null;
    let candidateActive = false;
    const removeRawGuards = () => {
      let off;
      try {
        off = socket.off;
      } catch {
        return;
      }
      if (typeof off !== 'function') return;
      try { off.call(socket, 'close', onRawTerminal); } catch {}
      try { off.call(socket, 'error', onRawTerminal); } catch {}
    };
    const removeCandidateGuards = (ws = acceptedWebSocket) => {
      let off;
      try {
        off = ws?.off;
      } catch {
        return;
      }
      if (typeof off !== 'function') return;
      try { off.call(ws, 'close', onCandidateTerminal); } catch {}
      try { off.call(ws, 'error', onCandidateTerminal); } catch {}
    };
    const destroyCandidate = (ws) => {
      try { wss.clients.delete(ws); } catch {}
      destroyRejectedWebSocket(ws);
    };
    const failAttempt = (code = null, candidate = acceptedWebSocket, rollbackCommitted = false) => {
      if (phase === 'failed' || (phase === 'committed' && !rollbackCommitted)) return;
      phase = 'failed';
      pendingAttempts.delete(attempt);
      removeRawGuards();
      candidateActive = false;
      try { admission.releaseAll(); } catch {}
      try {
        const destroy = socket.destroy;
        if (typeof destroy === 'function') destroy.call(socket);
      } catch {}
      removeCandidateGuards(candidate);
      destroyCandidate(candidate);
      if (code) {
        try {
          log.info?.(JSON.stringify({ event: 'upgrade_internal_error', code }));
        } catch {
          // Diagnostics cannot compromise admission cleanup.
        }
      }
    };
    function onRawTerminal() {
      if (phase !== 'committed') failAttempt();
    }
    function onCandidateTerminal() {
      candidateActive = false;
      if (phase !== 'committed') failAttempt();
    }
    const attempt = Object.freeze({ abort: failAttempt });
    pendingAttempts.add(attempt);
    socket.once('close', onRawTerminal);
    socket.once('error', onRawTerminal);

    const activateAcceptedWebSocket = () => {
      const ws = acceptedWebSocket;
      if (phase !== 'returned' || !ws) return;
      if (closing || socket.destroyed || !candidateActive
          || ws.__clickBridgeTerminal || ws.readyState !== ws.OPEN) {
        failAttempt();
        return;
      }
      phase = 'committing';
      if (!admission.acceptCallback()) return failAttempt();
      pendingAttempts.delete(attempt);
      removeRawGuards();
      removeCandidateGuards(ws);
      candidateActive = false;
      phase = 'committed';
      try {
        ws.__clickBridgeAdmission = admission;
        wss.emit('connection', ws, req);
      } catch {
        failAttempt('connection_callback_failure', ws, true);
      }
    };
    try {
      upgrade(req, socket, head, (ws) => {
        try {
          if (acceptedWebSocket) {
            if (ws !== acceptedWebSocket) destroyCandidate(ws);
            return;
          }
          if (phase === 'failed' || phase === 'committed') {
            destroyCandidate(ws);
            return;
          }
          if (typeof ws?.once !== 'function' || typeof ws?.off !== 'function') {
            acceptedWebSocket = ws;
            failAttempt('connection_callback_failure');
            return;
          }
          acceptedWebSocket = ws;
          candidateActive = ws.readyState === ws.OPEN && !ws.__clickBridgeTerminal;
          ws.once('close', onCandidateTerminal);
          ws.once('error', onCandidateTerminal);
          activateAcceptedWebSocket();
        } catch {
          failAttempt('connection_callback_failure', ws);
        }
      });
      if (phase === 'failed') return;
      phase = 'returned';
      activateAcceptedWebSocket();
    } catch {
      failAttempt('upgrade_throw');
    }
  };
  httpServer.on('upgrade', onUpgrade);

  wss.on('connection', (ws) => {
    const admission = ws.__clickBridgeAdmission;
    let role = null;
    let connection = null;
    let generation = 0;
    let phase = 'unauthenticated';
    let operationGeneration = 0;
    const pendingFrames = [];
    let processingFrames = false;
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

    const failProtocol = (event, error, closeCode = 4003, reason = 'bad message') => {
      log.info?.(JSON.stringify({
        event,
        code: error instanceof ProtocolError ? error.code : 'parser_failure',
      }));
      closeWithDeadline(
        ws, error instanceof ProtocolError ? closeCode : 1011,
        error instanceof ProtocolError ? reason : 'internal error',
        terminalCloseDeadlineMs, scheduleTerminalClose,
      );
    };

    const handleMessage = (raw, isBinary, ownedOperation) => {
      if (ws.__clickBridgeTerminal) return;
      if (ownedOperation !== operationGeneration) return;

      if (phase === 'claimant') {
        let message;
        try {
          message = parseClient(raw, 'pairing.claimed');
        } catch (error) {
          failProtocol('claim_message_rejected', error, 4003, 'bad pairing message');
          return;
        }
        if (message.type === 'pair.credential.ack') {
          const claimantConnection = connection;
          const claimantGeneration = generation;
          const claimantClaimId = message.claimId;
          return Promise.resolve(
            pairingCoordinator.acknowledge(connection, generation, message),
          ).then(() => {
            if (ownedOperation !== operationGeneration || ws.__clickBridgeTerminal) return;
            if (phase !== 'claimant' || connection !== claimantConnection
                || generation !== claimantGeneration
                || connection.claimId !== claimantClaimId) return;
          });
        } else {
          pairingCoordinator.cancelByClaimant(connection, generation, message);
        }
        return;
      }

      if (role === null) {
        let message;
        try {
          message = parseClient(raw, pairingEnabled ? 'pairing.initial' : null);
        } catch (initialError) {
          failProtocol('auth_rejected', initialError, 4003, 'bad initial message');
          return;
        }
        if (message.type === 'pair.claim') {
            if (ownedOperation !== operationGeneration || ws.__clickBridgeTerminal) return;
            generation += 1;
            connection = Object.freeze({
              id: ++nextConnectionId,
              role: 'claimant',
              generation,
              claimId: message.claimId,
            });
            connections.set(connection, ws);
            phase = 'claimant';
            clearTimeout(authTimer);
            admission.releaseUnauthenticated();
            pairingCoordinator.claim(connection, generation, message);
            return;
        }

        let descriptor = null;
        if (message.role === 'phone') {
          try {
            const candidate = credentialStore.authenticateCredential(message.token);
            if (candidate !== null) descriptor = captureCredentialDescriptor(candidate);
            if (candidate !== null && descriptor === null) {
              throw new TypeError('invalid credential descriptor');
            }
          } catch {
            log.info?.(JSON.stringify({ event: 'auth_internal_error', code: 'verifier_failure' }));
            closeWithDeadline(
              ws, 1011, 'internal error', terminalCloseDeadlineMs, scheduleTerminalClose,
            );
            return;
          }
        } else if (constantTimeEquals(message.token, macToken)) {
          descriptor = Object.freeze({ credentialVersion: null });
        }
        if (!descriptor) {
          log.info?.(JSON.stringify({
            event: 'auth_rejected', code: 'bad_token', role: message.role,
          }));
          closeWithDeadline(
            ws, AUTHENTICATION_REJECTED_CLOSE_CODE, 'bad token',
            terminalCloseDeadlineMs, scheduleTerminalClose,
          );
          return;
        }

        if (ownedOperation !== operationGeneration || ws.__clickBridgeTerminal) return;
        role = message.role;
        phase = role;
        clearTimeout(authTimer);
        admission.releaseUnauthenticated();
        generation += 1;
        connection = Object.freeze({
          id: ++nextConnectionId,
          role,
          generation,
          credentialVersion: descriptor.credentialVersion,
        });
        connections.set(connection, ws);
        if (role === 'phone') authorizedPhones.add(connection);
        state.replaceRole(role, connection);
        if (role === 'mac') pairingCoordinator.macConnected(connection, generation);
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
      if (role === 'phone') {
        state.handlePhoneMessage(connection, message);
      } else if (message.type.startsWith('pair.')) {
        if (!pairingEnabled) {
          const failure = {
            type: 'pair.failed', v: PROTOCOL_VERSION,
            requestId: message.requestId, reason: 'unsupported',
          };
          if (Object.hasOwn(message, 'claimId')) failure.claimId = message.claimId;
          ws.send(encode(failure));
          return;
        }
        if (message.type === 'pair.status.request') {
          pairingCoordinator.requestStatus(connection, generation, message);
        } else if (message.type === 'pair.create') {
          pairingCoordinator.create(connection, generation, message);
        } else if (message.type === 'pair.cancel') {
          pairingCoordinator.cancelByMac(connection, generation, message);
        } else if (message.type === 'pair.approve') {
          pairingCoordinator.approve(connection, generation, message);
        } else {
          pairingCoordinator.deny(connection, generation, message);
        }
      } else {
        state.handleMacMessage(connection, message);
      }
    };

    const drainFrames = () => {
      if (processingFrames) return;
      processingFrames = true;
      while (pendingFrames.length > 0) {
        if (ws.__clickBridgeTerminal) {
          pendingFrames.length = 0;
          processingFrames = false;
          return;
        }
        const frame = pendingFrames.shift();
        let result;
        try {
          result = handleMessage(frame.raw, frame.isBinary, frame.ownedOperation);
        } catch {
          if (frame.ownedOperation === operationGeneration && !ws.__clickBridgeTerminal) {
            log.info?.(JSON.stringify({
              event: 'message_internal_error', code: 'handler_failure',
            }));
            closeWithDeadline(
              ws, 1011, 'internal error', terminalCloseDeadlineMs, scheduleTerminalClose,
            );
          }
          continue;
        }
        if (result && typeof result.then === 'function') {
          result.catch(() => {
            if (frame.ownedOperation !== operationGeneration || ws.__clickBridgeTerminal) return;
            log.info?.(JSON.stringify({
              event: 'message_internal_error', code: 'handler_failure',
            }));
            closeWithDeadline(
              ws, 1011, 'internal error', terminalCloseDeadlineMs, scheduleTerminalClose,
            );
          }).finally(() => {
            processingFrames = false;
            drainFrames();
          });
          return;
        }
      }
      processingFrames = false;
    };

    ws.on('message', (data, isBinary) => {
      if (ws.__clickBridgeTerminal) return;
      const ownedOperation = operationGeneration;
      let raw;
      try {
        raw = isBinary ? data : data.toString('utf8');
      } catch (error) {
        failProtocol('message_internal_error', error, 4003, 'bad message');
        return;
      }
      pendingFrames.push({ raw, isBinary, ownedOperation });
      drainFrames();
    });

    ws.on('close', () => {
      operationGeneration += 1;
      pendingFrames.length = 0;
      admission.releaseAll();
      clearTimeout(authTimer);
      if (ws.__clickBridgeCloseTimer) clearTimeout(ws.__clickBridgeCloseTimer);
      ws.__clickBridgeCloseTimer = null;
      if (ws.__clickBridgePongTimer) clearTimeout(ws.__clickBridgePongTimer);
      ws.__clickBridgePongTimer = null;
      if (connection) {
        connections.delete(connection);
        authorizedPhones.delete(connection);
        if (phase === 'claimant') pairingCoordinator.disconnectClaimant(connection, generation);
        else {
          state.detachIfCurrent(role, connection);
          if (role === 'mac') pairingCoordinator.macDisconnected(connection, generation);
        }
        log.info?.(JSON.stringify({ event: 'disconnected', role }));
      }
    });
    ws.on('error', (error) => {
      operationGeneration += 1;
      pendingFrames.length = 0;
      ws.__clickBridgeTerminal = true;
      admission.releaseAll();
      if (connection) authorizedPhones.delete(connection);
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
      closing = true;
      clearInterval(pingTimer);
      httpServer.off('upgrade', onUpgrade);
      for (const attempt of [...pendingAttempts]) attempt.abort();
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
  pairingEnabled = '0',
  appleTeamId,
  phoneAuthRecord,
  authStore,
  pairingOptions = {},
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
  const pairingIsEnabled = parsePairingEnabled(pairingEnabled);
  if (pairingIsEnabled && !isValidAppleTeamId(appleTeamId)) {
    throw new Error('APPLE_TEAM_ID must be 10 uppercase alphanumeric characters when pairing is enabled');
  }
  if (pairingIsEnabled && !authStore && !phoneAuthRecord) {
    throw new Error('PHONE_AUTH_RECORD or authStore is required when pairing is enabled');
  }

  let redactedLog;
  const credentialStore = authStore ?? (pairingIsEnabled && phoneAuthRecord
    ? createPhoneAuthStore({
      recordPath: phoneAuthRecord,
      initialPhoneToken: phoneToken,
      fs,
      crypto,
      log: () => redactedLog?.('phone_auth_store_failure'),
    })
    : Object.freeze({
      async initialize() {},
      snapshot: () => Object.freeze({ activePhoneCredentialVersion: 0 }),
      authenticateCredential: (credential) => constantTimeEquals(credential, phoneToken)
        ? Object.freeze({ credentialVersion: 0 }) : null,
      async activate() { throw new Error('durable auth store unavailable'); },
    }));

  const connections = new Map();
  const authorizedPhones = new Set();
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
  redactedLog = (event, detail = {}) => {
    log.info?.(JSON.stringify({ event, ...detail }));
  };
  let state;
  const deauthorizeOlderPhones = ({ credentialVersion, exclude }) => {
    const older = [];
    for (const connection of [...authorizedPhones]) {
      if (connection.role !== 'phone'
          || connection === exclude.connection
          || connection.credentialVersion >= credentialVersion) continue;
      authorizedPhones.delete(connection);
      state.detachIfCurrent('phone', connection);
      older.push({
        connection,
        generation: connection.generation,
        credentialVersion: connection.credentialVersion,
      });
    }
    return older;
  };
  const pairing = new PairingCoordinator({
    enabled: pairingIsEnabled,
    now: pairingOptions.now ?? (() => Date.now()),
    randomBytes: pairingOptions.randomBytes ?? randomBytes,
    randomInt: pairingOptions.randomInt ?? randomInt,
    scheduler: pairingOptions.scheduler ?? {
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: (timer) => clearTimeout(timer),
    },
    authStore: credentialStore,
    emit: (connection, message) => emit(connection, { kind: 'message', message }),
    close: (connection, code, reason) => emit(connection, { kind: 'close', code, reason }),
    deauthorizeOlderPhones,
    log: redactedLog,
  });
  state = stateFactory({
    ...stateOptions,
    emit,
    log: redactedLog,
    authorizePhone: (connection) => authorizedPhones.has(connection)
      && (!pairingIsEnabled
        || pairing.allowsPhoneCredentialVersion(connection.credentialVersion) === true),
  });
  const httpServer = http.createServer(createHttpHandler({
    publicDir,
    clickBridgeDomain,
    pairingEnabled: pairingIsEnabled,
    appleTeamId,
  }));
  httpServer.on('connection', (socket) => socket.setNoDelay?.(true));
  const attachment = attachWebSocketServer({
    httpServer,
    state,
    connections,
    authorizedPhones,
    phoneToken,
    macToken,
    authStore: credentialStore,
    pairing,
    pairingEnabled: pairingIsEnabled,
    clickBridgeDomain,
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
  let serverClosing = false;

  return {
    httpServer,
    wss: attachment.wss,
    state,
    listen: async (port, host) => {
      await credentialStore.initialize();
      if (serverClosing) throw new Error('server is closing');
      return new Promise((resolve, reject) => {
        const onError = (error) => reject(error);
        httpServer.once('error', onError);
        httpServer.listen(port, host, () => {
          httpServer.off('error', onError);
          resolve();
        });
      });
    },
    async close() {
      serverClosing = true;
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
      pairingEnabled: process.env.PAIRING_ENABLED ?? '0',
      appleTeamId: process.env.APPLE_TEAM_ID,
      phoneAuthRecord: process.env.PHONE_AUTH_RECORD ?? DEFAULT_PHONE_AUTH_RECORD,
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
