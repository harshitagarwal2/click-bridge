import assert from 'node:assert/strict';
import test from 'node:test';

import { noCompletedActionReplay } from '../scripts/smoke-relay.mjs';

const actionId = '06ec8858-3fa6-45f2-ad51-6fb930e852d7';

test('unrelated state traffic after completion is not mistaken for action replay', () => {
  const inbox = [
    { type: 'action.result', actionId, status: 'posted' },
  ];
  inbox.push({ type: 'state', macOnline: true, remoteEnabled: true, permission: 'ready' });

  assert.equal(noCompletedActionReplay(inbox, actionId), true);
});

test('another request for the completed action is detected as replay', () => {
  const inbox = [
    { type: 'action.result', actionId, status: 'posted' },
  ];
  inbox.push({ type: 'action.request', actionId });

  assert.equal(noCompletedActionReplay(inbox, actionId), false);
});

test('a replay already present at the observation snapshot cannot become the baseline', () => {
  const inbox = [
    { type: 'action.result', actionId, status: 'posted' },
    { type: 'action.result', actionId, status: 'posted' },
  ];

  assert.equal(noCompletedActionReplay(inbox, actionId), false);
});
