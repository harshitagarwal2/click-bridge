export function deriveRelayWebSocketUrl(location) {
  const match = /^\/pair(?:\/web)?\/([A-Za-z0-9_-]{22})$/.exec(location.pathname);
  const suffix = match ? `/ws/${match[1]}` : '/ws';
  if (location.protocol === 'https:') return `wss://${location.host}${suffix}`;
  if (location.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(location.hostname)) {
    return `ws://${location.host}${suffix}`;
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
