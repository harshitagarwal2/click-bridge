# How to test this correctly

Seven rungs. Each proves something the one below cannot, and **each has a
"does not prove" line** — that line is the point. A green rung is not evidence
for the rung above it.

Current state: rungs 1–3 green (198 Node tests, 11 live smoke checks, and 23
macOS unit tests; all with 0 skips). Rungs 4–7 need their real environments.

---

## Rung 1 — Node suite

```bash
cd ~/Desktop/clicker/relay
npm ci
npm run check          # syntax + all tests
```

**Expect:** `# pass 198`, `# fail 0`, `# skipped 0`.

Skipped ≠ passed. If `skipped` is non-zero, `ws` failed to resolve and the
socket suite silently ran only against the built-in mini server.

**Proves:** protocol validation, relay state machine, phone reducer, transport
generation/heartbeat logic, CSP compliance of the HTML, browser/server constant
parity, latency-summary maths.

**Does not prove:** that any of it behaves correctly over a real socket, that
the PWA renders, or that the Mac app exists.

---

## Rung 2 — Adversarial probes

The suite tests what I expected. This tests what I didn't.

```bash
cd ~/Desktop/clicker/relay
export PHONE_TOKEN=$(openssl rand -hex 32) MAC_TOKEN=$(openssl rand -hex 32)
PORT=8123 node src/server.js &
node scripts/smoke-relay.mjs ws://127.0.0.1:8123/ws
```

**Expect:** 11/11 checks.

Then confirm the negative surface by hand — oversized frame, auth timeout,
wrong-role token, path traversal, `POST /healthz`, stale action. All verified
passing as of the last run.

**Critical check that is easy to skip:**

```bash
grep -c "$PHONE_TOKEN\|$MAC_TOKEN" /tmp/relay.log     # MUST be 0
```

**Proves:** real WebSocket framing, auth rejection paths, HTTP hardening, that
a stale action never reaches the Mac, and that tokens never reach logs.

**Does not prove:** anything about latency (loopback is ~11 ms and meaningless),
or that the phone UI works.

---

## Rung 3 — Mac unit tests

```bash
cd ~/Desktop/clicker/mac
xcodegen generate && echo "SPEC OK"          # STOP if this fails
grep -c SharedMacState ClickBridgeMac.xcodeproj/project.pbxproj   # must be > 0
xcodebuild -project ClickBridgeMac.xcodeproj -scheme ClickBridgeMac \
  -destination 'platform=macOS' test
```

**Do not skip the `grep`.** XcodeGen can fail spec validation and leave a stale
`.xcodeproj` in place; `xcodebuild` then happily compiles the old file list and
the error looks like a code problem. This has already happened twice.

**Expect:** all `ActionProcessorTests` and `WireMessageTests` green. The one
that matters is `testThousandConcurrentDuplicatesPostOnce` — 1,000 concurrent
copies of one action across two ingresses, exactly one `CGEvent` post.

**Proves:** the at-most-once guarantee, the Swift/Node contract (both decode the
same fixtures), rejection reasons.

**Does not prove:** that a `CGEvent` reaches any application. Every test here
uses `FakePoster`. **No real click has ever been posted.**

---

## Rung 4 — Local vertical slice

Relay on localhost, Mac app pointed at it, controller page in a desktop browser.
**Not the phone** — a phone cannot reach your Mac's localhost, and an
`http://` LAN page cannot open a `wss://` socket.

Open `tests/manual/click-target.html` in Octo, put the cursor on the counter:

| Do this | Expect |
|---|---|
| One tap | Counter +1 |
| Same actionId twice | Counter +1 total |
| Remote toggle off | No increment |
| Revoke permission | No increment, `permission_required` |
| Kill the relay mid-action | `Unknown`, no retry, no increment |

**Then calibrate.** `CLICK_GAP_MS`: 0 → 5 → 10 → 20 → 30. Send 100 distinct
actions at each. **Stop at the first value giving 100/100.** Do not pick a
larger gap after one passes.

**Proves:** a real `CGEvent` reaches a real application; dedup holds against
real input; the gap value for your Octo build.

**Does not prove:** anything over the internet, over TLS, or on a phone.

---

## Rung 5 — Deploy

Order matters; each step's failure mode is invisible if you skip ahead.

1. **DNS first.** `dig +short "$CLICK_BRIDGE_DOMAIN"` must return the OCI IP
   *before* Caddy starts. A failed ACME challenge triggers backoff.
2. **Both firewall layers.** The VCN security list is not enough — Oracle's
   images drop 80/443 in iptables regardless. This is the single most common
   OCI failure.
3. **Build on the VM**, never on the Mac. An arm64 image will not run on an
   x86_64 shape.
4. Verify: `curl -fsS https://$DOMAIN/healthz` → `ok`, then re-run the smoke
   script against `wss://$DOMAIN/ws`.

**Verify the negative:** port 8080 must NOT be reachable from outside.

```bash
curl -m 5 http://$CLICK_BRIDGE_DOMAIN:8080/healthz    # MUST fail/timeout
```

**Proves:** trusted TLS, WSS through Caddy, correct exposure.

**Does not prove:** phone behaviour on a real carrier.

---

## Rung 6 — Physical smoke matrix

**On the real phone, on cellular — not office WiFi.** Cellular is where radio
wake, carrier egress, and NAT timeouts live, and those are the behaviours that
actually differ.

All 17 rows in `docs/smoke-test.md`. The rows that catch real bugs:

- **Two rapid taps** → second suppressed, not queued
- **Background then foreground** → reconnect, nothing sent
- **Mac clock set 5s off** → "Clock mismatch", *not* a generic `expired`
- **VoiceOver activation** → exactly one click
- **Connection dropped after forwarding** → `Unknown` at 4s, never a retry
- **Mac locked** → no click, documented

**Use the Mac's diagnostic post counters, not Octo's on-screen number.** The
counters prove how many `CGEvent.post` calls happened; the UI count only proves
how many Octo noticed. They can disagree, and the disagreement is the finding.

---

## Rung 7 — Benchmark

Rules that make the numbers mean something:

- Latency percentiles from **Posted rows only**; Rejected and Unknown stay in
  the reliability totals
- **Never remove an outlier**
- **Never subtract wall clocks across devices** — use the NTP four-timestamp
  exchange and report the uncertainty
- A subgroup under 100 samples gets median and max, **no p95 claim**
- Keep-warm A/B must **alternate blocks within a session**, not all-off morning
  versus all-on evening

```bash
node relay/scripts/summarize-latency.mjs benchmarks/measurements.csv
```

The summarizer enforces all of the above; its own 15 tests prove it does.

**Keep keep-warm only if,** in both sessions: p95 improves ≥15% *and* ≥20 ms,
reliability doesn't drop, and Unknown/reconnect counts don't rise. Otherwise
delete the code. An unmeasured battery cost is not a feature.

---

## What no rung covers

- **Behaviour over days.** Nothing here tests a socket idle for 8 hours, a
  carrier NAT rebind, or the Mac sleeping and waking.
- **Two phones with the same token.** See the known issue below.
- **Octo-specific input hardening**, if any exists. Rung 4 finds it or it isn't
  there.

---

## Known issue found by probing

The displaced phone's socket closes with **code 1005 (no application code)**, so
`TransportController` cannot distinguish "you were replaced" from "network
dropped" — and it auto-reconnects on any close.

**Two phones holding the same token will displace each other indefinitely**,
each reconnecting and kicking the other off, neither working reliably.

Fix: close the displaced socket with a distinct code (e.g. `4004`), and have the
phone treat `4004` as terminal — show "Another phone took over" and stop
reconnecting until the user acts. Roughly ten lines across `relay.js` and
`transport-controller.js`, plus a test.

This is not covered by any rung above, because every test connects one phone.
