# Physical smoke matrix

Run every row from the real phone on cellular, with the installed Release
build. A row that cannot be produced is a failure, not a skip.

| Scenario | Required result |
|---|---|
| Mac app closed | Button disabled; no queued click |
| Remote control off | No input; phone reports remote disabled |
| Permission absent or revoked | No input; `permission_required` |
| Ready, Octo frontmost | One tap, exactly one counter increment |
| Duplicate action ID | One total increment; identical cached result |
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
gives 100 increments from 100 distinct actions:

```
0 ms → 5 ms → 10 ms → 20 ms → 30 ms
```

Do not pick a larger gap after one passes. Record raw counts and the chosen
value with the exact Octo and macOS versions.

`CGEvent` at `.cghidEventTap` injects below the window server, so Octo cannot
distinguish it from real hardware input. It clicks whatever is topmost under
the cursor — it does not target Octo specifically.

## Reading the results

Use the Mac's diagnostic post counters, not just Octo's on-screen number. The
counters prove how many `CGEvent.post` calls actually happened; the UI count
only proves how many the app noticed.
