import test from 'node:test';
import assert from 'node:assert/strict';

import {
  initialState, reduce, view, phaseOf, PHASE,
  activationDecision, clockHealthy, clockSample, bestSample,
} from '../public/state.js';

import { CLOCK_SKEW_TOLERANCE_MS } from '../src/constants.js';

const ID = '018f63f5-6f3d-7d21-88bc-9ef561f030de';
const OTHER = '018f63f5-6f3d-7d21-88bc-9ef561f030ff';

const apply = (state, ...events) => events.reduce(reduce, state);

/** A fully healthy, tappable state. */
function readyState() {
  return apply(initialState(),
    { type: 'token.set', token: '1'.repeat(64) },
    { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'ready' },
    { type: 'clock.health', healthy: true, offsetMs: 12, uncertaintyMs: 40 },
  );
}

// ---------------------------------------------------------------------------
// Every product state
// ---------------------------------------------------------------------------

test('missing token', () => {
  assert.equal(phaseOf(initialState()), PHASE.MISSING_TOKEN);
  assert.equal(view(initialState()).enabled, false);
});

test('connecting', () => {
  const s = apply(initialState(), { type: 'token.set', token: 'x' });
  assert.equal(phaseOf(s), PHASE.CONNECTING);
  assert.equal(view(s).enabled, false);
});

test('mac offline', () => {
  const s = apply(initialState(),
    { type: 'token.set', token: 'x' }, { type: 'transport.open' });
  assert.equal(phaseOf(s), PHASE.MAC_OFFLINE);
});

test('permission required', () => {
  const s = apply(initialState(),
    { type: 'token.set', token: 'x' }, { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'required' });
  assert.equal(phaseOf(s), PHASE.PERMISSION_REQUIRED);
  assert.equal(view(s).enabled, false);
});

test('remote disabled', () => {
  const s = apply(initialState(),
    { type: 'token.set', token: 'x' }, { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: false, permission: 'ready' });
  assert.equal(phaseOf(s), PHASE.REMOTE_DISABLED);
});

test('clock checking, then unhealthy, then ready', () => {
  const base = apply(initialState(),
    { type: 'token.set', token: 'x' }, { type: 'transport.open' },
    { type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'ready' });
  assert.equal(phaseOf(base), PHASE.CLOCK_CHECKING, 'gated until measured');
  assert.equal(view(base).enabled, false);

  const bad = reduce(base, { type: 'clock.health', healthy: false, offsetMs: 5000, uncertaintyMs: 30 });
  assert.equal(phaseOf(bad), PHASE.CLOCK_UNHEALTHY);
  assert.equal(view(bad).enabled, false);
  assert.match(view(bad).status, /automatic date and time/);

  const good = reduce(base, { type: 'clock.health', healthy: true, offsetMs: 8, uncertaintyMs: 30 });
  assert.equal(phaseOf(good), PHASE.READY);
  assert.equal(view(good).enabled, true);
});

test('ready → sending → forwarded → posted', () => {
  let s = readyState();
  assert.equal(phaseOf(s), PHASE.READY);

  s = reduce(s, { type: 'action.sent', actionId: ID });
  assert.equal(phaseOf(s), PHASE.SENDING);
  assert.equal(view(s).enabled, false, 'disabled while in flight');

  s = reduce(s, { type: 'action.ack', actionId: ID, status: 'forwarded' });
  assert.equal(phaseOf(s), PHASE.FORWARDED);
  assert.equal(view(s).enabled, false);

  s = reduce(s, { type: 'action.result', actionId: ID, status: 'posted', reason: 'ok', ms: 74 });
  assert.equal(phaseOf(s), PHASE.POSTED);
  assert.equal(view(s).status, 'Posted in 74 ms');
  assert.equal(view(s).enabled, true, 're-armed');
});

test('hidden', () => {
  const s = reduce(readyState(), { type: 'visibility', visible: false });
  assert.equal(phaseOf(s), PHASE.HIDDEN);
  assert.equal(view(s).enabled, false);
});

// ---------------------------------------------------------------------------
// The ack/result distinction
// ---------------------------------------------------------------------------

test('relay.ack can never produce Posted', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.ack', actionId: ID, status: 'forwarded' });
  assert.notEqual(phaseOf(s), PHASE.POSTED);
  assert.equal(phaseOf(s), PHASE.FORWARDED);
});

test('mac_offline ack terminates the action as rejected', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.ack', actionId: ID, status: 'mac_offline' });
  assert.equal(phaseOf(s), PHASE.REJECTED);
  assert.equal(s.action, null);
  assert.match(view(s).status, /offline/);
});

test('a rejected result reports its reason', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.result', actionId: ID, status: 'rejected', reason: 'remote_disabled' });
  assert.equal(phaseOf(s), PHASE.REJECTED);
  assert.match(view(s).status, /Enable remote control/);
});

// ---------------------------------------------------------------------------
// One action in flight; terminal states absorb
// ---------------------------------------------------------------------------

test('a second activation while pending produces no request', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  assert.equal(activationDecision('pointer', s), 'ignore');
  const after = reduce(s, { type: 'action.sent', actionId: OTHER });
  assert.equal(after.action.id, ID, 'first action is untouched');
});

test('result timeout becomes Unknown and never retries', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.timeout', actionId: ID });
  assert.equal(phaseOf(s), PHASE.UNKNOWN);
  assert.equal(s.action, null);
  assert.match(view(s).status, /check the Mac/);
});

test('a late result after timeout counts as diagnostics and cannot regress', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.timeout', actionId: ID });
  const before = phaseOf(s);

  s = reduce(s, { type: 'action.result', actionId: ID, status: 'posted', reason: 'ok', ms: 900 });
  assert.equal(phaseOf(s), before, 'terminal state is absorbing');
  assert.equal(s.lateResultCount, 1, 'counted for diagnostics only');
});

test('a duplicate result from a second transport is counted, not applied', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.result', actionId: ID, status: 'posted', reason: 'ok', ms: 70 });
  assert.equal(s.lateResultCount, 0);

  s = reduce(s, { type: 'action.result', actionId: ID, status: 'posted', reason: 'ok', ms: 90 });
  assert.equal(s.lateResultCount, 1);
  assert.equal(view(s).status, 'Posted in 70 ms', 'first result wins');
});

test('an ack for an unknown action is ignored', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  const after = reduce(s, { type: 'action.ack', actionId: OTHER, status: 'forwarded' });
  assert.equal(after.action.phase, 'sending', 'unchanged');
});

// ---------------------------------------------------------------------------
// Visibility
// ---------------------------------------------------------------------------

test('hiding marks an in-flight action Unknown', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'visibility', visible: false });
  assert.equal(s.action, null);
  assert.equal(s.last.outcome, 'unknown');
});

test('becoming visible clears stale readiness and creates no action', () => {
  let s = reduce(readyState(), { type: 'visibility', visible: false });
  s = reduce(s, { type: 'visibility', visible: true });
  assert.equal(s.connected, false, 'must re-establish');
  assert.equal(s.mac.online, false, 'stale Mac state discarded');
  assert.equal(s.clock.checked, false, 'clock must be re-measured');
  assert.equal(s.action, null);
  assert.equal(phaseOf(s), PHASE.CONNECTING);
});

test('a dropped transport marks an in-flight action Unknown', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'transport.closed' });
  assert.equal(s.last.outcome, 'unknown');
  assert.equal(s.action, null);
});

test('clearing the token resets everything', () => {
  let s = reduce(readyState(), { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'token.cleared' });
  assert.equal(phaseOf(s), PHASE.MISSING_TOKEN);
  assert.equal(s.action, null);
  assert.equal(s.last, null);
});

// ---------------------------------------------------------------------------
// Activation: pointer sequence, not a stopwatch
// ---------------------------------------------------------------------------

test('pointerdown sends and its synthetic click is consumed', () => {
  const s = readyState();
  assert.equal(activationDecision('pointer', s), 'send');

  const armed = reduce(s, { type: 'pointer.armed' });
  assert.equal(activationDecision('click', armed), 'consume', 'no second request');
});

test('a long press still produces exactly one request', () => {
  // The old 400 ms window broke here: the synthetic click landed outside it and
  // read as a fresh activation. Sequence-based suppression has no such edge.
  let s = reduce(readyState(), { type: 'pointer.armed' });
  s = reduce(s, { type: 'action.sent', actionId: ID });
  s = reduce(s, { type: 'action.result', actionId: ID, status: 'posted', reason: 'ok', ms: 60 });
  // ... 5 seconds later the finger lifts and the synthetic click fires.
  assert.equal(activationDecision('click', s), 'consume');
});

test('keyboard and assistive activation still work', () => {
  const s = readyState();
  assert.equal(s.pointerArmed, false);
  assert.equal(activationDecision('click', s), 'send', 'VoiceOver / keyboard path');
});

test('a cancelled pointer disarms suppression', () => {
  let s = reduce(readyState(), { type: 'pointer.armed' });
  s = reduce(s, { type: 'pointer.cancelled' });
  assert.equal(activationDecision('click', s), 'send');
});

test('activation is refused whenever the gate is shut', () => {
  const shut = apply(initialState(), { type: 'token.set', token: 'x' });
  assert.equal(activationDecision('pointer', shut), 'ignore');
  assert.equal(activationDecision('click', shut), 'ignore');
});

// ---------------------------------------------------------------------------
// Clock maths
// ---------------------------------------------------------------------------

test('NTP offset and round trip are computed correctly', () => {
  // Mac clock is exactly 100 ms ahead; each leg takes 20 ms.
  const { offsetMs, rttMs } = clockSample({ t0: 1000, t1: 1120, t2: 1125, t3: 1045 });
  assert.equal(offsetMs, 100);
  assert.equal(rttMs, 40);
});

test('a symmetric path with no skew reports zero offset', () => {
  const { offsetMs, rttMs } = clockSample({ t0: 0, t1: 25, t2: 25, t3: 50 });
  assert.equal(offsetMs, 0);
  assert.equal(rttMs, 50);
});

test('best sample is the smallest non-negative round trip', () => {
  const s = bestSample([
    { offsetMs: 5, rttMs: 300 },
    { offsetMs: 9, rttMs: 40 },
    { offsetMs: 7, rttMs: -1 },   // impossible, discarded
    { offsetMs: 6, rttMs: 90 },
  ]);
  assert.equal(s.rttMs, 40);
});

test('an all-impossible sample set yields nothing', () => {
  assert.equal(bestSample([{ offsetMs: 1, rttMs: -5 }]), null);
  assert.equal(bestSample([]), null);
});

test('health threshold widens by the measurement uncertainty', () => {
  const T = CLOCK_SKEW_TOLERANCE_MS;
  assert.equal(clockHealthy(0, 40, T), true);
  assert.equal(clockHealthy(T, 0, T), true, 'exactly at tolerance');
  assert.equal(clockHealthy(T + 1, 0, T), false, 'past tolerance on a perfect link');
  assert.equal(clockHealthy(T + 100, 400, T), true, 'excused by RTT/2 uncertainty');
  assert.equal(clockHealthy(-(T + 100), 400, T), true, 'symmetric for a fast clock');
  assert.equal(clockHealthy(5000, 40, T), false, 'a real skew still fails');
});

test('a fast phone clock is caught too', () => {
  // The fail-open direction: without a symmetric check, expiry would silently
  // never trigger for a phone running ahead.
  assert.equal(clockHealthy(-4000, 50, CLOCK_SKEW_TOLERANCE_MS), false);
});
