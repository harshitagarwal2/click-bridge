# Physical smoke test

Status: **NOT RUN**.

Simulator, fake relay, and unit-test results do not satisfy this gate.

This is the canonical operator acceptance guide. It separates scenarios driven
through the installed Release phone client from protocol-negative scenarios
driven through the repository harness. Both use the public OCI WSS relay, the
installed Release Mac receiver, and an explicitly harmless Octo target. Record
observed results; never infer them from protocol messages alone. A required row
that cannot be produced on its named execution surface is a failure, not a
skip.

## Preconditions

- The phone client under test is foreground-visible.
- The Mac is unlocked and awake, with automatic date and time enabled
  everywhere.
- Mac remote control is on and PostEvent Accessibility permission is granted.
- Octo is frontmost with an operator-visible counter and recorded starting
  value.
- Tokens remain outside screenshots, CSV, command output, and repository files.

## Physical Release-client matrix

Run these rows from the physical Release phone client on cellular. Do not use
the negative harness as evidence for this table.

| Scenario | Required result |
| --- | --- |
| Mac app closed | Button disabled; no queued click |
| Remote control off | No input; phone reports remote disabled |
| Permission absent or revoked | No input; `permission_required` |
| Initial clock health | Before the fifth valid response, action stays disabled and no request is sent; Ready only after five valid sync responses |
| Clock sync response missing | One missing response changes status to `Clock check unavailable` at 3.5 seconds, exposes Retry, and sends no action |
| Retry clock check | Selecting Retry starts a fresh five-sample batch; no action or replay can send until all five valid responses complete |
| Ready, Octo frontmost | One action/result; Mac `+3/+3`; Octo `+3` |
| Phone hidden with an action pending | `Unknown`; no replay |
| Phone visible again | Reconnect only; nothing sent |
| Relay container restarts | Both reconnect; no replay |
| OCI VM reboots | Services recover; no replay |
| VoiceOver or keyboard activation | Exactly one request |
| Two taps while pending | Second action suppressed |
| Mac locks or sleeps | No click; documented, not a crash |
| Mac wakes or unlocks | Fresh Ready; no replay; only a new action may send |
| Mac clock is set 5 seconds off | `Clock mismatch`; no request; not `expired` |
| Secure Input active | Record behavior and any unexpected result |

For unexpected Secure Input behavior, inspect `IsSecureEventInputEnabled()`.

## Controlled negative-harness matrix

These protocol-shaped rows require the repository harness. Before running it,
disconnect the regular phone client and verify that it stays disconnected for
the entire matrix. Keep the Release Mac receiver connected, unlocked, remotely
enabled, and Accessibility-authorized. Keep Octo frontmost and record a fresh
before/after counter pair for every row.

| Scenario | Required result |
| --- | --- |
| Duplicate action ID | One total three-click burst; identical cached result |
| Same ID, changed payload | `id_conflict`; no second increment |
| Expired buffered request | `expired`; no input |
| Result path drops after forwarding | One three-click execution across the disconnect window; no late result or replay after the harness reconnects |

Run the checked-in `relay/scripts/run-negative-matrix.mjs` harness from the
repository root using Node 24. Supply the phone token through the inherited
environment, never as a command argument. Enter the four observed Octo
before/after pairs as one JSON object when prompted; do not reuse expected
values as observations.

```bash
cd relay
report_path="$(mktemp /private/tmp/click-bridge-negative-matrix.XXXXXX)"
chmod 600 "$report_path"
read -r -p 'Relay WSS URL: ' CLICK_BRIDGE_URL
read -r -s -p 'PHONE_TOKEN: ' PHONE_TOKEN
printf '\n'
read -r -p 'Octo observations JSON: ' NEGATIVE_MATRIX_OCTO_OBSERVATIONS
export CLICK_BRIDGE_URL PHONE_TOKEN NEGATIVE_MATRIX_OCTO_OBSERVATIONS
node scripts/run-negative-matrix.mjs | tee "$report_path"
matrix_status="${PIPESTATUS[0]}"
unset CLICK_BRIDGE_URL PHONE_TOKEN NEGATIVE_MATRIX_OCTO_OBSERVATIONS
printf 'Redacted JSON report: %s\n' "$report_path"
test "$matrix_status" -eq 0
```

The JSON report is the controlled-matrix evidence. Require all four outcomes
to be `pass`, preserve the exact release commit and report path, and record the
Mac post counters and Octo observations that support each row. The report must
not contain either role token. Do not reconnect the regular phone client until
the harness has exited and the relay has retired its harness connection.

For every operator row, record the terminal state, Mac `mouseDown` and
`mouseUp` counter deltas, Octo counter delta, and replay outcome. Exact
one-action evidence requires one logical action ID/result, Mac `mouseDown +3`
and `mouseUp +3`, and Octo `+3`—not merely a Posted wire result.

Duplicate delivery must preserve one total three-click burst and the exact
cached result. Conflict, expiry, remote-off, and permission failure remain
zero-input operator rows; event-creation failure remains automated-only.

## Automated-only acceptance

There is no Release-safe event creation failure injection for Core Graphics.
Keep `event_creation_failed` as automated acceptance in
`ActionProcessorTests.testPermissionAndEventCreationFailuresPostNoEvents` unless
a separately reviewed Release-safe injection is added. Do not claim that case
as physical or controlled-harness evidence.

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
