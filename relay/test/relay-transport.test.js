import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayTransport, deriveRelayWebSocketUrl } from '../public/relay-transport.js';

test('OCI relay URL uses WSS on a secure public origin', () => {
  assert.equal(deriveRelayWebSocketUrl({ protocol: 'https:', host: 'click.example', hostname: 'click.example' }),
    'wss://click.example/ws');
});

test('plain WS is limited to the desktop simulator loopback origins', () => {
  assert.equal(deriveRelayWebSocketUrl({ protocol: 'http:', host: 'localhost:8080', hostname: 'localhost' }),
    'ws://localhost:8080/ws');
  assert.equal(deriveRelayWebSocketUrl({ protocol: 'http:', host: '127.0.0.1:8080', hostname: '127.0.0.1' }),
    'ws://127.0.0.1:8080/ws');
  assert.throws(
    () => deriveRelayWebSocketUrl({ protocol: 'http:', host: '10.0.0.5:8080', hostname: '10.0.0.5' }),
    /secure origin/,
  );
});

test('relay transport is the OCI controller composition boundary', () => {
  const transport = createRelayTransport({
    location: { protocol: 'https:', host: 'click.example', hostname: 'click.example' },
    token: () => 'a'.repeat(64),
    createSocket: () => ({ close() {} }),
  });
  assert.equal(transport.name, 'oci');
  assert.equal(transport.state, 'idle');
});
