# Physical smoke test

Status: **NOT RUN**. Simulator, fake relay, and unit-test results do not satisfy this gate.

Use a physical phone on cellular, the public OCI WSS relay, the installed Mac receiver, and
an explicitly harmless Octo target. Record observed results; never infer them from protocol
messages alone.

## Preconditions

- PWA foreground-visible, Mac unlocked/awake, automatic date/time enabled everywhere.
- Mac remote control on and PostEvent accessibility permission granted.
- Octo frontmost with an operator-visible counter and its starting value recorded.
- Tokens remain outside screenshots, CSV, command output, and repository files.

## Required rows

- Mac closed; remote off; permission missing/revoked.
- Fresh Ready clock gate; missing sync response; retry after recovery.
- One Ready tap; duplicate; ID conflict; expired; result drop.
- Hide with pending action; visible reconnect; relay restart; VM reboot.
- VoiceOver/keyboard activation; two taps while pending; Mac lock/sleep then fresh Ready.

For each row record terminal state, Mac counter delta, Octo counter delta, and replay outcome.
Exact one-action evidence requires one logical action ID/result, Mac
`mouseDown +3` and `mouseUp +3`, and Octo `+3`—not merely a Posted wire
result. Duplicate delivery must preserve one total three-click burst and the
exact cached result; conflict, expiry, remote-off, permission, and event-creation
failure remain zero-input rows.

Mac diagnostic counters record attempted `CGEvent.post` calls. Core Graphics
returns no success result from `CGEvent.post(tap:)`, so the matching Octo delta
is the authoritative physical-target observation. This acceptance remains
**NOT RUN** until recorded with a real phone and Octo.
