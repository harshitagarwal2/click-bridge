export function deriveRelayWebSocketUrl(location) {
  if (location.protocol === 'https:') return `wss://${location.host}/ws`;
  if (location.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(location.hostname)) {
    return `ws://${location.host}/ws`;
  }
  throw new Error('A secure origin is required');
}

export function createRelayTransport({ location, ...options }) {
  return new TransportController({
    ...options,
    name: 'oci',
    role: 'phone',
    url: () => deriveRelayWebSocketUrl(location),
  });
}
import { TransportController } from './transport-controller.js';
