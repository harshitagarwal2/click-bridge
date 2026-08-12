// Guards the CSP contract at the layer that causes the breakage.
//
// The relay emits `script-src 'self'; style-src 'self'` and Caddy passes it
// through unchanged. Local development also serves that header, so anything
// inline fails here rather than four tasks later in production.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CONTENT_SECURITY_POLICY } from '../src/csp.js';

const PUBLIC = join(dirname(fileURLToPath(import.meta.url)), '../public');
const html = readFileSync(join(PUBLIC, 'index.html'), 'utf8');

test('index.html has no inline script', () => {
  // A <script> tag is fine only when it has a src and no body.
  const tags = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  assert.ok(tags.length > 0, 'expected at least one script tag');
  for (const [, attrs, body] of tags) {
    assert.match(attrs, /\ssrc=/, 'every script must be external');
    assert.equal(body.trim(), '', 'script tags must have an empty body');
  }
});

test('index.html has no inline style', () => {
  assert.equal(/<style\b/i.test(html), false, '<style> blocks are blocked by CSP');
  assert.equal(/\sstyle\s*=\s*["']/i.test(html), false, 'style="" attributes are blocked by CSP');
});

test('index.html has no inline event handlers', () => {
  const handlers = html.match(/\son[a-z]+\s*=\s*["']/gi) ?? [];
  assert.deepEqual(handlers, [], `inline handlers are blocked by CSP: ${handlers}`);
});

test('index.html has no javascript: URLs', () => {
  assert.equal(/javascript:/i.test(html), false);
});

test('the canonical CSP forbids inline script and style', () => {
  assert.match(CONTENT_SECURITY_POLICY, /script-src 'self'/);
  assert.match(CONTENT_SECURITY_POLICY, /style-src 'self'/);
  assert.equal(/unsafe-inline/.test(CONTENT_SECURITY_POLICY), false);
  assert.match(CONTENT_SECURITY_POLICY, /frame-ancestors 'none'/);
  assert.match(CONTENT_SECURITY_POLICY, /object-src 'none'/);
});

test('every asset referenced by index.html exists', () => {
  const refs = [
    ...[...html.matchAll(/(?:href|src)="(\/[^"]+)"/g)].map((m) => m[1]),
  ];
  assert.ok(refs.length >= 4, 'expected several asset references');
  for (const ref of refs) {
    assert.ok(existsSync(join(PUBLIC, ref)), `missing asset ${ref}`);
  }
});

test('the manifest is installable', () => {
  const m = JSON.parse(readFileSync(join(PUBLIC, 'manifest.webmanifest'), 'utf8'));
  assert.equal(m.display, 'standalone');
  assert.equal(m.start_url, '/');
  assert.equal(m.scope, '/');
  assert.ok(m.name && m.short_name, 'needs a name');
  assert.ok(m.theme_color && m.background_color);

  const sizes = m.icons.map((i) => i.sizes).sort();
  assert.deepEqual(sizes, ['192x192', '512x512']);
  for (const icon of m.icons) {
    assert.ok(existsSync(join(PUBLIC, icon.src)), `missing icon ${icon.src}`);
  }
});

test('an Apple touch icon is declared', () => {
  assert.match(html, /rel="apple-touch-icon"/);
});

test('no service worker is registered in Milestone 1', () => {
  assert.equal(/serviceWorker/.test(readFileSync(join(PUBLIC, 'app.js'), 'utf8')), false);
});

test('the viewport allows zoom', () => {
  const vp = html.match(/name="viewport"\s+content="([^"]+)"/)[1];
  assert.equal(/user-scalable\s*=\s*no/.test(vp), false, 'zoom must not be disabled');
  assert.match(vp, /viewport-fit=cover/);
});
