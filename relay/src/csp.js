// The canonical Content-Security-Policy.
//
// Emitted by the relay's own static handler so localhost and production
// enforce the same rules; Caddy passes this header through unchanged rather
// than defining a second copy that could drift.
//
// Kept dependency-free so tests can import it without `ws`.

export const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  // ws:/wss: covers the local http dev origin, the production origin, and a
  // Milestone 2 Tailscale listener on *.ts.net.
  "connect-src 'self' ws: wss:",
  "img-src 'self' data:",
  "style-src 'self'",
  "script-src 'self'",
  "manifest-src 'self'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'none'",
].join('; ');

export const SECURITY_HEADERS = Object.freeze({
  'Content-Security-Policy': CONTENT_SECURITY_POLICY,
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
});
