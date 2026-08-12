import test from 'node:test';
import assert from 'node:assert/strict';

import { createRuntimeScheduler } from '../public/runtime-scheduler.js';

test('browser timer methods retain their runtime receiver', () => {
  const calls = [];
  const runtime = {
    setTimeout(callback, delay) {
      if (this !== runtime) throw new TypeError('Illegal invocation');
      calls.push(['set', callback, delay]);
      return 9;
    },
    clearTimeout(timer) {
      if (this !== runtime) throw new TypeError('Illegal invocation');
      calls.push(['clear', timer]);
    },
  };
  const scheduler = createRuntimeScheduler(runtime);
  const callback = () => {};

  assert.equal(scheduler.setTimeout(callback, 25), 9);
  scheduler.clearTimeout(9);
  assert.deepEqual(calls, [['set', callback, 25], ['clear', 9]]);
});
