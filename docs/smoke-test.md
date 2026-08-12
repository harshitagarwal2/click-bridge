# Physical smoke matrix

Run every row from the real phone on cellular, with the installed Release
build. A row that cannot be produced is a failure, not a skip.

| Scenario | Required result |
|---|---|
| Mac app closed | Button disabled; no queued click |
| Remote control off | No input; phone reports remote disabled |
| Permission absent or revoked | No input; `permission_required` |
| Ready, Octo frontmost | One tap; one logical action/result and exactly three Octo counter increments |
| Duplicate action ID | One total three-click burst (`+3/+3` attempted Mac posts and Octo `+3`); identical cached result |
| Same ID, changed payload | `id_conflict`; no second increment |
| Expired buffered request | `expired`; no input |
| Phone hidden with an action pending | `Unknown`; no replay |
| Phone visible again | Reconnect only; nothing sent |
| Relay container restart | Both reconnect; no replay |
| OCI VM reboot | Services recover; no replay |
| Result path drops after forwarding | `Unknown` at 4s; no retry |
| VoiceOver / keyboard activation | Exactly one request |
| Two taps while pending | Second suppressed |
| Mac locked or asleep | No click; documented, not a crash |
| Mac clock set 5s off | Button blocked with "Clock mismatch", not `expired` |
| Secure Input active (password field focused) | Record behaviour; check `IsSecureEventInputEnabled()` if odd |

## Octo down/up gap calibration

`CLICK_GAP_MS` starts at 0. Test in this order and stop at the FIRST value that
gives 300 increments from 100 distinct Posted actions:

```
0 ms → 5 ms → 10 ms → 20 ms → 30 ms
```

Do not pick a larger gap after one passes. Record raw counts and the chosen
value with the exact Octo and macOS versions.

`CGEvent` at `.cghidEventTap` injects below the window server, so Octo cannot
distinguish it from real hardware input. It clicks whatever is topmost under
the cursor — it does not target Octo specifically.

## Reading the results

The Mac's diagnostic counters record attempted `CGEvent.post` calls. For 100
Posted actions, require `mouseDown +300` and `mouseUp +300`, while Octo must
show 300 increments. Because `CGEvent.post(tap:)` returns no success result,
the matching Octo delta is the authoritative physical-target observation.
`CLICK_GAP_MS` applies within each of the three down/up pairs; there is no
separate inter-click delay.
