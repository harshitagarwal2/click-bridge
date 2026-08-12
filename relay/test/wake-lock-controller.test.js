import test from 'node:test';
import assert from 'node:assert/strict';

import { WakeLockController } from '../public/wake-lock-controller.js';

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function lock() {
  const listeners = [];
  return {
    releases: 0,
    addEventListener(type, listener) { if (type === 'release') listeners.push(listener); },
    async release() { this.releases += 1; for (const listener of listeners) listener(); },
  };
}

test('duplicate acquire while pending requests one wake lock', async () => {
  const pending = deferred();
  let requests = 0;
  const controller = new WakeLockController({
    requestLock: () => { requests += 1; return pending.promise; },
  });

  const first = controller.acquire();
  const second = controller.acquire();
  assert.equal(requests, 1);
  assert.equal(first, second);
  pending.resolve(lock());
  await first;
  assert.equal(controller.state, 'active');
});

test('lock resolving after hidden is released and cannot become current', async () => {
  const pending = deferred();
  const lateLock = lock();
  const controller = new WakeLockController({ requestLock: () => pending.promise });

  const acquiring = controller.acquire();
  await controller.suspend();
  pending.resolve(lateLock);
  await acquiring;

  assert.equal(lateLock.releases, 1);
  assert.equal(controller.state, 'suspended');
  assert.equal(controller.lock, null);
});

test('new visible generation owns its lock even if the old request resolves later', async () => {
  const oldPending = deferred();
  const newPending = deferred();
  const oldLock = lock();
  const newLock = lock();
  let calls = 0;
  const controller = new WakeLockController({
    requestLock: () => (++calls === 1 ? oldPending.promise : newPending.promise),
  });

  const oldAcquire = controller.acquire();
  await controller.suspend();
  const newAcquire = controller.acquire();
  newPending.resolve(newLock);
  await newAcquire;
  oldPending.resolve(oldLock);
  await oldAcquire;

  assert.equal(oldLock.releases, 1);
  assert.equal(newLock.releases, 0);
  assert.equal(controller.lock, newLock);
  assert.equal(controller.state, 'active');
});

test('suspend releases the active lock exactly once', async () => {
  const activeLock = lock();
  const controller = new WakeLockController({ requestLock: async () => activeLock });
  await controller.acquire();
  await controller.suspend();
  await controller.suspend();
  assert.equal(activeLock.releases, 1);
  assert.equal(controller.state, 'suspended');
});
