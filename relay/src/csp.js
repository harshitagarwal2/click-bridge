export function createContentSecurityPolicy(clickBridgeDomain) {
  return [
    "default-src 'self'",
    `connect-src 'self' wss://${clickBridgeDomain} wss://*.ts.net ws://127.0.0.1:* ws://localhost:*`,
    "img-src 'self'",
    "style-src 'self'",
    "script-src 'self'",
    "manifest-src 'self'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "form-action 'none'",
  ].join('; ');
}

export function createSecurityHeaders(clickBridgeDomain) {
  return Object.freeze({
    'Content-Security-Policy': createContentSecurityPolicy(clickBridgeDomain),
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
}

// Kept for environment-neutral asset-policy tests. The production handler
// always creates the canonical value from validated CLICK_BRIDGE_DOMAIN.
export const CONTENT_SECURITY_POLICY = createContentSecurityPolicy('localhost');
export const SECURITY_HEADERS = createSecurityHeaders('localhost');
