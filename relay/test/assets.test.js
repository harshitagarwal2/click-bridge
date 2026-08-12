// Guards the CSP contract at the layer that causes the breakage.
//
// The relay emits `script-src 'self'; style-src 'self'` and Caddy passes it
// through unchanged. Local development also serves that header, so anything
// inline fails here rather than four tasks later in production.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CONTENT_SECURITY_POLICY } from '../src/csp.js';
import { createHttpHandler } from '../src/server.js';

const PUBLIC = join(dirname(fileURLToPath(import.meta.url)), '../public');
const html = readFileSync(join(PUBLIC, 'index.html'), 'utf8');
const manifest = JSON.parse(readFileSync(join(PUBLIC, 'manifest.webmanifest'), 'utf8'));

test('primary control states the three-click physical outcome', () => {
  assert.match(html, />3 CLICKS<\/button>/);
  assert.match(html, /Three ordinary clicks at the Mac's current cursor/);
  assert.equal(
    manifest.description,
    "Post three ordinary left clicks at the Mac's current cursor.",
  );
});

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

test('the PWA pairing composition modules are served as JavaScript', async () => {
  for (const name of [
    'app-composition.js', 'pairing-link.js', 'pairing-controller.js', 'pairing-ui.js',
  ]) {
    const response = await requestStatic(`/${name}`);
    assert.equal(response.status, 200, `${name} must be available to app.js imports`);
  }
});

async function requestStatic(pathname) {
  return new Promise((resolve) => {
    const response = {
      status: null,
      body: '',
      writeHead(status) { this.status = status; },
      end(body = '') { this.body = body.toString(); resolve(this); },
    };
    createHttpHandler({ publicDir: PUBLIC, clickBridgeDomain: 'localhost' })(
      { method: 'GET', url: pathname }, response,
    );
  });
}

async function requestFrom(publicDir, { method, pathname, pairingEnabled }) {
  return new Promise((resolve) => {
    const response = {
      status: null,
      headers: null,
      body: '',
      writeHead(status, headers) { this.status = status; this.headers = headers; },
      end(body = '') { this.body = body.toString(); resolve(this); },
    };
    createHttpHandler({ publicDir, clickBridgeDomain: 'localhost', pairingEnabled })(
      { method, url: pathname }, response,
    );
  });
}

test('malformed pairing capability markers fail closed for every index route and method', async () => {
  const malformed = new Map([
    ['missing', '<!doctype html><title>Click Bridge</title>'],
    ['duplicate disabled', [
      '<meta name="clickbridge-pairing" content="off">',
      '<meta name="clickbridge-pairing" content="off">',
    ].join('\n')],
    ['pre-enabled only', '<meta name="clickbridge-pairing" content="on">'],
    ['mixed disabled and enabled', [
      '<meta name="clickbridge-pairing" content="off">',
      '<meta name="clickbridge-pairing" content="on">',
    ].join('\n')],
  ]);

  for (const [name, index] of malformed) {
    const publicDir = await mkdtemp(join(tmpdir(), 'click-bridge-index-'));
    try {
      await writeFile(join(publicDir, 'index.html'), index);
      for (const pairingEnabled of [false, true]) {
        const paths = pairingEnabled ? ['/', '/pair'] : ['/'];
        for (const pathname of paths) {
          for (const method of ['GET', 'HEAD']) {
            const response = await requestFrom(publicDir, { method, pathname, pairingEnabled });
            assert.equal(response.status, 500, `${name}: ${method} ${pathname}`);
            assert.equal(response.body, '', `${name}: malformed HTML must never be served`);
          }
        }
      }
    } finally {
      await rm(publicDir, { recursive: true, force: true });
    }
  }
});

test('legacy protocol-lite asset is unreferenced and unavailable over HTTP', async () => {
  assert.equal(existsSync(join(PUBLIC, 'protocol-lite.js')), false, 'duplicate parser shim must not ship');
  for (const name of ['app.js', 'state.js', 'transport-controller.js', 'transport-coordinator.js']) {
    assert.equal(
      readFileSync(join(PUBLIC, name), 'utf8').includes('protocol-lite'),
      false,
      `${name} must use wire-protocol.js directly`,
    );
  }
  const response = await requestStatic('/protocol-lite.js');
  assert.equal(response.status, 404);
  assert.equal(response.body, 'not found');
});

test('removed browser modules stay unavailable with the ordinary 404 response', async () => {
  for (const name of ['constants-lite.js', 'direct-transport.js']) {
    assert.equal(existsSync(join(PUBLIC, name)), false, `${name} must not ship`);
    const response = await requestStatic(`/${name}`);
    assert.equal(response.status, 404);
    assert.equal(response.body, 'not found');
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
  assert.match(html, /rel="apple-touch-icon" href="\/icons\/apple-touch-icon-180\.png"/);
});

test('platform installation guidance does not depend on beforeinstallprompt', () => {
  assert.match(html, /Share.*Add to Home Screen/s);
  assert.match(html, /Android.*Install\/Add to Home Screen/s);
  assert.equal(/beforeinstallprompt/.test(readFileSync(join(PUBLIC, 'app.js'), 'utf8')), false);
});

test('clock failure and wake-lock support have actionable status controls', () => {
  assert.match(html, /id="clock-retry"/);
  assert.match(html, /id="wake-status"/);
});

test('pairing is a first-class accessible flow while legacy credentials stay Advanced', () => {
  assert.match(html, /id="pairing-panel"[\s\S]*aria-labelledby="pairing-title"/);
  assert.match(html, /id="pairing-message"[\s\S]*aria-live="polite"/);
  assert.match(html, /id="pairing-alert"[\s\S]*role="alert"/);
  assert.match(html, /id="pairing-code"[\s\S]*aria-label="Confirmation code"/);
  assert.match(html, /id="manual-token-guidance"/);
  assert.match(html, /<details[^>]*id="manual-token-settings"[\s\S]*<summary>Set up phone token<\/summary>[\s\S]*id="token-input"/);
  assert.match(html, /id="pair-again"[^>]*>Pair Again<\/button>/);
  assert.match(html, /id="pairing-forget"[^>]*>Forget this browser<\/button>/);
  assert.equal(/pairing-reference|pairing-url|reference-input/i.test(html), false);
});

test('default-off composition keeps manual token recovery first-class without pairing copy', async () => {
  const meta = html.match(/<meta name="clickbridge-pairing" content="([^"]+)">/)?.[1];
  assert.equal(meta, 'off');
  const { composeCredentialAccess } = await import('../public/app-composition.js');
  const { initialState, reduce, view } = await import('../public/state.js');
  const app = readFileSync(join(PUBLIC, 'app.js'), 'utf8');
  assert.match(app, /function render\(\)[\s\S]*composeCredentialAccess\(\{/,
    'the state-driven production render must own this composition');
  const elements = {
    pairingPanel: { hidden: false },
    pairingGuidance: { hidden: false },
    manualSettings: { open: false },
    manualGuidance: { hidden: true, textContent: '' },
  };

  composeCredentialAccess({ pairingEnabled: meta === 'on', phase: view(initialState()).phase, elements });
  assert.equal(elements.pairingPanel.hidden, true);
  assert.equal(elements.pairingGuidance.hidden, true);
  assert.equal(elements.manualSettings.open, true);
  assert.match(elements.manualGuidance.textContent, /phone token/i);

  let takenOver = reduce(initialState(), { type: 'token.set', token: 'a'.repeat(64) });
  takenOver = reduce(takenOver, { type: 'transport.taken_over' });
  composeCredentialAccess({ pairingEnabled: false, phase: view(takenOver).phase, elements });
  assert.match(elements.manualGuidance.textContent, /replace/i);
});

test('a new invitation owns startup instead of pending recovery retiring its claimant', async () => {
  const { composePairingStartup } = await import('../public/app-composition.js');
  const events = [];

  const plan = composePairingStartup({
    pairingEnabled: true,
    hasPending: true,
    invitation: { pairingVersion: 1, reference: 'A'.repeat(43) },
    startInvitation: () => events.push('invitation'),
  });

  assert.deepEqual(events, ['invitation']);
  assert.equal(plan.recoveryNeeded, false);
});

test('pairing controls meet the minimum touch target and reduced-motion contract', () => {
  const css = readFileSync(join(PUBLIC, 'styles.css'), 'utf8');
  assert.match(css, /\.pairing-action[\s\S]*min-height\s*:\s*44px/);
  assert.match(css, /@media \(prefers-reduced-motion:reduce\)[\s\S]*\.pairing-mark/);
});

test('startup pending recovery enters a cancelable UI phase before authentication starts', () => {
  const app = readFileSync(join(PUBLIC, 'app.js'), 'utf8');
  assert.match(
    app,
    /startRecovery: \(\) => pairingUI\.startRecovery\(\),\s*recover: \(\) => pairingController\.recover\(\)/,
  );
});

test('click target preserves the low-latency accessible dimensions', () => {
  const css = readFileSync(join(PUBLIC, 'styles.css'), 'utf8');
  assert.match(css, /body\s*\{[\s\S]*touch-action\s*:\s*manipulation/);
  assert.match(css, /#click-button\s*\{[\s\S]*min-height\s*:\s*45vh/);
  assert.match(css, /#click-button\s*\{[\s\S]*width\s*:\s*min\(88vw\s*,\s*32rem\)/);
});

test('install icons have their declared PNG dimensions', () => {
  for (const [name, size] of [
    ['icon-192.png', 192], ['icon-512.png', 512], ['apple-touch-icon-180.png', 180],
  ]) {
    const bytes = readFileSync(join(PUBLIC, 'icons', name));
    assert.equal(bytes.toString('ascii', 1, 4), 'PNG');
    assert.equal(bytes.readUInt32BE(16), size, `${name} width`);
    assert.equal(bytes.readUInt32BE(20), size, `${name} height`);
  }
});

test('no service worker is registered in Milestone 1', () => {
  assert.equal(/serviceWorker/.test(readFileSync(join(PUBLIC, 'app.js'), 'utf8')), false);
});

test('the viewport allows zoom', () => {
  const vp = html.match(/name="viewport"\s+content="([^"]+)"/)[1];
  assert.equal(/user-scalable\s*=\s*no/.test(vp), false, 'zoom must not be disabled');
  assert.match(vp, /viewport-fit=cover/);
});
