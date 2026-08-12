// The coordinator owns the ONE logical action. These tests prove that adding a
// second transport (Milestone 2) cannot create a second action, and that
// hedging sends the identical immutable payload down both paths.

import test from 'node:test';
import assert from 'node:assert/strict';

import { TransportCoordinator } from '../public/transport-coordinator.js';
import { initialState, reduce, phaseOf, PHASE } from '../public/state.js';
import { ACTION_LIFETIME_MS, PHONE_RESULT_TIMEOUT_MS } from '../public/constants-lite.js';

function fakeTransport(name, ready = true) {
  return {
    name,
    controller: { name, ready, sent: [], send(m) { this.sent.push(m); return true; } },
  };
}

function harness({ transports, hedging = false, ready = true } = {}) {
  let state = initialState();
  state = reduce(state, { type: 'token.set', token: '1'.repeat(64) });
  state = reduce(state, { type: 'transport.open' });
  state = reduce(state, {
    type: 'mac.state', macOnline: true, remoteEnabled: true, permission: 'ready',
  });
  if (ready) {
    state = reduce(state, {
      type: 'clock.health', healthy: true, offsetMs: 5, uncertaintyMs: 20,
    });
  }

  const timers = new Map();
  let seq = 0;
  let uuidN = 0;
  let clock = 1_786_497_600_000;

  const c = new TransportCoordinator({
    getState: () => state,
    dispatch: (e) => { state = reduce(state, e); },
    transports,
    now: () => clock,
    uuid: () => `00000000-0000-4000-8000-${String(++uuidN).padStart(12, '0')}`,
    setTimeout: (fn, ms) => { timers.set(++seq, { fn, ms }); return seq; },
    clearTimeout: (id) => timers.delete(id),
  });
  c.hedging = hedging;

  return {
    c,
    get state() { return state; },
    fireTimer(ms) {
      for (const [id, t] of [...timers]) {
        if (t.ms === ms) { timers.delete(id); t.fn(); }
      }
    },
    advance: (ms) => { clock += ms; },
  };
}

// ---------------------------------------------------------------------------

test('a single ready transport sends exactly one request', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });

  assert.equal(h.c.activate('pointer'), 'sent');
  assert.equal(oci.controller.sent.length, 1);

  const req = oci.controller.sent[0];
  assert.equal(req.type, 'action.request');
  assert.equal(req.action, 'click');
  assert.equal(req.expiresAtUnixMs - req.issuedAtUnixMs, ACTION_LIFETIME_MS,
    'lifetime relation is exact');
});

test('with hedging off only the preferred transport is used', () => {
  const oci = fakeTransport('oci');
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [ts, oci] });   // deliberately out of order

  h.c.activate('pointer');
  assert.equal(oci.controller.sent.length, 1, 'preferred path chosen');
  assert.equal(ts.controller.sent.length, 0);
  assert.equal(h.c.pathsSent, 'oci');
});

test('the preferred transport is configurable', () => {
  const oci = fakeTransport('oci');
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [oci, ts] });
  h.c.preferredName = 'tailscale';

  h.c.activate('pointer');
  assert.equal(ts.controller.sent.length, 1);
  assert.equal(oci.controller.sent.length, 0);
});

test('hedging sends the IDENTICAL payload down both paths', () => {
  const oci = fakeTransport('oci');
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [oci, ts], hedging: true });

  h.c.activate('pointer');
  assert.equal(oci.controller.sent.length, 1);
  assert.equal(ts.controller.sent.length, 1);

  const a = oci.controller.sent[0];
  const b = ts.controller.sent[0];
  assert.equal(a.actionId, b.actionId, 'one logical action, one id');
  assert.deepEqual(a, b, 'byte-identical payload, never regenerated');
  assert.equal(h.c.pathsSent, 'oci+tailscale');
});

test('hedging still creates only ONE logical action', () => {
  const oci = fakeTransport('oci');
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [oci, ts], hedging: true });

  h.c.activate('pointer');
  assert.equal(h.state.action?.id, oci.controller.sent[0].actionId);
  assert.equal(phaseOf(h.state), PHASE.SENDING);

  // A second activation while pending must produce nothing on either path.
  h.c.activate('pointer');
  assert.equal(oci.controller.sent.length, 1);
  assert.equal(ts.controller.sent.length, 1);
});

test('one unavailable transport still sends on the other', () => {
  const oci = fakeTransport('oci', false);      // not ready
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [oci, ts], hedging: true });

  assert.equal(h.c.activate('pointer'), 'sent');
  assert.equal(oci.controller.sent.length, 0);
  assert.equal(ts.controller.sent.length, 1);
  assert.equal(h.c.pathsSent, 'tailscale');
});

test('no ready transport means no action at all', () => {
  const oci = fakeTransport('oci', false);
  const h = harness({ transports: [oci] });

  assert.equal(h.c.activate('pointer'), 'ignored');
  assert.equal(h.state.action, null, 'no phantom in-flight action');
});

test('relay.ack never completes the action', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });
  h.c.activate('pointer');
  const id = oci.controller.sent[0].actionId;

  h.c.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: id, status: 'forwarded', relayProcessingUs: 120,
  });
  assert.equal(phaseOf(h.state), PHASE.FORWARDED);
  assert.notEqual(phaseOf(h.state), PHASE.POSTED);
});

test('the first terminal result wins and the second is diagnostics only', () => {
  const oci = fakeTransport('oci');
  const ts = fakeTransport('tailscale');
  const h = harness({ transports: [oci, ts], hedging: true });
  h.c.activate('pointer');
  const id = oci.controller.sent[0].actionId;

  const result = (via) => h.c.handleMessage(via, {
    type: 'action.result', v: 1, actionId: id, status: 'posted', reason: 'ok',
    acceptedVia: 'oci', macProcessingUs: 800, mouseDownPostedUnixMs: 1_786_497_600_100,
  });

  result('tailscale');
  assert.equal(phaseOf(h.state), PHASE.POSTED);
  assert.equal(h.c.firstResultVia, 'tailscale', 'records which path won');
  assert.equal(h.state.lateResultCount, 0);

  result('oci');                                  // the loser arrives
  assert.equal(phaseOf(h.state), PHASE.POSTED, 'terminal state is absorbing');
  assert.equal(h.state.lateResultCount, 1, 'counted, not applied');
});

test('a timeout produces Unknown and never re-sends', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });
  h.c.activate('pointer');

  h.fireTimer(PHONE_RESULT_TIMEOUT_MS);
  assert.equal(phaseOf(h.state), PHASE.UNKNOWN);
  assert.equal(oci.controller.sent.length, 1, 'no retry');
});

test('a terminal ack stops the result timer', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });
  h.c.activate('pointer');
  const id = oci.controller.sent[0].actionId;

  h.c.handleMessage('oci', {
    type: 'relay.ack', v: 1, actionId: id, status: 'mac_offline', relayProcessingUs: 90,
  });
  assert.equal(phaseOf(h.state), PHASE.REJECTED);
  h.fireTimer(PHONE_RESULT_TIMEOUT_MS);
  assert.equal(phaseOf(h.state), PHASE.REJECTED, 'timeout cannot override a real answer');
});

test('the clock gate blocks activation until measured', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci], ready: false });

  assert.equal(phaseOf(h.state), PHASE.CLOCK_CHECKING);
  assert.equal(h.c.activate('pointer'), 'ignored');
  assert.equal(oci.controller.sent.length, 0, 'nothing sent before the clock is checked');
});

test('clock health runs three exchanges and picks the smallest RTT', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci], ready: false });

  h.c.startClockHealth('oci');
  const syncs = oci.controller.sent.filter((m) => m.type === 'time.sync.request');
  assert.equal(syncs.length, 3, 'CLOCK_HEALTH_SAMPLES exchanges');

  // Two contaminated samples and one clean one; the clean one must win.
  const reply = (s, macRecv, macSend, t3) => {
    h.advance(t3 - h.state.__t ?? 0);
    h.c.handleMessage('oci', {
      type: 'time.sync.response', v: 1, syncId: s.syncId,
      phoneSendUnixMs: s.phoneSendUnixMs, macReceiveUnixMs: macRecv, macSendUnixMs: macSend,
    });
  };

  const t0 = syncs[0].phoneSendUnixMs;
  reply(syncs[0], t0 + 300, t0 + 301, t0 + 600);   // rtt 599
  reply(syncs[1], t0 + 20, t0 + 21, t0 + 40);      // rtt 39  <- cleanest
  reply(syncs[2], t0 + 150, t0 + 151, t0 + 300);   // rtt 299

  assert.equal(h.state.clock.checked, true);
  assert.ok(h.state.clock.uncertaintyMs <= 300,
    `expected the low-RTT sample to win, got ±${h.state.clock.uncertaintyMs}`);
});

test('reset clears timers and in-flight sync state', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });
  h.c.activate('pointer');
  h.c.startClockHealth('oci');

  h.c.reset();
  assert.equal(h.c.resultTimer, null);
  assert.equal(h.c.pendingSyncs.size, 0);
  assert.equal(h.c.samples.length, 0);
});

test('a consumed synthetic click sends nothing', () => {
  const oci = fakeTransport('oci');
  const h = harness({ transports: [oci] });

  h.c.activate('pointer');
  assert.equal(oci.controller.sent.length, 1);

  // The click that belongs to that pointer sequence.
  assert.equal(h.c.activate('click'), 'consumed');
  assert.equal(oci.controller.sent.length, 1, 'still one request');
});
