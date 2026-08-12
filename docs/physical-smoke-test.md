# Physical smoke test

Status: **NOT RUN**.

Simulator, fake relay, and unit-test results do not satisfy this gate.

This is the canonical physical acceptance guide. Use a physical phone on
cellular, the public OCI WSS relay, the installed Release phone client and Mac
receiver, and an explicitly harmless Octo target. Record observed results;
never infer them from protocol messages alone. A required row that cannot be
produced is a failure, not a skip.

## Preconditions

- The phone client under test is foreground-visible.
- The Mac is unlocked and awake, with automatic date and time enabled
  everywhere.
- Mac remote control is on and PostEvent Accessibility permission is granted.
- Octo is frontmost with an operator-visible counter and recorded starting
  value.
- Tokens remain outside screenshots, CSV, command output, and repository files.

## Required scenario matrix

| Scenario | Required result |
| --- | --- |
| Mac app closed | Button disabled; no queued click |
| Remote control off | No input; phone reports remote disabled |
| Permission absent or revoked | No input; `permission_required` |
| Clock sync response missing | Action blocked; no request sent |
| Clock becomes Ready again | New action only; no replay |
| Ready, Octo frontmost | One action/result; Mac `+3/+3`; Octo `+3` |
| Duplicate action ID | One total three-click burst; identical cached result |
| Same ID, changed payload | `id_conflict`; no second increment |
| Expired buffered request | `expired`; no input |
| Event creation fails | `event_creation_failed`; no input |
| Phone hidden with an action pending | `Unknown`; no replay |
| Phone visible again | Reconnect only; nothing sent |
| Relay container restarts | Both reconnect; no replay |
| OCI VM reboots | Services recover; no replay |
| Result path drops after forwarding | `Unknown` at 4 seconds; no retry |
| VoiceOver or keyboard activation | Exactly one request |
| Two taps while pending | Second action suppressed |
| Mac locks or sleeps | No click; documented, not a crash |
| Mac wakes or unlocks | Fresh Ready; no replay; only a new action may send |
| Mac clock is set 5 seconds off | `Clock mismatch`; no request; not `expired` |
| Secure Input active | Record behavior and any unexpected result |

For unexpected Secure Input behavior, inspect `IsSecureEventInputEnabled()`.

For every row, record the terminal state, Mac `mouseDown` and `mouseUp` counter
deltas, Octo counter delta, and replay outcome. Exact one-action evidence
requires one logical action ID/result, Mac `mouseDown +3` and `mouseUp +3`, and
Octo `+3`—not merely a Posted wire result.

Duplicate delivery must preserve one total three-click burst and the exact
cached result. Conflict, expiry, remote-off, permission, and event-creation
failure remain zero-input rows.

## Octo down/up gap calibration

`CLICK_GAP_MS` starts at 0. Test in this order and stop at the first value that
gives 300 increments from 100 distinct Posted actions:

```text
0 ms -> 5 ms -> 10 ms -> 20 ms -> 30 ms
```

Do not select a larger gap after one passes. Record raw counts, the selected
value, and the exact Octo and macOS versions.

`CGEvent` at `.cghidEventTap` injects below the window server, so Octo cannot
distinguish it from real hardware input. It clicks whatever is frontmost under
the cursor; it does not target Octo specifically.

## Reading the results

Mac diagnostic counters record attempted `CGEvent.post` calls. For 100 Posted
actions, require `mouseDown +300` and `mouseUp +300`, while Octo must show 300
increments. Core Graphics returns no success result from `CGEvent.post(tap:)`,
so the matching Octo delta is the authoritative physical-target observation.

`CLICK_GAP_MS` applies within each of the three down/up pairs; there is no
separate inter-click delay.

This acceptance remains **NOT RUN** until recorded with a real phone and Octo.
