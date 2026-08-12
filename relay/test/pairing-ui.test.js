import test from 'node:test';
import assert from 'node:assert/strict';

import { createPairingUI } from '../public/pairing-ui.js';

const REFERENCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const LINK = `https://click.example/pair#v=1&r=${REFERENCE}`;

class FakeElement extends EventTarget {
  constructor() {
    super();
    this.hidden = false;
    this.disabled = false;
    this.textContent = '';
    this.value = '';
    this.open = false;
    this.attributes = new Map();
    this.focused = false;
  }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  removeAttribute(name) { this.attributes.delete(name); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  focus() { this.focused = true; }
}

function event(type, fields = {}) {
  const value = new Event(type, { cancelable: true });
  Object.assign(value, fields);
  return value;
}

function harness(overrides = {}) {
  const elements = {
    panel: new FakeElement(),
    remote: new FakeElement(),
    heading: new FakeElement(),
    message: new FakeElement(),
    alert: new FakeElement(),
    code: new FakeElement(),
    paste: new FakeElement(),
    cancel: new FakeElement(),
    pairedState: new FakeElement(),
    pairAgain: new FakeElement(),
    forget: new FakeElement(),
  };
  const lifecycleTarget = new EventTarget();
  const starts = [];
  let cancels = 0;
  let forgets = 0;
  let ui;
  ui = createPairingUI({
    elements,
    enabled: overrides.enabled ?? true,
    paired: overrides.paired ?? false,
    expectedHost: 'click.example',
    readClipboard: overrides.readClipboard ?? (async () => LINK),
    startPairing(reference) { starts.push(reference); },
    cancelPairing() { cancels += 1; overrides.cancelPairing?.(ui); },
    async forgetPairing() {
      forgets += 1;
      if (overrides.forgetPairing) return overrides.forgetPairing();
      return overrides.forgetResult ?? true;
    },
    lifecycleTarget,
  });
  return { ui, elements, lifecycleTarget, starts, cancels: () => cancels, forgets: () => forgets };
}

function renderedText(elements) {
  return Object.values(elements).map((element) => element.textContent).join(' ');
}

function deferred() {
  let resolve;
  const promise = new Promise((next) => { resolve = next; });
  return { promise, resolve };
}

test('disabled pairing composition stays absent and does not claim an invitation', () => {
  const h = harness({ enabled: false });
  h.ui.start({ pairingVersion: 1, reference: REFERENCE });

  assert.equal(h.elements.panel.hidden, true);
  assert.equal(h.starts.length, 0);
});

test('an invitation starts without putting its reference or URL in the DOM', () => {
  const h = harness();
  h.ui.start({ pairingVersion: 1, reference: REFERENCE });

  assert.deepEqual(h.starts, [REFERENCE]);
  assert.equal(h.elements.heading.textContent, 'Pair this browser');
  assert.equal(h.elements.message.textContent, 'Claiming the pairing link…');
  assert.equal(h.elements.heading.focused, true);
  assert.equal(renderedText(h.elements).includes(REFERENCE), false);
  assert.equal(renderedText(h.elements).includes(LINK), false);
});

test('paste fallback consumes clipboard data without placing the link in an input or label', () => {
  const h = harness();
  const pasteEvent = event('paste', { clipboardData: { getData: () => LINK } });
  h.elements.paste.dispatchEvent(pasteEvent);

  assert.equal(pasteEvent.defaultPrevented, true);
  assert.deepEqual(h.starts, [REFERENCE]);
  assert.equal(renderedText(h.elements).includes(REFERENCE), false);
  assert.equal(renderedText(h.elements).includes(LINK), false);
});

test('a clipboard read cannot start pairing after the page is hidden', async () => {
  const clipboard = deferred();
  const h = harness({ readClipboard: () => clipboard.promise });

  h.elements.paste.dispatchEvent(event('click'));
  h.lifecycleTarget.dispatchEvent(event('pagehide'));
  clipboard.resolve(LINK);
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(h.starts, []);
});

test('a clipboard read cannot start pairing after the UI is destroyed', async () => {
  const clipboard = deferred();
  const h = harness({ readClipboard: () => clipboard.promise });

  h.elements.paste.dispatchEvent(event('click'));
  h.ui.destroy();
  clipboard.resolve(LINK);
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(h.starts, []);
});

test('the confirmation code is one labelled element and approval progress is polite', () => {
  const h = harness();
  h.ui.handleState({
    phase: 'awaiting_approval',
    confirmationCode: '482 193',
    expiresAtUnixMs: Date.now() + 60_000,
  });

  assert.equal(h.elements.heading.textContent, 'Check the code on your Mac');
  assert.equal(h.elements.message.textContent, 'If both screens show this code, approve on the Mac.');
  assert.equal(h.elements.message.getAttribute('aria-live'), 'polite');
  assert.equal(h.elements.code.hidden, false);
  assert.equal(h.elements.code.textContent, '482 193');
  assert.equal(h.elements.code.getAttribute('aria-label'), 'Confirmation code');
  assert.equal(h.elements.alert.hidden, true);
});

test('pairing phases give actionable safe messages without exposing internal reasons', () => {
  const h = harness();
  const cases = [
    [{ phase: 'activating' }, 'Activating this browser…', false],
    [{ phase: 'failed', reason: 'expired' }, 'This pairing link expired.', true],
    [{ phase: 'failed', reason: 'used' }, 'This pairing link was already used.', true],
    [{ phase: 'failed', reason: 'denied' }, 'Pairing was denied on the Mac.', true],
    [{ phase: 'failed', reason: 'disconnected' }, 'The network connection was interrupted.', true],
    [{ phase: 'replaced' }, 'This browser was replaced.', true],
  ];

  for (const [state, copy, blocking] of cases) {
    h.ui.handleState(state);
    const target = blocking ? h.elements.alert : h.elements.message;
    assert.equal(target.textContent, copy);
    assert.equal(target.hidden, false);
  }
});

test('active pairing reveals the remote and settings expose Pair Again and Forget', () => {
  const h = harness();
  h.ui.handleState({ phase: 'active' });

  assert.equal(h.elements.panel.hidden, true);
  assert.equal(h.elements.remote.hidden, false);
  assert.equal(h.elements.pairedState.textContent, 'Paired with your Mac.');
  assert.equal(h.elements.pairAgain.hidden, false);
  assert.equal(h.elements.forget.hidden, false);
});

test('Pair Again returns to the first-class pairing state without forgetting the active credential', () => {
  const h = harness({ paired: true });
  h.elements.pairAgain.dispatchEvent(event('click'));

  assert.equal(h.forgets(), 0);
  assert.equal(h.elements.panel.hidden, false);
  assert.equal(h.elements.remote.hidden, true);
  assert.equal(h.elements.heading.textContent, 'Pair this browser');
  assert.equal(h.elements.heading.focused, true);
});

test('Forget waits for durable removal before showing the unpaired state', async () => {
  let release;
  const blocked = new Promise((resolve) => { release = resolve; });
  const h = harness({ paired: true });
  h.ui.destroy();
  const ui = createPairingUI({
    elements: h.elements,
    enabled: true,
    paired: true,
    expectedHost: 'click.example',
    startPairing() {},
    cancelPairing() {},
    async forgetPairing() { await blocked; return true; },
    lifecycleTarget: h.lifecycleTarget,
  });

  h.elements.forget.dispatchEvent(event('click'));
  assert.equal(h.elements.forget.disabled, true);
  assert.equal(h.elements.panel.hidden, true);
  release();
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(h.elements.forget.disabled, false);
  assert.equal(h.elements.panel.hidden, false);
  assert.equal(h.elements.remote.hidden, true);
  assert.equal(h.elements.heading.textContent, 'Pair this browser');
  ui.destroy();
});

for (const [name, result] of [['success', true], ['failure', false]]) {
  test(`a stale Forget ${name} cannot overwrite a newer pairing attempt`, async () => {
    const pending = deferred();
    const h = harness({ paired: true, forgetPairing: () => pending.promise });

    h.elements.forget.dispatchEvent(event('click'));
    h.ui.start({ pairingVersion: 1, reference: REFERENCE });
    pending.resolve(result);
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(h.starts, [REFERENCE]);
    assert.equal(h.elements.heading.textContent, 'Pair this browser');
    assert.equal(h.elements.message.textContent, 'Claiming the pairing link…');
    assert.equal(h.elements.alert.hidden, true);
  });
}

test('Escape and page hide cancel an in-progress claimant lifecycle', () => {
  const h = harness();
  h.ui.handleState({ phase: 'claiming' });
  h.lifecycleTarget.dispatchEvent(event('keydown', { key: 'Escape' }));
  h.ui.handleState({ phase: 'awaiting_approval', confirmationCode: '123 456' });
  h.lifecycleTarget.dispatchEvent(event('pagehide'));

  assert.equal(h.cancels(), 2);
  assert.equal(h.elements.code.textContent, '');
  assert.equal(h.elements.code.hidden, true);
});

test('page hide cancels startup credential recovery before it can activate', () => {
  const h = harness();

  h.ui.startRecovery();
  h.lifecycleTarget.dispatchEvent(event('pagehide'));

  assert.equal(h.cancels(), 1);
  assert.equal(h.elements.code.textContent, '');
  assert.equal(h.elements.code.hidden, true);
});

test('reentrant cancellation publishes a stable home state and does not cancel twice', () => {
  const h = harness({ cancelPairing: (ui) => ui.handleState({ phase: 'cancelled' }) });
  h.ui.handleState({ phase: 'claiming' });

  h.lifecycleTarget.dispatchEvent(event('pagehide'));
  h.lifecycleTarget.dispatchEvent(event('pagehide'));

  assert.equal(h.cancels(), 1);
  assert.equal(h.elements.heading.textContent, 'Pair this browser');
  assert.equal(h.elements.message.textContent, 'Open a pairing link from your Mac, or paste it here.');
});

test('destroy ignores a reentrant controller state publication', () => {
  const h = harness({ cancelPairing: (ui) => ui.handleState({ phase: 'cancelled' }) });
  h.ui.handleState({ phase: 'claiming' });
  h.elements.heading.focused = false;

  h.ui.destroy();

  assert.equal(h.cancels(), 1);
  assert.equal(h.elements.heading.focused, false);
});
