# Click Bridge — Final OCI-First, Low-Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Use the xcodebuildmcp-cli skill for the macOS and iOS build, test, run, and diagnostic steps. Steps use checkbox syntax for tracking.

**Canonical file:** `FINAL-PLAN.md`. `archive/plans/PLAN-v5.md` and earlier plans are preserved as historical inputs only; implementation status and future edits belong here.

**Goal:** While either foreground phone client is active, one accepted user input produces at most one native left mouse click at the Mac's current cursor position within the running-process reliability boundary. The PWA remains the tap fallback; the native iOS client additionally maps each real output-volume delta to one action through the same OCI relay and unchanged phone protocol. An optional measured Tailscale path follows only after both OCI clients pass.

**Architecture:** Milestone 1 uses the foreground PWA, one persistent WebSocket to a stateless Node.js relay on the existing OCI us-sanjose-1 VM, and one persistent WebSocket from that relay to a native Swift menu-bar application. The native iOS extension uses one authenticated WSS connection to that same relay and reuses the exact phone wire protocol, action-ID/expiry rules, heartbeat, reconnect, clock-health, and terminal-result handling. Milestone 2 then adds a Tailscale Serve-backed WebSocket directly into the same Mac action processor; optional hedging sends one immutable action ID over both paths and lets the Mac's serialized processor accept the first arrival.

**Tech Stack:** Foreground HTML/CSS/JavaScript PWA, native iOS SwiftUI, AVAudioSession output-volume KVO, Node.js 24 LTS, ws 8.21.3, Node's built-in test runner, Swift and SwiftUI, URLSessionWebSocketTask, Network.framework, Core Graphics CGEvent, XcodeGen, Docker Compose, Caddy, OCI Compute in us-sanjose-1, and optional Tailscale Serve.

## Global Constraints

- macOS 13 or newer only.
- One phone, one Mac, one user, one OCI relay process.
- The foreground installable PWA remains unchanged and supported as the fallback phone client.
- The native iOS SwiftUI client is an additional foreground-only client and requires a normal signed iPhone build for physical acceptance. Release automation may upload to TestFlight or submit an already processed build for App Store review only through protected manual workflows; it never distributes to testers or releases automatically.
- Production uses a stable public hostname. Prefer a domain you own; DuckDNS is the no-cost fallback. Do not depend on sslip.io or nip.io for the permanent installation.
- The only action is one left click at the Mac's current cursor position.
- Octo Browser is the required physical target for final click verification; the application is not restricted to Octo.
- OCI us-sanjose-1 is the primary relay and phone-page host.
- Deployment requires verified Docker Engine and Compose v2. Ubuntu 22.04/24.04 LTS is the only in-plan installation path. A different OCI OS may continue only when its already-installed Docker Engine, Compose, hello-world run, and reboot persistence all pass; this plan never presents RHEL repository commands as an officially supported Oracle Linux installation.
- The relay is a Docker container behind a Caddy container.
- No PostgreSQL, Redis, database, action history, durable queue, offline action queue, retry, or replay.
- No Windows, Tauri, Electron, Rust, Node desktop receiver, libnut, cliclick, or AppleScript input path.
- No phone-supplied coordinates, cursor movement, keyboard commands, scrolling, dragging, double click, or right click.
- No multiple users, accounts, device enrollment, OIDC, audit system, rate-limit service, or security-hardening project.
- Minimum working protection remains: trusted HTTPS/WSS, three role/path-specific random tokens, a strict click-only protocol, a 4 KiB frame limit, and tokens never placed in URLs or logs.
- The Mac remote-control toggle defaults off.
- The phone never automatically retries an action whose outcome is unknown.
- No end-to-end latency number is treated as fact until measured on the real phone, carrier, OCI instance, Mac, and Octo Browser.
- Cloudflare Durable Objects and Fly.io are not part of this plan.
- Tailscale and simultaneous dual-path delivery begin only after the OCI milestone passes.

### SOLID and design-pattern guardrails

This personal application uses **proportional SOLID**, not framework-driven ceremony:

- **Single responsibility and one owner:** every mutable state, timer, socket generation, request route, runtime gate, and native side effect has exactly one owner.
- **Open/closed:** OCI, direct Tailscale, and later hedged delivery plug into the same small transport/action ports; adding a path must not modify native input execution or protocol semantics.
- **Liskov substitution:** every fake and production adapter obeys the same observable contract, including failure behavior. A binary frame cannot become an empty text frame in one implementation.
- **Interface segregation:** action delivery sees only `name`, `generation`, `ready`, and `send(message)`; it does not receive connection lifecycle, storage, clock-sync, DOM, or benchmark APIs.
- **Dependency inversion:** inject only external or nondeterministic boundaries—WebSocket creation, clocks/timers, random jitter, Keychain, permission checks, Core Graphics construction/posting, and sleep. Domain logic never imports those platform APIs directly.
- Prefer composition and pure functions. Do not use inheritance for transports or UI states.
- Create an abstraction only when it has a production adapter plus a deterministic fake, supports a real second implementation, or prevents two components from owning the same effect.
- Do not optimize for file count or pattern names. Optimize for independently testable behavior and an unchanged hot path.

Required patterns and owners:

| Pattern | Owner | Purpose |
| --- | --- | --- |
| Composition root | Node `server.js`, browser `app.js`, Swift `ClickBridgeApp` | Construct concrete dependencies in one place; domain types do not locate globals |
| Ports and adapters | WebSocket, Keychain, permission, clock/timer, CGEvent boundaries | Deterministic tests and replaceable external mechanisms |
| Pure state machine | PWA `state.js` reducer | One explicit source for user-visible states and legal transitions |
| Native phone ports | iOS `VolumeChangeSource`, `PhoneActionTransport`, `Clock`, `Scheduler`, and `Haptics` | Keep AVAudioSession, URLSession, time, lifecycle races, and feedback outside deterministic domain tests |
| Coordinator | PWA `TransportCoordinator` | One logical action, selected delivery ports, ack/result timeout; no clock or benchmark ownership |
| Volume coordinator | iOS foreground session coordinator | Accept one real output-volume delta only while ready; keep one action in flight and no queue |
| Serialized command handler | Swift `ActionProcessor` actor | Reserve action ID, gate, post synchronously, and cache result atomically |
| Strategy | Small injected transport-selection function | OCI-only, direct-only, or hedged selection without branching inside transports |
| Observer | Narrow callbacks and `@Published` presentation state | Report state changes without a global event bus |

The latency-critical flow stays direct:

~~~text
PWA pointer event -> TransportCoordinator -> selected socket send
iOS output-volume delta -> foreground coordinator -> PhoneActionTransport send
validated Mac ingress -> ActionProcessor actor -> synchronous InputPosting
~~~

No dependency-injection container, service locator, global singleton registry, event bus, generic command/plugin framework, transport subclass hierarchy, cache repository, circuit breaker, or action middleware is allowed. Do not split the `ActionProcessor` critical section across actors or introduce `await` between reservation and terminal-result caching.

---

## 1. Why This Is a Complete Replacement

PLAN-v4 chose Fly.io and explicitly excluded OCI, Docker, Caddy, and Tailscale. This plan replaces those decisions because an existing OCI VM is already available in the exact us-sanjose-1 region.

Current folder facts to preserve during implementation:

- The folder is an initialized Git repository on `main` at scaffold-polish commit `b3d7729`, with initial commit `ab0fc92` in its ancestry. The only working-tree change at this handoff is the updated canonical `FINAL-PLAN.md` produced by this review.
- Partial `contracts/`, `relay/`, `mac/`, `deploy/oci/`, `docs/`, `tests/`, and `archive/` trees already exist. Reconcile them in place through the task tests instead of recreating or silently overwriting them.
- `relay/package.json` currently permits Node 22+ and `ws` with a caret range. A lockfile now exists but reflects that old contract; Task 2 replaces the manifest contract and regenerates the lockfile for exact Node 24 and `ws@8.21.3` inputs.
- Existing fixtures, relay state/server files, PWA files, and tests are incomplete and use duplicated `constants-lite.js`/`protocol-lite.js` parsing. Task 2 introduces the canonical browser-shared parser; Tasks 3 and 4 migrate the existing code and remove the duplicates only after parity tests pass.
- The Swift scaffold uses `mac/project.yml` and already contains partial app, relay-client, action-processor, input, and test files. Task 5 keeps the XcodeGen specification as the project source, generates the missing Xcode project, and Tasks 5 and 6 complete or split the partial types.
- Existing OCI Docker, Compose, Caddy, and deployment documentation are scaffold only. Task 8 replaces the Node 22 image contract and the flat deployment/rollback instructions with the reviewed immutable-release runbook.
- `archive/` contains the historical plans and prototypes, including `archive/plans/PLAN-v5.md`. Do not duplicate them.
- `_to_delete/_impl.tgz` and `_to_delete/_scaffold.tgz` remain as ignored local bundles and are no longer tracked. Keep them out of Docker and release transfer inputs; Task 9 deletes them only after proving they contain no unique source or evidence.
- `archive/plans/PLAN-v5.md` and earlier plans remain historical inputs. FINAL-PLAN.md is the only active implementation plan.

Do not treat any imported file as complete merely because it exists. Preserve the working tree, reconcile each active file through its owning task, and keep historical material outside runtime, build, and deployment inputs.

---

## 2. Delivery Milestones

### Milestone 1 — Complete working application

~~~text
Foreground phone PWA
  pointerdown or accessible click
          |
          | persistent WSS
          v
Existing OCI us-sanjose-1 VM
  Caddy on 80 and 443
  Node relay on private port 8080
          |
          | persistent WSS
          v
Native Swift menu-bar app
  shared ActionProcessor actor
  CGEvent left-down and left-up
          |
          v
Octo Browser at the current cursor
~~~

Milestone 1 is independently usable and remains the PWA/core OCI acceptance gate. It requires no native iOS build or Tailscale installation, but it is no longer the final plan stop: Task 10 must add and physically accept the native iPhone client before final handoff.

### Milestone 2 — Measured lowest-latency path

~~~text
                         +-- Tailscale direct WSS --------+
Phone PWA -- one action -|                                |--> one Mac ActionProcessor --> CGEvent
                         +-- OCI relay WSS ---------------+
~~~

The phone keeps both sockets connected while visible. After the Tailscale path proves faster and the concurrency gate proves at-most-once execution, one press may send the same action ID on both transports. The Mac executes whichever reaches the shared actor first and returns the exact cached result to the later copy.

Milestone 2 improves latency and path resilience after both OCI phone clients pass. Because OCI still hosts the PWA, it is not complete page-load failover when OCI is unavailable.

---

## 3. Product Scope

### Phone experience

~~~text
+----------------------------------+
|  Green dot  Mac ready         Gear|
|                                  |
|        +----------------+        |
|        |                |        |
|        |   CLICK MAC    |        |
|        |                |        |
|        +----------------+        |
|                                  |
|   Clicks at current cursor       |
|   Last: Posted - 74 ms - OCI     |
+----------------------------------+
~~~

The PWA:

- asks for the phone token on first use;
- stays usable only while visible and unlocked;
- disables the action until an authenticated transport reports the Mac ready and the coarse clock-health check passes;
- distinguishes Checking clock, Clock mismatch, and Clock check unavailable so a failed readiness gate never leaves an unexplained disabled button;
- sends on primary pointerdown;
- retains ordinary click activation for keyboard, VoiceOver, and Switch Control;
- consumes the one pointer-generated click that belongs to a handled pointer sequence, regardless of press duration;
- permits one logical action in flight;
- displays Sending, Forwarded, Posted, Rejected, and Unknown distinctly;
- shows Posted only after the Mac returns action.result;
- closes sockets when hidden and reconnects without replay when visible;
- may request Screen Wake Lock after user activation;
- does not claim Wake Lock keeps a mobile radio warm;
- installs to the Home Screen with a manifest and icons;
- contains no offline action behavior.

PWA setup is deliberately small:

1. Open https://CLICK_BRIDGE_DOMAIN in a current mobile browser.
2. Open Settings and enter PHONE_TOKEN once.
3. Add the site to the Home Screen.
4. Launch it from the Home Screen and keep it visible while sending clicks.

The PWA token is its only saved setup. The native client stores the relay WSS URL plus `PHONE_TOKEN`; the token belongs in Keychain and must never enter a URL or log. A second authenticated phone client replaces the first because the product deliberately supports one live phone, so the PWA and native client are fallbacks rather than simultaneous relay sessions.

Production HTTPS is part of the working architecture, not a hardening project. Installable PWAs and Screen Wake Lock rely on a secure context, and an HTTPS page must use WSS. Wake Lock is best-effort: it prevents dimming while granted but does not guarantee foreground scheduling or keep the radio warm. For an installed iPhone Home Screen web app, require iOS/iPadOS 18.4 or newer before offering the Wake Lock toggle; older versions continue without it.

The native iOS client observes `AVAudioSession.sharedInstance().outputVolume` through its supported KVO surface only while the app is foreground-active. Any real upward or downward delta is one click input. Duplicate callback noise, an unchanged value, a held-button repeat while an action is in flight, lifecycle races, and callbacks from stale observer or socket generations send nothing; there is no queue. The UI shows Ready, Not connected, Mac offline, Clock mismatch, and At volume boundary. At 0% or 100%, it explains that the outward direction cannot create another observable delta. Because the API observes output-volume changes rather than the physical source, changes from Control Center, wired or Bluetooth headsets, and AirPods can also trigger. Haptics occur only after the Mac terminal result, never after `relay.ack`.

### Mac experience

The SwiftUI MenuBarExtra shows:

- OCI connection state;
- optional Tailscale-listener state;
- PostEvent permission ready or required;
- Remote control enabled toggle;
- last action result and winning ingress;
- reconnect;
- request permission;
- settings;
- quit.

Settings contain:

- OCI relay URL;
- Mac role token stored in Keychain;
- independent direct token only after Milestone 2 is enabled;
- exact allowed OCI PWA Origin and direct-listener toggle only after Milestone 2 is enabled.

### Octo Browser behavior

The native click is a system Core Graphics event, not an Octo-specific automation API. It lands at the current cursor in whichever application is frontmost. Milestone 1 must physically prove the chosen down/up timing inside the installed Octo Browser using the harmless counter page.

This plan does not add a frontmost-app guard, window inspection, screen capture, or phone coordinates. If a later requirement says clicks must be restricted to Octo, that is a separate scope change.

---

## 4. Reliability Contract

1. One physical activation creates exactly one logical actionId.
2. An actionId is generated before transport selection.
3. The payload is immutable for the lifetime of that action.
4. The relay never persists, retries, batches, or replays actions.
5. The phone never retries after Unknown.
6. Every Mac ingress calls the same ActionProcessor actor.
7. The actor reserves an unseen actionId before any native side effect.
8. No await or suspension occurs between reservation, native posting, and terminal-result caching.
9. A later identical copy receives the exact cached wire result and posts no input; duplicate-delivery metadata remains local to the phone.
10. Reusing an actionId with a different payload returns id_conflict and posts no input.
11. Acknowledgement means transport forwarding only; it never means a click occurred.
12. Posted means the Mac submitted one mouse-down and one mouse-up event. It does not prove Octo completed a higher-level operation.
13. The guarantee is at-most-once execution per actionId while the Mac process and in-memory dedup state remain alive.
14. Absolute exactly-once behavior across a Mac crash is not claimed. No old action is resent after restart.

The completed-action cache retains entries for five minutes and has a safety cap of 4,096 entries. Cleanup never evicts an unexpired or processing entry. If the cache is full of protected entries, new actions fail closed with capacity_exceeded.

---

## 5. Timing Constants

| Constant | Value | Owner | Meaning |
| --- | ---: | --- | --- |
| MAX_MESSAGE_BYTES | 4096 | all | Reject larger WebSocket messages |
| AUTH_TIMEOUT_MS | 5000 | relay and direct server | Time allowed for the first hello |
| HEARTBEAT_INTERVAL_MS | 20000 | clients | Visible authenticated liveness check |
| HEARTBEAT_TIMEOUT_MS | 10000 | clients | Close and reconnect after missing acknowledgement |
| SERVER_PING_INTERVAL_MS | 30000 | relay | WebSocket protocol ping interval |
| SERVER_PONG_TIMEOUT_MS | 10000 | relay | Terminate a socket after its ping misses pong |
| ACTION_LIFETIME_MS | 2000 | phone, relay, Mac | Fixed live-action deadline |
| CLOCK_SKEW_TOLERANCE_MS | 1000 | phone, relay, Mac | Practical allowance for automatically synchronized clocks and the phone readiness gate |
| CLOCK_HEALTH_SAMPLES | 5 | phone | Valid sequential sync exchanges required before Ready |
| CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS | 3500 | phone | Stop a missing-response clock batch after the relay's three-second route lifetime |
| CLOCK_HEALTH_REFRESH_MS | 300000 | phone | Refresh coarse skew readiness while visible |
| RELAY_PENDING_TTL_MS | 3000 | relay | Maximum result-routing state |
| PHONE_RESULT_TIMEOUT_MS | 4000 | phone | Outcome becomes Unknown; never retry |
| PHONE_RECONNECT_CAP_MS | 8000 | phone | Full-jitter reconnect cap |
| MAC_RECONNECT_CAP_MS | 5000 | Mac | Jittered reconnect cap |
| COMPLETED_ACTION_TTL_MS | 300000 | Mac | Duplicate-result retention |
| COMPLETED_ACTION_CAP | 4096 | Mac | Memory safety bound |
| DIRECT_LISTENER_PORT | 8787 | Mac | Loopback WebSocket backend for Tailscale Serve |
| CLICK_GAP_MS | 0 initially | Mac | Calibrate to the smallest value Octo accepts reliably |
| KEEPWARM_INTERVAL_MS | 5000 | phone diagnostics | Experimental and off by default |

HEARTBEAT_INTERVAL_MS and KEEPWARM_INTERVAL_MS are different controls. Heartbeat detects dead application paths. Keep-warm deliberately generates more radio traffic and remains disabled unless the physical A/B benchmark passes.

---

## 6. Wire Protocol

All messages are UTF-8 JSON, maximum 4 KiB, contain v equal to 1, and reject unknown fields. JSON fixtures are the canonical contract used by Node and Swift tests.

### Authentication

Phone to OCI relay:

~~~json
{"type":"hello","v":1,"role":"phone","token":"64-lowercase-hex"}
~~~

Mac to OCI relay:

~~~json
{"type":"hello","v":1,"role":"mac","token":"64-lowercase-hex"}
~~~

Phone to the Milestone 2 direct listener:

~~~json
{"type":"hello","v":1,"role":"phone","token":"64-lowercase-hex"}
~~~

Successful endpoint response:

~~~json
{"type":"hello.ok","v":1,"role":"phone"}
~~~

Generate each token independently with openssl rand -hex 32 when its milestone begins: PHONE_TOKEN and MAC_TOKEN in Task 8, DIRECT_TOKEN only in Task 11. The phone receives PHONE_TOKEN and, only for Milestone 2, DIRECT_TOKEN. The Mac receives MAC_TOKEN and, only for Milestone 2, DIRECT_TOKEN. Tokens are first-message data, never URL query parameters.

### Heartbeat

~~~json
{"type":"heartbeat.request","v":1,"sequence":17}
~~~

~~~json
{"type":"heartbeat.ack","v":1,"sequence":17}
~~~

These messages contain no action and are ignored by action processing.

The phone and Mac each originate heartbeat.request every 20 seconds on their active authenticated sockets. The relay and direct listener reply immediately. A client that does not receive the matching acknowledgement within 10 seconds closes that connection and enters its normal reconnect state. The Node relay additionally uses WebSocket protocol ping/pong to clear dead server-side sockets; browsers reply automatically.

The optional five-second keep-warm experiment sends additional heartbeat.request frames through the same phone-side heartbeat manager. Every probe uses the next unique sequence and receives the normal heartbeat.ack. It does not create a second acknowledgement map, timeout owner, or message type, and it does not cancel the fixed 20-second liveness schedule. When keep-warm is off, only the normal 20-second heartbeat remains.

### Clock health and benchmark alignment

Time synchronization never changes the relay or Mac acceptance calculation, but the phone uses it to detect a clearly mis-set clock before enabling Ready:

~~~json
{"type":"time.sync.request","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":1786497600000.125}
~~~

~~~json
{"type":"time.sync.response","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":1786497600000.125,"macReceiveUnixMs":1786497600031.500,"macSendUnixMs":1786497600031.650}
~~~

The relay always routes valid time-sync messages and never owns a diagnostics-mode flag. Mac ready is necessary but not sufficient for phone Ready. After a fresh Mac-ready state, the phone enters Checking clock and runs five sequential exchanges with one outstanding syncId at a time. All five must return valid responses; the phone chooses the minimum-RTT sample and blocks the action button with "Clock mismatch — enable automatic date and time" when abs(offset) is greater than CLOCK_SKEW_TOLERANCE_MS plus RTT/2. This adds a one-time Mac round trip batch after connection but is never part of an action's hot path.

If any exchange lacks a matching valid response within CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS, abort the batch and enter Clock check unavailable with: "Clock check unavailable — the Mac did not answer. Check the Mac connection, then retry." Show a Retry clock check control that starts a new five-exchange batch only while the transport remains authenticated and the latest Mac state is ready. It retries only synchronization and never creates, retains, or replays an action. A later Mac-not-ready state supersedes this message with the corresponding Mac state. A response for a timed-out syncId or superseded batch is ignored. A malformed inbound frame still follows the global strict-parser close/reconnect rule rather than being relabeled as clock unavailability.

Repeat the five-exchange readiness gate after reconnect, network/visibility change, and every five visible minutes. If a periodic refresh becomes due while an action is in flight, defer it until that action reaches a terminal phone state; then transition from Ready to Checking clock while the new batch runs. Benchmark mode uses the separate 20-exchange schedule in Task 9.

If an action is rejected as expired, the PWA records the latest offset, RTT/2 uncertainty proxy, and sample age beside that rejection. If the recent estimate indicates definite skew, the UI presents Clock mismatch as the likely cause; otherwise it presents Expired. The wire reason remains expired because the relay/Mac cannot distinguish clock error from genuine network delay using the action timestamps alone.

### Diagnostic post counters

The PWA takes a counter snapshot before and after a physical run:

~~~json
{"type":"diagnostics.request","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030ab"}
~~~

~~~json
{"type":"diagnostics.counters","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030ab","mouseDownPostCount":1000,"mouseUpPostCount":1000}
~~~

The counters are cumulative for the current Mac process and increment immediately around the actual CGEvent.post calls. The messages do not create, retry, or acknowledge an action. The relay retains only a three-second request route, and the PWA emits requests only from its visible Diagnostics screen.

### Mac state

Mac to relay:

~~~json
{"type":"mac.state","v":1,"remoteEnabled":true,"permission":"ready"}
~~~

Relay or direct listener to phone:

~~~json
{"type":"state","v":1,"macOnline":true,"remoteEnabled":true,"permission":"ready"}
~~~

permission is ready, required, or unknown. The relay alone authors macOnline for the OCI path. The Mac owns remoteEnabled and permission.

### Action request

~~~json
{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"click","issuedAtUnixMs":1786497600000,"expiresAtUnixMs":1786497602000}
~~~

expiresAtUnixMs must equal issuedAtUnixMs plus ACTION_LIFETIME_MS. The relay and Mac reject a request after expiresAtUnixMs plus CLOCK_SKEW_TOLERANCE_MS. Automatic date and time must be enabled on the phone, OCI VM, and Mac. These wall-clock fields prevent dangerously late clicks; they are not used to calculate reported latency.

### OCI relay acknowledgement

~~~json
{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"forwarded","reason":"ok","relayProcessingUs":140}
~~~

status is forwarded, mac_offline, or rejected. reason is ok, mac_offline, expired, or invalid_request and must match the status. relayProcessingUs is measured entirely on the OCI process's monotonic clock. In OCI-only mode, a non-forwarded acknowledgement is terminal Rejected, never Posted. In hedged mode it is one path's failure and becomes terminal only when no selected path can still return a Mac result.

### Mac terminal result

~~~json
{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"ok","acceptedVia":"oci","macProcessingUs":820,"mouseDownPostedUnixMs":1786497600068.250}
~~~

status is posted or rejected.

Rejection reasons:

~~~text
permission_required
remote_disabled
expired
capacity_exceeded
id_conflict
event_creation_failed
invalid_request
~~~

acceptedVia is oci or tailscale. macProcessingUs uses the Mac's monotonic clock from parsed action receipt through the mouse-up post. mouseDownPostedUnixMs is required only when status is posted and is absent from rejected results. It exists only for benchmark clock alignment. An identical duplicate receives the exact cached original result, including acceptedVia and timestamps; the wire result is not mutated to mark it duplicate.

### Routing rules

- Exactly one authenticated phone socket and one authenticated Mac socket exist at the relay.
- A newly authenticated same-role socket replaces the old socket.
- The closing callback clears a role only if that closing socket is still the current owner.
- Only the phone may send action.request.
- Only the phone may send diagnostics.request or time.sync.request.
- Only the Mac may send mac.state, action.result, diagnostics.counters, or time.sync.response to the relay.
- The relay routes each result only to the current originating phone socket.
- Pending result, diagnostic, and time-sync routes expire after three seconds and disappear on disconnect or restart.
- A pending result owned by a replaced phone socket is never delivered to the replacement phone.
- The relay never fans out.
- Unknown action results are ignored and logged without payload or token data.

---

## 7. Planned Repository Layout

~~~text
clicker/
+-- FINAL-PLAN.md
+-- README.md
+-- .gitignore
+-- .dockerignore
+-- archive/
|   +-- plans/
|   +-- prototypes/
+-- contracts/
|   +-- fixtures/
+-- relay/
|   +-- package.json
|   +-- package-lock.json
|   +-- src/
|   +-- test/
|   +-- scripts/
|   +-- public/
+-- mac/
|   +-- project.yml
|   +-- ClickBridgeMac.xcodeproj/
|   +-- Config/
|   +-- ClickBridgeMac/
|   +-- ClickBridgeMacTests/
+-- ios/
|   +-- project.yml
|   +-- ClickBridgePhone.xcodeproj/
|   +-- ClickBridgePhone/
|   +-- ClickBridgePhoneTests/
+-- deploy/
|   +-- oci/
|       +-- Dockerfile
|       +-- compose.yaml
|       +-- Caddyfile
|       +-- .env.example
+-- tests/
|   +-- manual/
|       +-- click-target.html
|       +-- click-target.css
|       +-- click-target.js
+-- benchmarks/
|   +-- measurements.csv
|   +-- run-evidence.csv
|   +-- README.md
+-- docs/
    +-- preflight.md
    +-- install-macos.md
    +-- benchmark.md
    +-- oci-deployment.md
    +-- oci-recovery.md
    +-- physical-smoke-test.md
    +-- ios-acceptance.md
    +-- latency-report.md
    +-- phase-2-tailscale.md
~~~

Core relay files:

~~~text
relay/src/constants.js
relay/public/wire-protocol.js
relay/src/relay.js
relay/src/server.js
relay/test/protocol.test.js
relay/test/relay.socket.test.js
relay/test/relay.state.test.js
relay/test/assets.test.js
relay/test/browser-parity.test.js
relay/test/phone-state.test.js
relay/test/transport-controller.test.js
relay/test/transport-coordinator.test.js
relay/test/clock-health-controller.test.js
relay/test/phone-settings-store.test.js
relay/test/benchmark-session.test.js
relay/test/latency-summary.test.js
relay/test/negative-matrix.test.js
relay/scripts/smoke-relay.mjs
relay/scripts/run-negative-matrix.mjs
relay/scripts/summarize-latency.mjs
relay/public/index.html
relay/public/styles.css
relay/public/state.js
relay/public/app.js
relay/public/transport-controller.js
relay/public/relay-transport.js
relay/public/transport-coordinator.js
relay/public/clock-health-controller.js
relay/public/phone-settings-store.js
relay/public/benchmark-session.js
relay/public/manifest.webmanifest
relay/public/icons/apple-touch-icon-180.png
relay/public/icons/icon-192.png
relay/public/icons/icon-512.png
~~~

Core Mac files:

~~~text
mac/ClickBridgeMac/ClickBridgeApp.swift
mac/ClickBridgeMac/AppState.swift
mac/ClickBridgeMac/WireMessage.swift
mac/ClickBridgeMac/StrictWireDecoder.swift
mac/ClickBridgeMac/ActionIngress.swift
mac/ClickBridgeMac/RelayClient.swift
mac/ClickBridgeMac/ActionProcessor.swift
mac/ClickBridgeMac/PostEventPermissionService.swift
mac/ClickBridgeMac/MacInputExecutor.swift
mac/ClickBridgeMac/SettingsStore.swift
mac/ClickBridgeMac/KeychainStore.swift
mac/ClickBridgeMac/Info.plist
mac/ClickBridgeMac/Assets.xcassets/
mac/ClickBridgeMacTests/WireMessageTests.swift
mac/ClickBridgeMacTests/RelayClientTests.swift
mac/ClickBridgeMacTests/ActionProcessorTests.swift
mac/ClickBridgeMacTests/PermissionServiceTests.swift
mac/ClickBridgeMacTests/MacInputExecutorTests.swift
mac/ClickBridgeMacTests/SettingsStoreTests.swift
~~~

Core iOS files (Task 10; the generated shared scheme is `ClickBridgePhone`):

~~~text
ios/project.yml
ios/ClickBridgePhone/ClickBridgePhoneApp.swift
ios/ClickBridgePhone/PhoneSessionCoordinator.swift
ios/ClickBridgePhone/AVAudioSessionVolumeChangeSource.swift
ios/ClickBridgePhone/RelayPhoneActionTransport.swift
ios/ClickBridgePhone/PhoneSettingsStore.swift
ios/ClickBridgePhone/KeychainStore.swift
ios/ClickBridgePhone/ContentView.swift
ios/ClickBridgePhoneTests/PhoneSessionCoordinatorTests.swift
ios/ClickBridgePhoneTests/RelayPhoneActionTransportTests.swift
~~~

Milestone 2 adds:

~~~text
relay/public/direct-transport.js
mac/ClickBridgeMac/DirectWebSocketServer.swift
mac/ClickBridgeMacTests/DirectWebSocketServerTests.swift
~~~

Secret files, build output, and generated local configuration are ignored:

~~~gitignore
node_modules/
build/
DerivedData/
.env
deploy/oci/.env
mac/Config/Local.xcconfig
*.dmg
.DS_Store
benchmarks/*.csv
!benchmarks/measurements.csv
!benchmarks/run-evidence.csv
!benchmarks/measurements.example.csv
_to_delete/
~~~

The root .dockerignore excludes at least .git, every .env except .env.example, node_modules, build, DerivedData, archive, `_to_delete`, benchmarks, mac, ios, docs, tests, plan files, and *.dmg. The root build context must never transmit deploy/oci/.env or historical/bundled content to Docker.

---

## 8. Task Dependency Order

~~~text
Task 1 preflight and repository
  -> Task 2 protocol contract
    -> Task 3 relay
      -> Task 4 phone PWA
        -> Task 5 Swift shell and relay client
          -> Task 6 actor, permission, and CGEvent
            -> Task 7 local Octo vertical slice
              -> Task 8 OCI Docker/Caddy deployment
                -> Task 9 physical benchmark, canonical cleanup, and Milestone 1 acceptance
                  -> Task 10 native iOS foreground volume client and physical acceptance
                    +-> stop with both OCI phone clients complete
                    +-> Task 11 Tailscale ingress
                          -> optional Task 12 hedging and comparison
                    -> Task 13 final verification and handoff
~~~

Tasks 1 through 9 produce the complete PWA/core OCI application. Task 10 adds the required native iOS client without changing that fallback. Tasks 11 and 12 are optional latency upgrades, not prerequisites for the two-client OCI clicker.

---

### Task 1: Preflight, Repository, and Canonical Boundaries

**Files:**

- Modify: README.md
- Modify: archive/README.md
- Modify: .gitignore
- Create: .dockerignore
- Create: docs/preflight.md
- Preserve: FINAL-PLAN.md
- Preserve as historical: `archive/plans/PLAN-v5.md` and earlier plan files
- Inspect only: committed imported scaffold, historical archives, `_to_delete/` bundles, and existing OCI instance

**Interfaces:**

- Produces a recorded CPU architecture, OCI public address, domain decision, Mac and Octo versions, and final repository boundary.
- Later deployment tasks consume CLICK_BRIDGE_DOMAIN and the OCI architecture recorded here.

- [ ] **Step 1: Record the local starting state**

Run:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
pwd
git status --short --branch
git log --oneline -3
uname -m
sw_vers
node --version
npm --version
docker version 2>/dev/null || true
docker compose version 2>/dev/null || true
docker buildx version 2>/dev/null || true
~~~

Expected at this handoff: `main` is at `b3d7729`, with `ab0fc92` in its ancestry, and exactly the updated `FINAL-PLAN.md` is modified. If the plan was committed separately before execution, a clean descendant of `b3d7729` is also valid; record the actual HEAD rather than resetting it. At this handoff the Mac has a Docker CLI but no reachable daemon and no Compose plugin; record the fresh result rather than assuming local container validation is available. Record the actual status, commit, Mac architecture, and macOS version in docs/preflight.md. Do not discard or reset imported files. If unrelated changes exist, preserve and record them rather than folding them into this task. Task 2 requires Node 24.x and a compatible npm; install the current Node 24 LTS patch if another major is active.

- [ ] **Step 2: Inspect the existing OCI VM without changing it**

Run through the existing SSH access:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'uname -m; cat /etc/os-release; docker version --format "{{.Server.Arch}}" 2>/dev/null || true; docker compose version 2>/dev/null || true'
~~~

The verified Milestone 1 SSH target is recorded above; update it only after an
instance/address replacement and the corresponding DuckDNS change.

Record:

- OCI region is us-sanjose-1;
- VM shape and amd64 or arm64 architecture;
- operating system;
- Docker and Compose availability;
- current public IPv4 and whether it is ephemeral or reserved;
- public-subnet, Internet Gateway, default route, VNIC, and attached NSG/security-list state;
- current DNS name, if any;
- current OCI NSG or security-list ingress;
- current host-firewall state.

Choose and record CLICK_BRIDGE_DOMAIN here:

- preferred: a subdomain of a domain the user owns;
- no-cost fallback: a dedicated DuckDNS name;
- rejected for permanent use: sslip.io and nip.io shared wildcard hostnames;
- rejected for this plan: bare-IP public TLS, because the stock Caddy flow documented here is hostname-based and adding separate short-lived IP-certificate automation adds unnecessary operations.

Expected: no deployment mutation occurs.

- [ ] **Step 3: Record the physical target**

Record in docs/preflight.md:

- Mac model and macOS version;
- installed Octo Browser version;
- target phone model, OS, and carrier;
- whether Mac networking is wired or Wi-Fi;
- the harmless page that will be used for physical click counting.

- [ ] **Step 4: Reconcile repository boundaries without rewriting the committed baseline**

Verify the committed baseline and current index before staging anything:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
test "$(git rev-parse --show-toplevel)" = "/Users/harshitagarwal/Desktop/clicker"
test "$(git branch --show-current)" = "main"
git merge-base --is-ancestor ab0fc92 HEAD
git cat-file -e 'b3d7729^{commit}'
test -z "$(git diff --cached --name-only)"
WORKTREE_CHANGES="$(git status --porcelain)"
test -z "$WORKTREE_CHANGES" || test "$WORKTREE_CHANGES" = ' M FINAL-PLAN.md'
git diff --check
test -e _to_delete/_impl.tgz
test -e _to_delete/_scaffold.tgz
test -z "$(git ls-files _to_delete)"
git check-ignore -q _to_delete/_impl.tgz
git check-ignore -q _to_delete/_scaffold.tgz
~~~

Do not run `git rm --cached`, reset the index, or rewrite the initial commit. Reconcile `.gitignore` with Section 7. Create a root `.dockerignore` that excludes at least `.git`, `.env` files, `node_modules`, build products, `archive/`, `_to_delete/`, `mac/`, `ios/`, `benchmarks/`, tests, docs, and plan files while leaving the required `relay/package*.json`, `relay/src/`, and `relay/public/` build inputs visible.

Stage only the Task 1 boundary files:

~~~bash
git add .gitignore .dockerignore FINAL-PLAN.md README.md archive/README.md docs/preflight.md
git diff --cached --check
git diff --cached --name-only
~~~

Expected: every staged name is a member of the six-file Task 1 allowlist above; unchanged allowlisted files may be absent. No generated file, secret, implementation scaffold, archive payload, or `_to_delete/` bundle is newly staged. Previously committed files remain untouched unless listed for this task. Staging the reviewed `FINAL-PLAN.md` resolves the one expected handoff modification.

- [ ] **Step 5: Document the delivery boundaries**

README.md must state:

- Tasks 1 through 9 are Milestone 1;
- Task 10 adds the required native iOS foreground client while preserving the PWA fallback and phone wire protocol;
- Tailscale and hedging are not enabled before Milestone 1 passes;
- FINAL-PLAN.md is the only active plan;
- all earlier files are preserved until the mandatory cleanup inside Task 9.

`archive/README.md` must label `archive/plans/PLAN-v5.md` and all other archived content non-authoritative. The root README must distinguish fresh automated evidence from physical acceptance and must not copy old “done” or test-count claims forward without rerunning them.

- [ ] **Step 6: Commit**

~~~bash
git commit -m "docs: establish final click bridge scope"
~~~

---

### Task 2: Protocol Contract and Test Fixtures

**Files:**

- Modify or replace: contracts/fixtures/*.json
- Modify: relay/package.json
- Regenerate: relay/package-lock.json
- Modify: relay/src/constants.js
- Modify or reduce to a re-export: relay/src/protocol.js
- Create: relay/public/wire-protocol.js
- Modify or replace: relay/test/protocol.test.js
- Modify: relay/scripts/check.mjs

**Interfaces:**

- Produces environment-neutral parseClientMessage(raw, role), parseServerMessage(raw, role), and encodeMessage(message); both Node and the PWA import this one browser-safe module.
- Produces canonical JSON fixtures loaded by both Node and Swift tests.
- The request fingerprint is action plus issuedAtUnixMs plus expiresAtUnixMs, encoded deterministically with the action ID excluded.

- [ ] **Step 1: Create the package manifest**

Verify the exact dependency pin before writing the lockfile:

~~~bash
npm view ws@8.21.3 version engines --json
~~~

Expected: version 8.21.3 resolves. Stop and re-evaluate the pin if the registry does not return that exact version.

Use this contract:

~~~json
{
  "name": "click-bridge-relay",
  "private": true,
  "type": "module",
  "engines": {"node": ">=24 <25"},
  "scripts": {
    "start": "node src/server.js",
    "test": "node --test",
    "check": "node scripts/check.mjs && node --test"
  },
  "dependencies": {
    "ws": "8.21.3"
  }
}
~~~

Regenerate the existing lockfile from the exact manifest before using npm ci:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm install --package-lock-only
npm ci
~~~

Expected: package-lock.json changes to the exact `ws@8.21.3` graph, contains no caret range for that direct dependency, and npm ci exits zero.

Node 24 is an intentional LTS pin for this first build. Re-evaluate Node 26 only after it enters LTS and the complete relay test suite passes; do not change runtime majors during Milestone 1 merely because Node 26 is the Current line.

- [ ] **Step 2: Write all canonical fixtures**

Each valid fixture must match Section 6 exactly. Add contracts/fixtures/invalid for oversized, binary-descriptor, malformed, unknown-field, wrong-version, wrong-role, and invalid status/reason cases. Use fixed action IDs and timestamps so Node, browser, and Swift tests consume the same corpus.

Include hello, hello.ok, heartbeat, time-sync request/response, diagnostic request/counters, Mac state, phone state, action request, relay acknowledgement, and every terminal result variant. scripts/check.mjs recursively finds existing .js and .mjs files under src, public, scripts, and test, runs node --check for each file, and skips a directory only when it does not exist.

- [ ] **Step 3: Write failing protocol tests**

Tests must cover:

- every valid fixture;
- malformed JSON;
- non-object JSON;
- missing v;
- wrong version;
- unknown type;
- unknown field;
- wrong role for a message;
- token not exactly 64 lowercase hexadecimal characters;
- invalid UUID;
- any action other than click;
- invalid result status or reason;
- invalid relay acknowledgement status/reason pairing;
- invalid acceptedVia;
- expiresAtUnixMs not exactly ACTION_LIFETIME_MS after issuedAtUnixMs;
- a malformed time-sync request or response;
- a message larger than 4,096 bytes.

Representative test shape:

~~~javascript
test("phone cannot send mac.state", () => {
  assert.throws(
    () => parseClientMessage(JSON.stringify(macStateFixture), "phone"),
    /message_not_allowed_for_role/
  );
});
~~~

- [ ] **Step 4: Run the test and verify failure**

~~~bash
npm test -- --test-name-pattern="phone cannot send mac.state"
~~~

Expected: FAIL because the canonical browser-shared strict parser and exact fixture contract are not yet implemented.

- [ ] **Step 5: Implement the minimal strict parser**

Required signature:

~~~javascript
export function parseClientMessage(raw, authenticatedRole = null) {
  // Return a validated plain object or throw ProtocolError.
}
~~~

parseServerMessage applies the same byte limit and exact-key rules to relay/Mac messages received by the PWA. Do not coerce strings to numbers, ignore unknown fields, or accept unlisted action names.

- [ ] **Step 6: Run the full protocol verification**

~~~bash
npm test
npm run check
~~~

Expected: all protocol tests pass and syntax checking reports no error.

- [ ] **Step 7: Commit**

~~~bash
git add contracts relay/package.json relay/package-lock.json relay/src/constants.js relay/src/protocol.js relay/public/wire-protocol.js relay/test/protocol.test.js relay/scripts/check.mjs
git commit -m "feat: define click bridge wire contract"
~~~

---

### Task 3: Stateless One-Phone, One-Mac Relay

**Files:**

- Modify or replace: relay/src/relay.js
- Modify or replace: relay/src/server.js
- Modify: relay/src/csp.js
- Modify or replace: relay/test/relay.socket.test.js
- Modify or replace: relay/test/relay.state.test.js
- Modify: relay/scripts/smoke-relay.mjs

**Interfaces:**

- HTTP: GET /healthz returns ok, WebSocket upgrade occurs only at /ws, and a static-file handler is tested against an injected temporary fixture until the real PWA exists in Task 4.
- Environment: PHONE_TOKEN, MAC_TOKEN, CLICK_BRIDGE_DOMAIN, and PORT defaulting to 8080.
- `server.js` is the composition root and transport boundary: raw-frame limits, decoding, authentication, strict parsing, encoding, WebSocket lifecycle, and HTTP/static handling live there.
- `RelayState` accepts validated role-specific message objects only and owns one current phone connection, one current Mac connection, latest Mac state, temporary actionId-to-phone routes, and three-second time-sync/diagnostic routes. It never imports `ws` or the wire parser.

- [ ] **Step 1: Write failing integration tests**

Cover:

- startup fails when either token is missing or malformed;
- startup fails when CLICK_BRIDGE_DOMAIN is missing or not a bare valid hostname;
- upgrade path other than /ws is rejected;
- hello timeout;
- wrong token and wrong-role token;
- same-role replacement;
- old-socket close cannot clear the replacement socket;
- Mac state propagation;
- Mac disconnect sets macOnline false;
- mac_offline acknowledgement;
- one request forwarded to exactly one Mac;
- relay acknowledgement remains distinct from action result;
- result routing to the originating current phone;
- a result for a route owned by a replaced phone is never delivered to its replacement;
- pending route expiry;
- action expiry before forwarding;
- benchmark time-sync request/response forwarding and expiry;
- diagnostic request/counter forwarding and expiry;
- heartbeat acknowledgement;
- every static response carries the canonical Content-Security-Policy and forbids inline script/style;
- invalid post-authentication message causes no side effect and leaves the socket usable;
- oversized frame close;
- process restart has no route and no replay.
- `relay.state.test.js` supplies validated objects plus fake emitter/scheduler/clock dependencies and never constructs a WebSocket;
- `relay.socket.test.js` proves each raw frame is parsed exactly once and then dispatched to exactly one role method;
- parser failures never call `RelayState`, and RelayState tests contain no parser assertions.

- [ ] **Step 2: Run one targeted test and verify failure**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test -- --test-name-pattern="old socket cannot clear replacement"
~~~

Expected: FAIL on the new replacement/boundary assertion because the imported relay has not yet proven the validated-object ownership contract.

- [ ] **Step 3: Implement the relay state object**

Required ownership shape:

~~~javascript
export class RelayState {
  constructor({now, schedule, cancel, emit, log}) {}

  replaceRole(role, connection) {}
  detachIfCurrent(role, connection) {}
  handlePhoneMessage(connection, validatedMessage) {}
  handleMacMessage(connection, validatedMessage) {}
}
~~~

`connection` is a small relay-owned handle or ID plus an injected `emit` target, not a `ws` instance exposed to domain logic. All pending timers are created/cancelled through injected functions and cleared when their entry is removed. `now`, scheduler, emitter, and structured redacted logger have deterministic fakes. No request body is persisted outside memory.

- [ ] **Step 4: Implement the HTTP and WebSocket server**

Requirements:

- keep `server.js` as the only composition root; export separately testable HTTP-handler and WebSocket-attachment functions rather than adding a framework or transport class hierarchy;
- serve only known static files with explicit MIME types;
- GET /healthz returns status 200 and body ok;
- emit the canonical CSP from the relay static handler so localhost and production enforce the same policy;
- authenticate from the first WebSocket message within five seconds;
- compare tokens with a constant-time byte comparison;
- set the underlying TCP socket to no-delay when available;
- enforce maxPayload at 4,096 bytes in ws;
- reply to valid application heartbeat messages from both clients;
- send WebSocket protocol ping frames on a separate server-side liveness interval and terminate sockets that miss pong;
- reject expired actions before forwarding and never create a pending route for them;
- route valid time-sync and diagnostic messages live without a relay mode flag; the PWA emits time-sync for clock health/benchmarking and emits counter requests only from its local Diagnostics screen;
- ignore a strictly rejected post-authentication frame, log only its error code, and keep the socket open; invalid authentication and oversized frames still close;
- never log token values or complete hello payloads.

The transport boundary performs: bytes/frame -> strict role parser -> validated object -> one RelayState role method -> encoded output. RelayState never reparses, encodes, reads environment variables, or attaches socket listeners.

Canonical CSP:

~~~text
default-src 'self'; connect-src 'self' wss://CLICK_BRIDGE_DOMAIN wss://*.ts.net ws://127.0.0.1:* ws://localhost:*; img-src 'self'; style-src 'self'; script-src 'self'; manifest-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'
~~~

CLICK_BRIDGE_DOMAIN contains only the hostname, never a scheme, port, slash, or header-controlled value. Caddy preserves this application header and does not define a second copy.

- [ ] **Step 5: Implement the end-to-end relay smoke script**

The script opens one phone and one Mac socket, authenticates both, publishes ready state, completes one time-sync exchange and one diagnostic-counter exchange, sends one unexpired action, verifies relay.ack, returns action.result, and asserts that a second Mac never receives the request.

- [ ] **Step 6: Verify**

Terminal one:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
PHONE_TOKEN=1111111111111111111111111111111111111111111111111111111111111111 MAC_TOKEN=2222222222222222222222222222222222222222222222222222222222222222 CLICK_BRIDGE_DOMAIN=localhost npm start
~~~

The two fixed 64-hex values are test-only and must never be reused in deployment.

Terminal two:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
PHONE_TOKEN=1111111111111111111111111111111111111111111111111111111111111111 MAC_TOKEN=2222222222222222222222222222222222222222222222222222222222222222 CLICK_BRIDGE_DOMAIN=localhost node scripts/smoke-relay.mjs ws://127.0.0.1:8080/ws
~~~

Expected: one forwarded request, one terminal result, zero replay.

- [ ] **Step 7: Commit**

~~~bash
git add relay/src relay/test/relay.socket.test.js relay/test/relay.state.test.js relay/scripts/smoke-relay.mjs
git commit -m "feat: add stateless websocket relay"
~~~

---

### Task 4: Foreground Installable Phone PWA

**Files:**

- Modify or replace: relay/public/index.html
- Modify or replace: relay/public/styles.css
- Modify or replace: relay/public/state.js
- Modify or replace: relay/public/app.js
- Modify or replace: relay/public/transport-controller.js
- Create: relay/public/relay-transport.js
- Modify or replace: relay/public/transport-coordinator.js
- Create: relay/public/clock-health-controller.js
- Create: relay/public/phone-settings-store.js
- Modify or replace: relay/public/manifest.webmanifest
- Create: relay/public/icons/apple-touch-icon-180.png
- Verify or replace: relay/public/icons/icon-192.png
- Verify or replace: relay/public/icons/icon-512.png
- Remove after parity passes: relay/public/constants-lite.js
- Remove after parity passes: relay/public/protocol-lite.js
- Modify or replace: relay/test/assets.test.js
- Modify or replace: relay/test/browser-parity.test.js
- Modify or replace: relay/test/phone-state.test.js
- Create: relay/test/transport-controller.test.js
- Create: relay/test/transport-coordinator.test.js
- Create: relay/test/clock-health-controller.test.js
- Create: relay/test/phone-settings-store.test.js

**Interfaces:**

- createActionRequest() returns one immutable action.request with crypto.randomUUID() and a fixed two-second expiry.
- TransportController owns exactly one WebSocket generation, reconnect/backoff, normal heartbeat, optional keep-warm cadence, authentication, and strict inbound validation; it owns no logical action or clock-health state.
- TransportCoordinator owns the single pending logical action, selected delivery strategy, ack/result handling, and result timeout. It remains the action owner when a second transport is added and owns no clock-health, benchmark, storage, DOM, wake-lock, or socket-lifecycle behavior.
- ClockHealthController owns sequential time-sync exchanges, timeout, minimum-RTT selection, retry, five-minute refresh, and stale-generation isolation. It cannot create or replay an action.
- PhoneSettingsStore is the localStorage adapter for token and keep-warm preference. It contains no DOM or socket logic and has a memory fake.
- The pure reducer owns all user-visible button and status states.
- app.js is the browser composition root plus DOM/page lifecycle wiring; it constructs these owners and does not reimplement their decisions.

- [ ] **Step 1: Write failing reducer tests**

Test every product state:

- missing token;
- connecting;
- Mac offline;
- remote disabled;
- permission required;
- checking clock;
- clock mismatch;
- clock check unavailable;
- ready;
- sending;
- forwarded;
- posted;
- rejected;
- unknown;
- hidden.

Also test:

- a short primary pointerdown followed by its click produces one action;
- a two-second held pointerdown followed by its click still produces one action;
- pointercancel clears the matching sequence without creating another action;
- a keyboard or assistive click with no pointer sequence remains usable;
- keyboard click without pointerdown produces one action;
- second activation while pending produces no request;
- relay.ack cannot produce Posted;
- relay.ack with mac_offline or rejected produces terminal Rejected with actionable reason;
- result timeout becomes Unknown;
- hidden clears ready state and marks an in-flight result Unknown;
- visible reconnect creates no action.
- button remains disabled until five valid clock-health responses pass after a fresh Mac-ready state.
- the minimum-RTT response is selected from five fixed valid samples, not the last response or their average.
- fake-clock tests hold a missing response at CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS minus 1 ms in Checking clock and transition at the exact timeout to Clock check unavailable.
- a missing matching response transitions from Checking clock to Clock check unavailable within CLOCK_HEALTH_EXCHANGE_TIMEOUT_MS, exposes Retry clock check, and never sends an action.
- Retry clock check starts only a fresh five-exchange sync batch; a successful retry reaches Ready and a later Mac-not-ready state supersedes the clock-unavailable copy.
- a late response from the timed-out or superseded batch cannot change Clock check unavailable or satisfy the new retry batch.
- an idle five-minute refresh transitions Ready to Checking clock and returns to Ready only after five new valid responses.
- a refresh becoming due during an in-flight action waits for that action's terminal phone state, does not alter its result timer, and then starts the clock-only batch.
- a malformed clock-health frame follows strict-parser transport closure and reconnect rather than being shown as skew or timeout.
- expired rejection exports the latest offset, uncertainty proxy, and sample age without changing the wire reason.
- Posted, Rejected, and Unknown are absorbing for that action; late acknowledgements or results cannot regress or replace them.
- keep-warm off still retains the normal 20-second heartbeat.
- keep-warm on emits extra heartbeat.request sequences through the same manager without creating a second liveness timeout.
- an intentional hidden close cannot schedule a reconnect.
- Unknown displays "Click may have occurred; check the Mac before trying again."
- oversized, binary, unknown-field, wrong-version, and wrong-role inbound messages cause no state transition or action and close that transport into normal backoff.
- index.html contains no inline script, style, or event-handler attribute and passes under the relay's canonical CSP.

Place reducer/view assertions in `phone-state.test.js`, socket/timer assertions in `transport-controller.test.js`, logical-action assertions in `transport-coordinator.test.js`, sync/refresh assertions in `clock-health-controller.test.js`, and storage-failure assertions in `phone-settings-store.test.js`. Tests must not reach through one owner to mutate another owner's private state.

- [ ] **Step 2: Run and verify the first failure**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test -- --test-name-pattern="relay ack cannot produce Posted"
~~~

Expected: FAIL because the imported PWA does not yet satisfy the new action-only coordinator, separate clock owner, and complete terminal-state contract.

- [ ] **Step 3: Implement the transport controller**

Required public surface:

~~~javascript
export class TransportController {
  constructor({url, token, role, createSocket, clock, scheduler, random, onMessage, onStatus}) {}
  connect() {}
  close(reason) {}
  send(message) {}
  get state() {}
  get generation() {}
  get ready() {}
  setKeepWarm(enabled) {}
}
~~~

Rules:

- derive OCI WSS from the current HTTPS origin;
- permit ws only when the controller itself is loaded from http://127.0.0.1 or http://localhost for the Task 7 desktop simulator;
- authenticate in hello, never the URL;
- reconnect with full jitter from 250 ms through an 8 s cap;
- use a generation counter so callbacks from old sockets do nothing;
- send heartbeat.request every 20 seconds only while visible;
- require heartbeat.ack within 10 seconds;
- stop all timers on hidden or pagehide;
- close the socket on hidden;
- set an explicit suspended-by-visibility gate before the hidden close so close/error callbacks cannot reconnect;
- clear that gate and reconnect on visible, pageshow, or online;
- never retain, regenerate, retry, or replay an action.
- own both the normal 20-second heartbeat and optional five-second keep-warm sequence allocation so there is one heartbeat manager and one liveness timeout;
- expose immutable status/generation notifications rather than its socket or timers.

TransportCoordinator accepts a transport port with only `{name, generation, ready, send(message)}` and an injected selection function. It creates the immutable action, sends it through the selected ready port(s), owns the four-second result timer, and routes ack/result events to the reducer. OCI-only selection is the Milestone 1 strategy; direct-only and hedged selection arrive later without subclassing or changing transport internals.

ClockHealthController accepts `sendSync`, generation access, clock, scheduler, ID generator, and reducer dispatch. After a fresh Mac-ready state it owns the sequential five-exchange gate, per-exchange timeout, explicit unavailable state, manual sync-only retry, and five-minute refresh. It permits only one outstanding syncId and cancels the batch on generation change. A refresh that becomes due during an action observes the action coordinator's public busy/terminal signal; it never owns or alters the action result timer.

Every inbound text frame passes through `parseServerMessage` inside TransportController before dispatch. Binary or invalid frames close that transport generation and produce no UI/action side effect. Neither coordinator parses wire text, owns WebSockets, or directly mutates terminal UI state.

Migrate all browser protocol users to `wire-protocol.js`. Keep `constants-lite.js` and `protocol-lite.js` only long enough to prove browser/Node parity, then delete both in this task so production has one parser contract.

- [ ] **Step 4: Implement accessible low-latency activation**

Use a semantic button. A primary pointerdown records performance.now(), sends once, and arms a one-shot record containing pointerId, pointerType, and button. Keep that record across action completion until the related click, pointercancel, visibility loss, or a new primary pointer sequence. Consume the corresponding pointer-generated click by matching pointerId when exposed, otherwise by pointer source semantics such as nonzero detail/pointerType; do not use a fixed time window. Never consume a keyboard or assistive click with detail zero and no handled pointer source. pointercancel clears the matching sequence and never sends another action.

Required CSS includes:

~~~css
body {
  touch-action: manipulation;
}

#click-button {
  min-height: 45vh;
  width: min(88vw, 32rem);
}
~~~

Do not disable page zoom.

- [ ] **Step 5: Implement visibility and wake-lock behavior**

On hidden:

- disable the button immediately;
- close transport;
- release wake lock;
- stop heartbeat and keep-warm;
- mark an in-flight result Unknown.

On visible:

- clear stale state;
- reconnect;
- reacquire wake lock only when feature-detected, supported, and permitted;
- wait for fresh Mac state and a successful five-exchange clock check before enabling.

While Clock check unavailable, keep the action button disabled, show the exact failure copy from Section 6, and expose Retry clock check. Do not imply that the clock is skewed when the Mac simply failed to answer.

PHONE_TOKEN is stored in localStorage for this personal app. Settings must show replace-token and clear-token actions without echoing the stored token. Clearing it immediately closes the socket and returns to missing-token state.

The five-second keep-warm control exists only inside a Diagnostics section, defaults off, runs only while visible and authenticated, and never replaces the 20-second heartbeat. app.js changes the persisted preference and tells TransportController to update its cadence; app.js does not create a heartbeat timer.

- [ ] **Step 6: Add installation assets and explicit install guidance**

The manifest includes name or short_name, display standalone, start_url "/", scope "/", theme colors, 192/512 icons, and an Apple touch icon. Add apple-mobile-web-app-capable, apple-mobile-web-app-title, and theme-color metadata. Do not add a service worker in Milestone 1.

Show short platform instructions instead of depending on beforeinstallprompt: iOS/iPadOS 16.4 or newer uses the browser Share menu and Add to Home Screen; Android uses its browser's Install/Add to Home Screen action. On iOS/iPadOS below 18.4, show Wake Lock unavailable and keep the click flow otherwise usable.

- [ ] **Step 7: Verify**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test
npm run check
~~~

Manual browser checks:

- one touch produces one request;
- keyboard activation produces one request;
- VoiceOver or Switch Control activation while Ready produces exactly one request;
- each accessible activation still produces no duplicate request;
- Posted appears only after action.result;
- background then foreground reconnects without sending;
- fresh Mac ready first shows Checking clock, five valid responses reach Ready, and no action is sent by the check;
- withholding one response produces the actionable Clock check unavailable state rather than Clock mismatch or an indefinitely disabled button;
- Retry clock check reaches Ready after five valid responses;
- the Home Screen icon is correct and launch opens in standalone presentation;
- Wake Lock is hidden/unavailable below iOS/iPadOS 18.4 and re-requested after visibility return when supported.
- the browser console has no CSP violation and disabling/removing any external JS or CSS asset visibly fails rather than falling back to inline code.

- [ ] **Step 8: Commit**

~~~bash
git add -A relay/public relay/test/assets.test.js relay/test/browser-parity.test.js relay/test/phone-state.test.js relay/test/transport-controller.test.js relay/test/transport-coordinator.test.js relay/test/clock-health-controller.test.js relay/test/phone-settings-store.test.js
git commit -m "feat: add foreground click controller pwa"
~~~

---

### Task 5: Native SwiftUI Shell and OCI Relay Client

**Files:**

- Modify: mac/project.yml
- Generate and verify: mac/ClickBridgeMac.xcodeproj
- Modify: mac/Config/Local.xcconfig.example
- Modify: mac/ClickBridgeMac/ClickBridgeApp.swift
- Create: mac/ClickBridgeMac/AppState.swift
- Modify: mac/ClickBridgeMac/WireMessage.swift
- Create: mac/ClickBridgeMac/StrictWireDecoder.swift
- Create: mac/ClickBridgeMac/ActionIngress.swift
- Modify or replace: mac/ClickBridgeMac/RelayClient.swift
- Modify or split: mac/ClickBridgeMac/SettingsStore.swift
- Create: mac/ClickBridgeMac/KeychainStore.swift
- Modify or replace: mac/ClickBridgeMacTests/WireMessageTests.swift
- Create: mac/ClickBridgeMacTests/RelayClientTests.swift
- Create: mac/ClickBridgeMacTests/SettingsStoreTests.swift

**Interfaces:**

- RelayClient is the only OCI socket owner.
- RelayClient depends on `any ActionRequestSink`, never concrete `ActionProcessor`; ActionIngress identifies oci or tailscale and accompanies each validated request through that port.
- URLSession, Keychain, UserDefaults, clocks/sleep, random jitter, and UI state remain behind narrow injected adapters or closures.
- No input event is posted in this task.

- [ ] **Step 1: Complete the existing XcodeGen project**

Requirements:

- macOS 13 deployment target;
- SwiftUI application with MenuBarExtra and Settings;
- shared ClickBridgeMac scheme;
- stable bundle identifier;
- test target;
- App Sandbox disabled;
- no entitlements file;
- deterministic checked-in ad-hoc signing defaults for a buildable personal app;
- optional stable Apple Development identity imported only from ignored Local.xcconfig when present.

The checked-in project uses manual signing, CODE_SIGN_IDENTITY set to "-", and no development team. Local.xcconfig.example documents DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY overrides for an Apple Development certificate. The app path and bundle identifier remain stable in either mode.

Keep `mac/project.yml` as the reviewed project source. Verify `xcodegen --version`, update the specification for every source/resource/test file in this plan, run `xcodegen generate --spec project.yml` from `mac/`, and inspect the generated `ClickBridgeMac.xcodeproj` before running any `xcodebuild` command. Commit the specification and generated project together so a fresh checkout is buildable even before regeneration.

`ClickBridgeApp` is the composition root. In Task 5 it constructs the production SettingsStore/Keychain adapter, URLSession transport factory, RelayClient, and AppState, but injects `RejectingActionSink` and `ZeroDiagnosticCounterReader` no-input adapters so this milestone cannot post input. AppState receives dependencies through its initializer and owns presentation orchestration only; it does not instantiate platform adapters internally or act as a service locator. Task 6 replaces those two adapters at the composition root with one production ActionProcessor that implements both ports, backed by PostEventPermissionService and MacInputExecutor.

- [ ] **Step 2: Add fixture decoding tests**

Copy both valid and invalid contracts/fixtures into the test target as resources. Each valid fixture must decode and re-encode without semantic change. Each invalid fixture must be rejected.

Representative interface:

~~~swift
enum WireMessage: Equatable, Codable {
    case hello(Hello)
    case helloOK(HelloOK)
    case heartbeatRequest(HeartbeatRequest)
    case heartbeatAck(HeartbeatAck)
    case timeSyncRequest(TimeSyncRequest)
    case timeSyncResponse(TimeSyncResponse)
    case diagnosticsRequest(DiagnosticsRequest)
    case diagnosticsCounters(DiagnosticsCounters)
    case macState(MacState)
    case state(PhoneState)
    case actionRequest(ActionRequest)
    case relayAck(RelayAck)
    case actionResult(ActionResult)
}
~~~

StrictWireDecoder checks UTF-8 byte count before JSON parsing, rejects binary frames, validates exact allowed keys for the selected message type and role, and only then decodes WireMessage. Do not rely on Codable's default unknown-key behavior.

- [ ] **Step 3: Run and verify failure**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
~~~

Expected: fixture tests fail until WireMessage is implemented.

- [ ] **Step 4: Implement the injected socket boundary**

Required interfaces:

~~~swift
protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

protocol ActionRequestSink: Sendable {
    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult
}

protocol DiagnosticCounterReading: Sendable {
    func diagnosticPostCounts() async -> InputPostCounts
}

struct InputPostCounts: Sendable, Equatable {
    let mouseDownPostCount: Int
    let mouseUpPostCount: Int
}
~~~

`RejectingActionSink` returns an existing valid rejection such as `remote_disabled` and never touches Core Graphics; do not add a new wire reason merely for the scaffold milestone. `ZeroDiagnosticCounterReader` returns zero counters. RelayClient tests prove an incoming action reaches the adapter and produces no platform call. These types are removed from the production composition in Task 6; they are not a second action implementation.

During Task 5, AppState forces the advertised MacState to `remoteEnabled: false`, disables the remote-control toggle with copy explaining that native input is installed in Task 6, and ignores any persisted true preference for runtime/advertising purposes. Therefore the phone cannot become Ready while the no-input adapter is installed. Task 6 enables the toggle only after production ActionProcessor wiring and its permission/input tests pass, then applies the persisted preference through the actor-owned gate.

Production uses a URLSessionWebSocketTask adapter with text frames only. Binary receipt throws a typed transport error; returning an empty string for binary is prohibited. A binary, oversized, or strictly invalid inbound frame closes that relay generation and enters normal reconnect backoff without posting input. Tests use a deterministic fake.

RelayClient receives `any ActionRequestSink` and a separate `any DiagnosticCounterReading`, plus injected transport construction, sleep/backoff, jitter, and wall-clock sampling closures. Action delivery never gains diagnostic methods merely for convenience. Use closures rather than a clock/factory class hierarchy. The default closures call the real platform APIs; tests control time and randomness without sleeping.

- [ ] **Step 5: Implement one reconnect owner**

RelayClient must:

- validate the saved relay URL as wss with path /ws, no user information, query, or fragment;
- allow ws only for localhost or 127.0.0.1 when the explicit local-simulator option is enabled;
- authenticate before connected becomes true;
- keep exactly one receive loop;
- keep exactly one reconnect task;
- use jittered backoff capped at five seconds;
- cancel the old generation before Save or Reconnect starts a new one;
- retain the latest immutable MacState snapshot supplied through `updateAdvertisedState(_:)` and publish it after hello.ok or snapshot changes; never call a MainActor-backed provider closure from the actor;
- originate heartbeat.request every 20 seconds after authentication;
- close and reconnect when its matching heartbeat.ack is not received within 10 seconds;
- reply to clock-health and benchmark time-sync requests immediately using wall-clock receipt/send samples without blocking the action actor;
- answer diagnostics.request through DiagnosticCounterReading and serialize the returned snapshot;
- never resend an action.

RelayClientTests use an injected fake clock to prove one heartbeat owner, acknowledgement cancellation, timeout reconnect, stale-generation isolation, no heartbeat while disconnected, public plaintext URL rejection, and explicit loopback-only simulator allowance. StrictWireDecoder tests prove the 4 KiB limit and exact-key rejection independently of the Node tests.

- [ ] **Step 6: Implement storage and UI state**

- `SettingsStore` and `AppState` are `@MainActor`; neither uses `@unchecked Sendable`;
- relay URL and the persisted remoteEnabled preference live in injected UserDefaults;
- MAC_TOKEN lives behind an injected `SecretStoring` port implemented by KeychainStore;
- `SecretStoring` exposes throwing read/write/delete operations so Security API failures reach actionable UI state instead of disappearing;
- remoteEnabled defaults false only when no stored value exists;
- menu shows connection, permission, toggle, last result, reconnect, settings, permission action, and quit.

Required storage port:

~~~swift
protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}
~~~

SettingsStoreTests use isolated UserDefaults plus a fake SecretStoring adapter to prove stored-false preservation, URL persistence, token save/clear, and visible Keychain read/write/delete failures.

- [ ] **Step 7: Verify**

~~~bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
~~~

Expected: protocol and relay-client tests pass; the app connects and publishes state but cannot click.

- [ ] **Step 8: Commit**

~~~bash
git add mac
git commit -m "feat: add native mac relay client"
~~~

---

### Task 6: Serialized Deduplication, Permission, and CGEvent

**Files:**

- Modify or replace: mac/ClickBridgeMac/ActionProcessor.swift
- Create: mac/ClickBridgeMac/PostEventPermissionService.swift
- Modify or replace: mac/ClickBridgeMac/MacInputExecutor.swift
- Modify or replace: mac/ClickBridgeMacTests/ActionProcessorTests.swift
- Create: mac/ClickBridgeMacTests/PermissionServiceTests.swift
- Create: mac/ClickBridgeMacTests/MacInputExecutorTests.swift

**Interfaces:**

- ActionProcessor is the only authority allowed to call InputPosting.
- ActionProcessor also owns the live remoteEnabled execution gate. SettingsStore owns only the persisted preference, and RelayClient holds only the last advertised immutable snapshot.
- InputPosting is synchronous so the actor never suspends inside the reserve-to-result critical section.
- PostEventPermissionChecking wraps the Core Graphics permission functions.

- [ ] **Step 1: Write the actor concurrency tests first**

Required protocol:

~~~swift
protocol InputPosting: Sendable {
    func postLeftClickAtCurrentCursor() -> InputPostOutcome
    func diagnosticPostCounts() -> InputPostCounts
}

protocol PostEventPermissionChecking: Sendable {
    func isGranted() -> Bool
}

actor ActionProcessor: ActionRequestSink, DiagnosticCounterReading {
    func setRemoteEnabled(_ enabled: Bool)

    func receive(
        _ request: ActionRequest,
        via ingress: ActionIngress
    ) async -> ActionResult

    func diagnosticPostCounts() -> InputPostCounts
}
~~~

ActionProcessor receives `any InputPosting` and `any PostEventPermissionChecking` through its initializer. Tests inject deterministic fakes for both; the actor never calls the permission prompt API.

Tests:

- valid request posts once;
- remote disabled posts zero times;
- permission missing posts zero times;
- event construction failure posts zero times;
- counter snapshot starts at zero and reflects the exact number of actual down/up post calls;
- completed duplicate returns the exact cached wire result;
- same ID with different payload returns id_conflict;
- expired request posts zero times;
- a cache full of protected entries rejects a new ID with capacity_exceeded;
- 1,000 concurrent identical requests split across fake OCI and direct ingress call the fake poster once;
- distinct IDs each post once;
- cache cleanup respects TTL and cap;
- no in-flight entry is evicted;
- cancellation of one caller does not cause a second execution.
- runtime remoteEnabled starts false, changes only through the actor method, and a request racing a toggle is serialized against that update;
- AppState publishes `remoteEnabled: true` only after `setRemoteEnabled(true)` completes, so advertised and enforced state cannot disagree;
- RelayClient reconnect republishes its cached snapshot without reading SettingsStore across actors.

- [ ] **Step 2: Verify the concurrency test fails**

~~~bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' -only-testing:ClickBridgeMacTests/ActionProcessorTests test
~~~

Expected: FAIL because the imported partial ActionProcessor does not yet satisfy the complete actor-owned gate, deduplication, and diagnostic contract.

- [ ] **Step 3: Implement the non-reentrant critical path**

Algorithm:

1. Validate the click-only request, exact lifetime relation, and current expiry; compute its fingerprint.
2. Remove completed entries older than five minutes.
3. If an entry exists with another fingerprint, return id_conflict.
4. If a completed identical entry exists, return the exact cached ActionResult without changing any field.
5. If every cache slot is protected by an unexpired or processing entry, return capacity_exceeded.
6. Insert processing state before checking permission or posting.
7. Check the actor-owned remoteEnabled value.
8. Check PostEvent permission.
9. Call the synchronous input poster at most once.
10. Replace processing with the terminal result before returning.
11. Never await between steps 6 and 10.

SettingsStore remains the persisted preference adapter, not a runtime dependency of the action actor. On launch and every menu toggle, AppState awaits `processor.setRemoteEnabled(value)`, then creates one immutable MacState snapshot and gives it to RelayClient. Remove `RemoteToggleReading`, MainActor `assumeIsolated`, cross-actor `@Published` reads, and any duplicated live-gate boolean outside ActionProcessor.

At the start of Task 6, update ClickBridgeApp's composition root to construct PostEventPermissionService, MacInputExecutor, and the single ActionProcessor; inject that same actor separately as ActionRequestSink and DiagnosticCounterReading. Remove the Task 5 rejecting/zero stubs from the production wiring before the first physical click test.

- [ ] **Step 4: Implement the correct permission API**

~~~swift
struct PostEventPermissionService: PostEventPermissionChecking {
    func isGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    func requestFromUserAction() -> Bool {
        CGRequestPostEventAccess()
    }
}
~~~

Request permission only when the user chooses the menu action. Refresh state on app activation, menu display, after a request, and immediately before posting.

`isGranted()` satisfies the domain-facing permission-check port. `requestFromUserAction()` remains a concrete UI capability called only by AppState from the explicit menu action; do not widen the ActionProcessor port to include prompting.

- [ ] **Step 5: Implement native input creation**

MacInputExecutor must:

- read the current Core Graphics cursor location;
- create both leftMouseDown and leftMouseUp before posting either;
- use the same location and left button;
- set mouseEventClickState to 1 on both;
- post through cghidEventTap;
- use the named CLICK_GAP_MS between down and up;
- return event_creation_failed without posting if either event cannot be created;
- increment in-memory mouse-down and mouse-up counters immediately around the actual post calls;
- return counter snapshots only through ActionProcessor so posting and snapshots remain serialized;
- never spawn a process or use a third-party native-input package.

Inject only three synchronous platform closures: event construction, event posting, and gap sleeping. Production closures call Core Graphics and the selected microsecond sleep; tests use recording fakes. Do not create another actor, input-command hierarchy, or dedup repository. MacInputExecutorTests prove both events are constructed before either post, construction failure posts zero, order is down then up, the configured gap is requested once, and counters surround the actual post calls.

- [ ] **Step 6: Verify**

~~~bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
~~~

Expected: all action, permission, input, socket, and fixture tests pass.

- [ ] **Step 7: Commit**

~~~bash
git add mac/ClickBridgeMac mac/ClickBridgeMacTests
git commit -m "feat: add atomic native click execution"
~~~

---

### Task 7: Local Desktop Simulator and Octo Calibration

**Files:**

- Modify or replace: tests/manual/click-target.html
- Modify or replace: tests/manual/click-target.css
- Modify or replace: tests/manual/click-target.js
- Create: docs/install-macos.md
- Rename and rewrite: docs/smoke-test.md to docs/physical-smoke-test.md

**Interfaces:**

- click-target.html exposes a visible count incremented by one normal click.
- The chosen CLICK_GAP_MS is recorded with the exact Octo and macOS versions.

- [ ] **Step 1: Create the harmless target**

The page contains one large button and a visible integer count. Each DOM click increments the count exactly once. It contains no network calls.

- [ ] **Step 2: Build and verify the Release app**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -configuration Release -derivedDataPath build build
codesign --verify --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements :- build/Build/Products/Release/ClickBridgeMac.app
~~~

Expected: signature verification succeeds and App Sandbox is absent.

Prefer a stable Apple Development identity configured through ignored Local.xcconfig. If only ad-hoc signing is available, document that rebuilding may require the PostEvent permission to be granted again.

- [ ] **Step 3: Install before granting permission**

Copy the exact Release build to /Applications/ClickBridgeMac.app. Launch it, choose Request Permission, grant Accessibility control in System Settings, relaunch if prompted, and confirm CGPreflightPostEventAccess returns true.

- [ ] **Step 4: Run the local desktop-simulator vertical slice**

Start the local relay, connect the Mac app to ws://127.0.0.1:8080/ws, and open the controller page from http://127.0.0.1:8080 in a desktop browser on the Mac. This is a protocol/input simulator, not the physical-phone acceptance test. Open click-target.html in Octo Browser, enable remote control, and place the cursor over the target button.

Required:

- one distinct action ID increments once;
- a duplicate ID does not increment;
- remote off does not increment;
- permission revoked does not increment;
- a lost result produces Unknown and no retry.

A physical phone must not be pointed at Mac localhost. The first physical-phone end-to-end gate is Task 9 through trusted OCI HTTPS/WSS.

- [ ] **Step 5: Calibrate the Octo down/up gap**

Test CLICK_GAP_MS in this order:

~~~text
0 ms
5 ms
10 ms
20 ms
30 ms
~~~

For each value, send 100 distinct actions from the desktop simulator with Octo frontmost and the cursor on the counter. Select the first value producing 100 increments from 100 actions. Do not choose a larger gap after the first passing value.

Record raw counts and the selected value in docs/physical-smoke-test.md.

- [ ] **Step 6: Commit**

~~~bash
git add tests/manual docs/install-macos.md docs/physical-smoke-test.md mac/ClickBridgeMac
git commit -m "test: prove native clicking in octo browser"
~~~

---

### Task 8: Dockerize and Deploy to the Existing OCI SJC VM

**Files:**

- Modify or replace: deploy/oci/Dockerfile
- Modify or replace: deploy/oci/compose.yaml
- Modify or replace: deploy/oci/Caddyfile
- Modify or replace: deploy/oci/.env.example
- Rewrite: docs/oci-deployment.md
- Create: docs/oci-recovery.md

**Interfaces:**

- Public: TCP 80 and 443 to Caddy.
- Private Compose network: Caddy to relay:8080.
- Inputs: CLICK_BRIDGE_DOMAIN, CLICK_BRIDGE_RELEASE, PHONE_TOKEN, MAC_TOKEN.
- No application volume or database.

- [ ] **Step 1: Gate the OCI operating system and network prerequisites**

Run this read-only inspection before changing the VM:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'set -eu; uname -m; cat /etc/os-release; ip route; command -v rsync || true; docker version 2>/dev/null || true; docker compose version 2>/dev/null || true; docker buildx version 2>/dev/null || true; systemctl is-enabled docker 2>/dev/null || true; sudo ss -ltnp | awk "NR == 1 || \$4 ~ /:(80|443|8080)$/"'
~~~

Record the output in `docs/oci-deployment.md`. Docker's current supported-platform matrix does not list Oracle Linux; do not present the RHEL repository as an officially supported Oracle Linux installation. The runtime gate passes in either of these cases:

1. `/etc/os-release` reports Ubuntu 22.04 or 24.04 LTS, so Step 2 can install or verify Docker through its official Ubuntu repository; or
2. another OS already has Docker Engine, Compose v2, Buildx, and rsync, and `docker version`, `docker compose version`, `docker buildx version`, `docker run --rm hello-world`, `rsync --version`, and `systemctl is-enabled docker` all pass without installing or replacing the engine. Step 12 supplies the controlled reboot/recheck before final acceptance.

If neither case passes, stop this task without changing the VM and choose one of these separately authorized branches:

1. provision or select an Ubuntu 22.04/24.04 instance in OCI us-sanjose-1 and continue this exact Docker Compose plan; or
2. revise Task 8 into a separately reviewed Podman/Quadlet or manually maintained Docker-static-binary deployment.

Do not reimage, terminate, or replace the existing VM automatically. Also verify in OCI that the instance VNIC is in a public subnet with an Internet Gateway and a `0.0.0.0/0` route to that gateway. Missing network prerequisites block deployment until corrected.

- [ ] **Step 2: Install Docker Engine when the VM uses the canonical Ubuntu path**

Always ensure the ordinary Ubuntu prerequisites and rsync exist first:

~~~bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl rsync
~~~

Skip the Docker repository/package block only when `sudo docker version`, `docker compose version`, and `docker buildx version` all succeed. This capability check may use `sudo` only to determine whether the engine is already installed; unprivileged access is established and tested immediately afterward. If any Docker capability is missing, run Docker's Ubuntu repository procedure on the VM:

~~~bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
ARCHITECTURE="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" "$ARCHITECTURE" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
~~~

Whether Docker was preinstalled or installed above, enable it and add the login user to the Docker group:

~~~bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
~~~

Disconnect and reconnect once so the Docker group membership is active. The task does not continue until every following command succeeds without `sudo`:

~~~bash
docker version
docker compose version
docker buildx version
docker run --rm hello-world
rsync --version
~~~

Expected: Docker Engine, Buildx, Compose v2, and rsync succeed without `sudo`; Docker is enabled across reboot. Record the actual versions in `docs/oci-deployment.md`.

- [ ] **Step 3: Write the container configuration**

Dockerfile requirements:

- base image node:24-alpine;
- use the repository root as build context;
- copy relay/package.json and relay/package-lock.json before source;
- copy relay/src to /app/src and relay/public to /app/public explicitly;
- npm ci --omit=dev;
- run as the node user;
- expose 8080;
- start node src/server.js;
- health check GET http://127.0.0.1:8080/healthz with node -e and built-in fetch; do not assume curl exists in the image.

Compose contains exactly:

- one relay service with build context ../.., Dockerfile deploy/oci/Dockerfile, and image tag click-bridge-relay:${CLICK_BRIDGE_RELEASE};
- one caddy:2-alpine service;
- relay uses `expose: ["8080"]` only on the private Compose network and has no `ports` key;
- Caddy ports 80:80 and 443:443;
- read-only bind mount ./Caddyfile:/etc/caddy/Caddyfile:ro;
- Caddy named-volume mounts `caddy_data:/data` and `caddy_config:/config`;
- restart unless-stopped for both;
- relay has no service-level `env_file:` key and receives PHONE_TOKEN, MAC_TOKEN, and CLICK_BRIDGE_DOMAIN through explicit `environment` mappings populated by the selected Compose `--env-file`;
- Caddy receives CLICK_BRIDGE_DOMAIN from Compose interpolation of that selected env file;
- local validation selects ignored `deploy/oci/.env`; OCI selects `/opt/click-bridge/shared/secrets.env`, which remains outside every release;
- relay health check.

Every production command uses the fixed Compose project name `oci`. The live
flat deployment already owns `oci_caddy_data` and `oci_caddy_config`; preserving
that project name reuses its certificate state during immutable-release
migration and avoids a second project competing for ports 80 and 443.

The relay environment block is explicit so the CLI-selected shared file works from every immutable release:

~~~yaml
environment:
  PORT: "8080"
  HOST: "0.0.0.0"
  PHONE_TOKEN: ${PHONE_TOKEN}
  MAC_TOKEN: ${MAC_TOKEN}
  CLICK_BRIDGE_DOMAIN: ${CLICK_BRIDGE_DOMAIN}
~~~

Do not retain the scaffold's `env_file: .env`; it would make rollback depend on a release-local secret file that this plan intentionally forbids.

Caddyfile:

~~~caddyfile
{$CLICK_BRIDGE_DOMAIN} {
    encode zstd gzip
    reverse_proxy relay:8080
}
~~~

Caddy must pass through the relay's canonical Content-Security-Policy unchanged. Do not maintain a second policy string here.

- [ ] **Step 4: Run local source checks and use container validation only when a local engine exists**

Always run the source-level gate on the Mac:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm ci
npm run check
~~~

Then inspect the local container capabilities:

~~~bash
docker info
docker compose version
docker buildx version
~~~

At this review the Mac does not have a reachable Docker daemon or Compose plugin, so failure here is an expected recorded preflight result, not permission to skip container validation entirely. Do not install or start Docker Desktop merely for this plan unless the user separately chooses to. When all three commands do pass, create ignored `deploy/oci/.env` from `.env.example` with CLICK_BRIDGE_DOMAIN=example.test, CLICK_BRIDGE_RELEASE=local, and the two fixed test tokens from Task 3, then optionally run the following early smoke. Do not use real deployment tokens for local validation.

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
docker build -f deploy/oci/Dockerfile -t click-bridge-relay:local .
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --quiet
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --services
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --images
cleanup_local_smoke() { docker rm -f click-bridge-relay-smoke >/dev/null 2>&1 || true; }
trap cleanup_local_smoke EXIT INT TERM
cleanup_local_smoke
docker run --detach --name click-bridge-relay-smoke -p 127.0.0.1:18080:8080 -e PHONE_TOKEN=1111111111111111111111111111111111111111111111111111111111111111 -e MAC_TOKEN=2222222222222222222222222222222222222222222222222222222222222222 -e CLICK_BRIDGE_DOMAIN=example.test click-bridge-relay:local
LOCAL_READY=0
for ATTEMPT in $(seq 1 30); do
  if docker exec click-bridge-relay-smoke node -e 'fetch("http://127.0.0.1:8080/healthz").then(async response => { if (!response.ok || (await response.text()) !== "ok") process.exit(1) }).catch(() => process.exit(1))'; then
    LOCAL_READY=1
    break
  fi
  sleep 1
done
if test "$LOCAL_READY" != 1; then
  docker logs --tail=100 click-bridge-relay-smoke
  exit 1
fi
cleanup_local_smoke
trap - EXIT INT TERM
~~~

When the optional local container path runs, expected: the relay image builds, the Compose model validates, and relay-only health passes. When it cannot run, record the exact missing capability in `docs/preflight.md`; Step 10 performs the same required image/config/health gate on OCI before any production `up -d`. Do not start the production-domain Caddyfile locally: DNS is not local and Caddy would attempt public ACME. TLS/Caddy validation occurs on OCI after DNS and firewall readiness.

- [ ] **Step 5: Verify the attached OCI address and instance-scoped ingress**

Use the OCI Console and record the resulting resource names and public IPv4 in `docs/oci-deployment.md`. For this personal Milestone 1 deployment, the existing attached ephemeral IPv4 is acceptable because it survives ordinary instance stops. A reserved address is an optional durability improvement, not a release gate. If the instance, VNIC, or primary private IP is replaced, update DuckDNS before starting Caddy on the replacement.

When a reserved-address migration is desired later:

1. Under **Networking > IP management > Reserved public IPs**, create a regional reserved IPv4 in the instance's compartment.
2. Open **Compute > Instances > the relay instance > Attached VNICs > the primary VNIC > IPv4 Addresses**.
3. Edit the primary private IP and assign the reserved public IP. An ephemeral public IP cannot be converted in place; unassign/delete the ephemeral public IP from that private IP, assign the reserved address to the same private IP, and then update `OCI_SSH_TARGET`. Do not detach the VNIC.
4. Under the instance VCN, create or reuse a Network Security Group attached only to this VNIC.
5. Add two stateful ingress rules with source CIDR `0.0.0.0/0`, protocol TCP, all source ports, and destination port `80` for HTTP and `443` for HTTPS/WSS.
6. Audit every NSG attached to the VNIC and every security list attached to its subnet. Remove or narrow any existing public TCP `8080`, all-protocol, all-port, or other broad application-ingress rule before claiming the application boundary is only `80`/`443`. Keep the existing SSH path usable and restricted to the operator's source CIDR. Do not add an OCI ingress rule for `8080`.

A subnet security list is acceptable only if its wider subnet scope is explicitly recorded; the instance-scoped NSG is the default. Milestone 1 is IPv4-only: do not add IPv6 ingress or publish an AAAA record.

- [ ] **Step 6: Choose the hostname and verify DNS before Caddy starts**

Point `CLICK_BRIDGE_DOMAIN` to the selected attached OCI public IPv4. The verified Milestone 1 endpoint is `clickbridge-sjc.duckdns.org` at `146.235.216.172`. Do not use `sslip.io` or `nip.io` as the permanent address because certificate issuance for their shared registered domains can be affected by other users.

Let's Encrypt supports short-lived IP-address certificates as of 2026, but the stock Caddy automatic-public-HTTPS path used by this plan is hostname-based. Do not add a second ACME client and six-day IP-certificate renewal path to avoid choosing a hostname.

Verify from the Mac, not only from the VM:

~~~bash
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
export OCI_PUBLIC_IP='146.235.216.172'
test "$(dig +short A "$CLICK_BRIDGE_DOMAIN" | sort -u)" = "$OCI_PUBLIC_IP"
test -z "$(dig +short AAAA "$CLICK_BRIDGE_DOMAIN")"
~~~

Expected: the complete unique A RRset contains exactly one value, the reserved OCI IPv4, and the AAAA RRset is empty. Remove stale A and AAAA records before Caddy startup. Do not start Caddy until this passes; repeated ACME failures create avoidable backoff.

- [ ] **Step 7: Verify the host firewall and listening-port boundary**

Always inspect listeners first:

~~~bash
sudo ss -ltnp | awk 'NR == 1 || $4 ~ /:(80|443|8080)$/'
~~~

On Ubuntu, inspect UFW. If it reports `Status: active`, allow the two public services:

~~~bash
sudo ufw status verbose
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status verbose
~~~

On a reused Oracle Linux VM whose existing Docker runtime passed Step 1, inspect `firewalld`, derive the external zone from the interface carrying the default route, explicitly reject Docker's own zone, and add HTTP/HTTPS only when it is running:

~~~bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
DEFAULT_ROUTE_INTERFACE="$(ip route show default | awk 'NR == 1 {print $5}')"
test -n "$DEFAULT_ROUTE_INTERFACE"
ACTIVE_ZONE="$(sudo firewall-cmd --get-zone-of-interface="$DEFAULT_ROUTE_INTERFACE")"
test -n "$ACTIVE_ZONE"
test "$ACTIVE_ZONE" != "no zone"
test "$ACTIVE_ZONE" != "docker"
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=http
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=https
sudo firewall-cmd --reload
test "$(sudo firewall-cmd --get-zone-of-interface="$DEFAULT_ROUTE_INTERFACE")" = "$ACTIVE_ZONE"
sudo firewall-cmd --zone="$ACTIVE_ZONE" --list-services
~~~

If neither UFW nor `firewalld` is the active host-firewall tool, stop and record the actual tool before changing rules; do not paste rules for the wrong distribution.

Stop if another process already owns port 80 or 443; identify and resolve that service deliberately rather than killing it from this plan. Docker-published ports can bypass UFW, so the actual boundary is both of the following: OCI permits only 80/443, and Compose publishes only Caddy's 80/443 mappings. The relay uses `expose: 8080` on the private Compose network and has no host `ports` entry.

- [ ] **Step 8: Install the one shared role-token environment**

For the first migration, preserve the already-paired credentials. Copy only the
domain and two role tokens from the existing live mode-0600 file into the shared
location without printing them:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'set -eu; test "$(stat -c %a /opt/click-bridge/deploy/oci/.env)" = 600; install -d -m 0700 /opt/click-bridge/shared; umask 077; grep -E "^(CLICK_BRIDGE_DOMAIN|PHONE_TOKEN|MAC_TOKEN)=" /opt/click-bridge/deploy/oci/.env > /opt/click-bridge/shared/secrets.env; test "$(wc -l < /opt/click-bridge/shared/secrets.env)" = 3; grep -Eq "^PHONE_TOKEN=[0-9a-f]{64}$" /opt/click-bridge/shared/secrets.env; grep -Eq "^MAC_TOKEN=[0-9a-f]{64}$" /opt/click-bridge/shared/secrets.env; test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600'
~~~

Keep the flat tree and its original `.env` untouched until the immutable
candidate and rollback test pass. Only a new installation or deliberate
two-role rotation uses the generation path below.

On the Mac, generate a temporary mode-0600 transfer file without printing either token:

~~~bash
umask 077
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
PHONE_TOKEN="$(openssl rand -hex 32)"
MAC_TOKEN="$(openssl rand -hex 32)"
{
  printf 'CLICK_BRIDGE_DOMAIN=%s\n' "$CLICK_BRIDGE_DOMAIN"
  printf 'PHONE_TOKEN=%s\n' "$PHONE_TOKEN"
  printf 'MAC_TOKEN=%s\n' "$MAC_TOKEN"
} > /private/tmp/click-bridge-secrets.env
test "$(wc -l < /private/tmp/click-bridge-secrets.env | tr -d ' ')" = 3
~~~

Transfer it and install the single canonical VM copy outside every release:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
scp /private/tmp/click-bridge-secrets.env "$OCI_SSH_TARGET:/tmp/click-bridge-secrets.env"
ssh "$OCI_SSH_TARGET" 'sudo install -d -m 0700 -o "$USER" -g "$(id -gn)" /opt/click-bridge/shared && install -m 0600 /tmp/click-bridge-secrets.env /opt/click-bridge/shared/secrets.env && rm -f /tmp/click-bridge-secrets.env && test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600'
~~~

Every OCI Compose command selects `/opt/click-bridge/shared/secrets.env` directly with `--env-file`; never copy it into a release directory. Keep `/private/tmp/click-bridge-secrets.env` at mode 0600 only until the Step 12 rollback/reboot checks and client setup finish. Configure the phone with `PHONE_TOKEN` and the Mac Keychain with `MAC_TOKEN`; after every Step 12 recovery smoke passes, remove that exact temporary file and unset the two shell variables. Never place either token in a URL, tracked file, shell transcript, or deployment log. Generate `DIRECT_TOKEN` only if Task 11 begins.

- [ ] **Step 9: Transfer an immutable release**

Define the real values recorded in Task 1 before running the commands:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
export CLICK_BRIDGE_RELEASE="$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$CLICK_BRIDGE_RELEASE" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || exit 1
ssh "$OCI_SSH_TARGET" 'sudo mkdir -p /opt/click-bridge/releases /opt/click-bridge/shared && sudo chown -R "$USER":"$USER" /opt/click-bridge && command -v rsync && rsync --version >/dev/null && docker version && docker compose version && docker buildx version && test -f /opt/click-bridge/shared/secrets.env'
ssh "$OCI_SSH_TARGET" "test ! -e /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE && mkdir /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
rsync -az --delete --exclude .git --exclude node_modules --exclude build --exclude DerivedData --exclude deploy/oci/.env --exclude archive --exclude _to_delete --exclude benchmarks /Users/harshitagarwal/Desktop/clicker/ "$OCI_SSH_TARGET":/opt/click-bridge/releases/"$CLICK_BRIDGE_RELEASE"/
ssh "$OCI_SSH_TARGET" "printf '%s\\n' '$CLICK_BRIDGE_RELEASE' > /opt/click-bridge/candidate-release"
~~~

Replace every ACTUAL value before execution and verify `CLICK_BRIDGE_RELEASE` matches only fourteen UTC digits plus `T` and `Z`. The `--delete` target is the newly created exact release directory; never point it at `/opt/click-bridge`, a home directory, or an unresolved variable. Historical archives, `_to_delete/`, and benchmark data never enter a VM release. A failed prerequisite check stops deployment; do not improvise a different container engine inside this step.

- [ ] **Step 10: Build and start the release on the OCI VM**

Build on the VM so Docker selects the VM's recorded amd64 or arm64 architecture:

~~~bash
export CLICK_BRIDGE_RELEASE='ACTUAL_RELEASE_FROM_STEP_9'
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml config --quiet
if test -f /opt/click-bridge/current-release; then
  cp /opt/click-bridge/current-release /opt/click-bridge/previous-release
fi
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml build --pull
cleanup_candidate() { docker rm -f click-bridge-relay-candidate >/dev/null 2>&1 || true; }
trap cleanup_candidate EXIT INT TERM
cleanup_candidate
docker run --detach --name click-bridge-relay-candidate -p 127.0.0.1:18080:8080 --env-file /opt/click-bridge/shared/secrets.env "click-bridge-relay:${CLICK_BRIDGE_RELEASE}"
CANDIDATE_READY=0
for ATTEMPT in $(seq 1 30); do
  if docker exec click-bridge-relay-candidate node -e 'fetch("http://127.0.0.1:8080/healthz").then(async response => { if (!response.ok || (await response.text()) !== "ok") process.exit(1) }).catch(() => process.exit(1))'; then
    CANDIDATE_READY=1
    break
  fi
  sleep 1
done
if test "$CANDIDATE_READY" != 1; then
  docker logs --tail=100 click-bridge-relay-candidate
  exit 1
fi
cleanup_candidate
trap - EXIT INT TERM
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
docker volume ls --filter label=com.docker.compose.project=oci
~~~

Expected: Compose configuration, OCI-native image build, and loopback relay-only health all pass before the candidate can replace the production services. Then exactly one relay and one Caddy container run. Caddy publishes host ports 80 and 443; relay port 8080 is absent from the host-published-port list. The named Caddy data and config volumes exist so certificate state survives container replacement.

- [ ] **Step 11: Verify HTTPS, WSS, and the public port boundary**

From the Mac:

~~~bash
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
curl -fsS "https://${CLICK_BRIDGE_DOMAIN}/healthz"
curl -fsS -I "http://${CLICK_BRIDGE_DOMAIN}/"
curl -fsS -D - -o /dev/null "https://${CLICK_BRIDGE_DOMAIN}/"
~~~

Expected: `/healthz` returns `ok`, HTTP redirects to HTTPS, the certificate is trusted for the chosen hostname, and the HTTPS response contains exactly one canonical Content-Security-Policy header.

Load the temporary token file only for the smoke if it has not yet been removed, then run the planned end-to-end script:

~~~bash
set -e
cd /Users/harshitagarwal/Desktop/clicker/relay
set -a
. /private/tmp/click-bridge-secrets.env
set +a
node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"
unset PHONE_TOKEN MAC_TOKEN
~~~

On the VM, verify the bindings and logs:

~~~bash
export CLICK_BRIDGE_RELEASE='ACTUAL_RELEASE_FROM_STEP_9'
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
sudo ss -ltnp | awk 'NR == 1 || $4 ~ /:(80|443|8080)$/'
~~~

Expected:

- trusted HTTPS;
- successful WSS handshake;
- full request/result round trip;
- token absent from URLs and logs;
- exactly one canonical Content-Security-Policy header matching the local relay test;
- Caddy logs successful certificate management rather than an ACME retry loop;
- only Caddy ports 80 and 443 are host-published; relay 8080 is not a host listener.

Only after the public smoke passes, record the active release on the VM:

~~~bash
printf '%s\n' "$CLICK_BRIDGE_RELEASE" > /opt/click-bridge/current-release
~~~

For the first flat-layout migration, retain `candidate-release` through the
entire Step 12 rollback, roll-forward, restart, reboot, and external-smoke gate.
The emergency legacy fallback must validate its strict release-ID format and
directory before intentionally stopping the new stack. Remove the marker only
after the complete recovery gate passes.

- [ ] **Step 12: Verify rollback and recovery behavior**

Step 10 already captures `current-release` into `previous-release` before starting a later release. Never overwrite `previous-release` after the candidate stack has started. All recovery Compose commands use the one shared secrets file; no release contains its own `.env`.

If a later candidate fails after `up -d` but before Step 11 marks it current, recover the still-recorded current release. `FAILED_RELEASE` is the candidate ID from Step 10; never derive it from `current-release`, which intentionally still names the last known-good release:

~~~bash
export FAILED_RELEASE='ACTUAL_FAILED_CANDIDATE_RELEASE_FROM_STEP_10'
export RECOVERY_RELEASE="$(cat /opt/click-bridge/current-release)"
test -n "$RECOVERY_RELEASE"
test "$RECOVERY_RELEASE" != "$FAILED_RELEASE"
export CLICK_BRIDGE_RELEASE="$RECOVERY_RELEASE"
cd "/opt/click-bridge/releases/$RECOVERY_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the same external HTTPS, WSS, CSP, and public-port smoke from Step 11 against the restored stack. Also rerun the VM listener check and verify relay `8080` is still not host-published. `current-release` already contains `RECOVERY_RELEASE`, so do not rewrite it. If the restored stack does not pass, preserve both release directories and logs and follow `docs/oci-recovery.md`; do not mark recovery healthy. If the first-ever candidate fails, there is no previous application to recover: leave `current-release` absent, preserve the failed release and logs, fix the cause, and repeat Steps 9 through 11 with a new release ID.

For the first deployment, prove recovery from its immutable source even though no previous release exists:

~~~bash
export ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml build
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the full external Step 11 smoke before calling first-release recovery successful.

Then exercise a real rollback and roll-forward without waiting for a code change:

1. Repeat Steps 9 through 11 from the same verified local commit using a new timestamped release ID. This creates a second immutable release, captures the first ID in `previous-release`, and records the second in `current-release` only after its smoke passes.
2. Save the second ID as `FORWARD_RELEASE`, select the first ID from `previous-release`, and force the running project back to it:

~~~bash
export FORWARD_RELEASE="$(cat /opt/click-bridge/current-release)"
export ROLLBACK_RELEASE="$(cat /opt/click-bridge/previous-release)"
test -n "$ROLLBACK_RELEASE"
test "$ROLLBACK_RELEASE" != "$FORWARD_RELEASE"
export CLICK_BRIDGE_RELEASE="$ROLLBACK_RELEASE"
cd "/opt/click-bridge/releases/$ROLLBACK_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the complete external Step 11 smoke. Only after it passes:

~~~bash
printf '%s\n' "$ROLLBACK_RELEASE" > /opt/click-bridge/current-release
~~~

3. Roll forward to the already-built second release:

~~~bash
export CLICK_BRIDGE_RELEASE="$FORWARD_RELEASE"
cd "/opt/click-bridge/releases/$FORWARD_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the complete external Step 11 smoke again. Only after it passes:

~~~bash
printf '%s\n' "$FORWARD_RELEASE" > /opt/click-bridge/current-release
printf '%s\n' "$ROLLBACK_RELEASE" > /opt/click-bridge/previous-release
~~~

Do not delete either retained release directory or image until the rollback, roll-forward, and reboot recovery checks all pass.

Test each container restart explicitly from the VM:

~~~bash
export ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml restart relay
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the complete external Step 11 smoke, then repeat for Caddy:

~~~bash
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml restart caddy
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
~~~

Rerun the complete external Step 11 smoke. Finally request a controlled VM reboot from the Mac and wait up to five minutes for SSH to return:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
PRE_BOOT_ID="$(ssh "$OCI_SSH_TARGET" 'cat /proc/sys/kernel/random/boot_id')"
test -n "$PRE_BOOT_ID"
ssh "$OCI_SSH_TARGET" 'sudo systemctl reboot'
VM_READY=0
for ATTEMPT in $(seq 1 60); do
  CURRENT_BOOT_ID="$(ssh -o ConnectTimeout=5 "$OCI_SSH_TARGET" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
  if test -n "$CURRENT_BOOT_ID" && test "$CURRENT_BOOT_ID" != "$PRE_BOOT_ID"; then
    if ssh -o ConnectTimeout=5 "$OCI_SSH_TARGET" 'docker version >/dev/null && docker compose version >/dev/null'; then
      VM_READY=1
      break
    fi
  fi
  sleep 5
done
if test "$VM_READY" != 1; then
  printf 'VM did not return with a new boot ID and working Docker within five minutes.\n' >&2
  exit 1
fi
ssh "$OCI_SSH_TARGET" 'set -eu; ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"; export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"; cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"; docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps'
~~~

Rerun the complete external Step 11 smoke and confirm Docker's enabled service plus each container's `restart: unless-stopped` policy restored the stack.

After each:

- both clients reconnect;
- no old action executes;
- /healthz returns ok;
- exactly one relay replica is running.

After the final rollback/reboot smoke and phone/Mac setup succeed, remove the exact local transfer file and clear token variables:

~~~bash
unset PHONE_TOKEN MAC_TOKEN
rm -f /private/tmp/click-bridge-secrets.env
~~~

Oracle documents that idle Always Free compute may be reclaimed. docs/oci-recovery.md must contain the complete source, environment, DNS, and Compose recovery sequence. Do not create artificial CPU or network load to evade the platform policy.

- [ ] **Step 13: Commit the deployment runbook and container files**

~~~bash
git add deploy/oci docs/oci-deployment.md docs/oci-recovery.md
git commit -m "chore: deploy click bridge on oci sjc"
~~~

---

### Task 9: Milestone 1 Physical Acceptance, Real Latency Data, and Canonical Cleanup

**Files:**

- Create: benchmarks/measurements.csv
- Create: benchmarks/run-evidence.csv
- Create: benchmarks/README.md
- Create: relay/scripts/summarize-latency.mjs
- Create: relay/scripts/run-negative-matrix.mjs
- Create: relay/test/latency-summary.test.js
- Create: relay/test/negative-matrix.test.js
- Create: relay/public/benchmark-session.js
- Create: relay/test/benchmark-session.test.js
- Modify or replace: docs/benchmark.md
- Modify: relay/public/app.js
- Modify: relay/public/transport-coordinator.js
- Modify: relay/public/wire-protocol.js
- Modify: mac/ClickBridgeMac/RelayClient.swift
- Modify: mac/ClickBridgeMac/ActionProcessor.swift
- Modify: mac/ClickBridgeMac/MacInputExecutor.swift
- Create: docs/latency-report.md
- Modify: archive/README.md
- Modify: docs/physical-smoke-test.md
- Modify: README.md
- Historical cleanup complete: `archive/plans/PLAN-v5.md` is preserved as non-authoritative evidence
- Verify in place: historical plans and prototypes already under archive/
- Remove after content verification: `_to_delete/_impl.tgz` and `_to_delete/_scaffold.tgz`

**Interfaces:**

- BenchmarkSession owns benchmark scheduling, immutable in-memory rows, alignment sets, counter snapshots, and explicit CSV export. It uses only public ClockHealthController and TransportCoordinator APIs plus an injected `requestCounterSnapshot` closure; it never sends directly to a socket.
- TransportCoordinator emits immutable action-lifecycle records to an optional observer; it remains unaware of CSV, counters, schedules, and percentile calculations.
- The foreground PWA stores diagnostics in memory and exports CSV only on explicit user action.
- action.result supplies Mac processing time and the mouse-down post wall-clock sample.
- relay.ack supplies relay processing time.
- summarize-latency.mjs reports nearest-rank latency percentiles only for Posted rows and reports every failure separately.
- The archive is explicitly non-authoritative and excluded from runtime, build, and deployment inputs.

- [ ] **Step 1: Define raw and derived measurement fields**

CSV columns:

~~~text
runId,condition,blockIndex,sampleIndex,network,scheduledIdleSeconds,actualIdleMs,keepWarm,normalHeartbeat,tailscaleRoute,pathsSent,actionId,activationUnixMs,mouseDownPostedUnixMs,clockOffsetMs,clockRttMs,clockUncertaintyMs,estimatedActuationMs,ackMs,confirmationMs,relayProcessingUs,macProcessingUs,acceptedVia,firstResultVia,lateResultCount,status,reason
~~~

Run-evidence columns:

~~~text
runId,startMouseDownPostCount,startMouseUpPostCount,endMouseDownPostCount,endMouseUpPostCount,octoCounterStart,octoCounterEnd,logicalActionCount
~~~

Definitions:

- condition is the exact tuple of network, selected transport mode, keep-warm state, and benchmark session;
- pathsSent is oci, tailscale, or oci+tailscale;
- acceptedVia is the immutable ingress in the Mac's cached result;
- firstResultVia is phone-local delivery metadata and never changes action.result;
- actualIdleMs is measured, not copied from the requested schedule;
- normalHeartbeat is always 20s for an authenticated visible client, including keep-warm-off runs.
- run-evidence counter differences, not per-action wire results, prove the exact number of CGEvent.post calls.

No token, IP address, browsing data, cursor coordinate, Octo profile data, or page content is recorded.

- [ ] **Step 2: Write failing summary and reliability tests**

Use fixed arrays to prove nearest-rank calculations:

~~~javascript
assert.equal(nearestRank([1, 2, 3, 4], 0.50), 2);
assert.equal(nearestRank([1, 2, 3, 4], 0.95), 4);
~~~

Tests must prove:

- only Posted samples enter latency percentiles;
- Rejected and Unknown remain in reliability totals;
- no outlier is removed;
- missing raw clock fields cannot produce estimatedActuationMs;
- a full condition gets p95/p99 only with at least 95 Posted rows and always prints its Posted denominator;
- the predeclared 2s/15s/60s subgroups get median, maximum, count, and raw rows but no p95 or p99 claim;
- late transport results count separately and cannot change the terminal phone state.
- BenchmarkSession cannot start when an action is already pending, never bypasses coordinator readiness, and never retries Unknown;
- benchmark cancellation, visibility loss, or generation change stops its schedule without altering the coordinator's pending action or production result timer;
- action-lifecycle observation adds no extra timer or socket send on the normal one-tap path.

- [ ] **Step 3: Implement clock alignment and local-only metrics**

For one sync exchange:

~~~text
t0 = phone sends request
t1 = Mac receives request
t2 = Mac sends response
t3 = phone receives response

Mac-minus-phone offset = ((t1 - t0) + (t2 - t3)) / 2
network RTT = (t3 - t0) - (t2 - t1)
estimatedActuationMs = mouseDownPostedUnixMs - offset - activationUnixMs
clockUncertaintyMs = network RTT / 2
~~~

At the start of a benchmark, run 20 sync exchanges and select the sample with the smallest non-negative network RTT. Repeat 20 exchanges after every 25 actions and after visibility or network changes. Use performance.timeOrigin plus performance.now() for activationUnixMs. Reject an alignment set with impossible ordering or negative RTT.

estimatedActuationMs is a clock-corrected estimate from phone handler entry to CGEvent mouse-down post, with clockUncertaintyMs reported as an alignment uncertainty proxy under path asymmetry. It is not a claim about touchscreen hardware scan latency or a rigorous physical error bound. confirmationMs remains the user-visible round trip from handler entry to the first terminal result.

Also measure:

- ackMs on the phone's monotonic clock;
- relayProcessingUs on the OCI process's monotonic clock;
- macProcessingUs on the Mac's ContinuousClock;
- post counters from the Mac's diagnostic in-memory counters.

Do not combine unrelated monotonic clocks or call half of an ordinary action RTT one-way latency.

BenchmarkSession is created only when the Diagnostics screen starts a run. It asks ClockHealthController for alignment samples through a dedicated public method, selects through the shared pure minimum-RTT function, calls only `TransportCoordinator.activate()` for each scheduled action, and observes immutable ack/result/terminal records through a callback. It owns in-memory rows, the run schedule, before/after counter snapshots, and explicit CSV export; it cannot access a WebSocket or transport `send` method.

`benchmark-session.js` also exports a small CounterSnapshotRequester used only as the production implementation of the injected closure. It owns one diagnostic request ID, matching response, timeout, and cancellation; it receives a narrow `sendDiagnostics(message)` function and validated `diagnostics.counters` events, not a socket. BenchmarkSession receives only `requestCounterSnapshot(): Promise<snapshot>`, and tests replace it with a deterministic fake. Take one snapshot before and after a run, outside the timed action sequence, and write the pair to run-evidence.csv. app.js routes the validated counter response to CounterSnapshotRequester, wires Diagnostics controls to BenchmarkSession, and renders progress. Unit tests prove export column order, no secret fields, counter-delta calculation, request timeout/cancellation, and no benchmark-generated automatic retry.

- [ ] **Step 4: Build and prove the controlled negative-matrix harness**

run-negative-matrix.mjs connects as the one phone using tokens supplied only through environment variables. Its automated tests use a fake relay/Mac; its public run uses the harmless Octo target and explicit operator steps. It must support:

- exact duplicate: send one immutable request twice and assert exact cached result plus one Octo increment;
- ID conflict: reuse the ID with another valid issued/expiry pair and assert id_conflict plus no second increment;
- expired: send a valid already-expired request and assert relay rejection plus no input;
- result drop: close the phone route after relay.ack, wait for the Mac result, reconnect, and assert no late delivery or replay;
- capacity remains an injected Swift ActionProcessor test with a fake poster and clock; do not flood the public relay or fill the real Mac process for this case.

- [ ] **Step 5: Run the end-to-end correctness matrix**

Run normal interaction, visibility, accessibility, and restart rows from the physical phone on cellular. Run duplicate, ID-conflict, expired, and result-drop injection rows with Step 4's harness while the PWA is disconnected. Every row still uses the public OCI relay and the real Mac app; the harness exists only to construct protocol states the normal one-button UI cannot create.

Required outcomes:

| Scenario | Required result |
| --- | --- |
| Mac app closed | button disabled; no queued click |
| Remote control off | no input |
| Permission absent or revoked | no input; permission_required |
| Fresh Mac-ready state | Checking clock, then Ready only after five valid time-sync responses |
| Missing time-sync response | Clock check unavailable within 3.5 seconds; Retry control visible; no action |
| Retry after time-sync recovery | five new valid responses, then Ready; no action generated by retry |
| Ready with Octo frontmost | one tap, one counter increment |
| Duplicate action ID | one total increment and exact cached result |
| Same ID with changed payload | id_conflict; no second increment |
| Expired buffered request | expired; no input |
| Phone hidden with action pending | Unknown; no replay |
| Phone visible again | reconnect only |
| Relay restart | reconnect; no replay |
| OCI VM reboot | services recover; no replay |
| Result path drops after forward | Unknown; no retry |
| VoiceOver or keyboard activation while Ready | exactly one request and no duplicate |
| Two taps while pending | second suppressed |
| Mac locked or asleep | no queued or replayed action; record observed state, then require fresh Ready after wake/unlock before the next test |

- [ ] **Step 6: Collect the OCI baseline**

Run one Wi-Fi condition and one cellular condition with OCI selected and keep-warm off:

- 10 warm-up taps excluded;
- 100 recorded taps per condition;
- one pre-generated randomized schedule containing 70 two-second gaps, 20 fifteen-second gaps, and 10 sixty-second gaps;
- the same schedule reused for later comparable modes;
- every actual gap recorded;
- no outlier removed;
- Posted, Rejected, and Unknown counted separately.

For each 100-attempt condition, report the Posted denominator, p50, maximum, Posted rate, rejection reasons, Unknown count, reconnects, and clock uncertainty. Report p95/p99 only when at least 95 rows are Posted; otherwise mark tail latency unavailable and fail any optimization gate. For the 2s, 15s, and 60s subgroups, report count, median, maximum, and raw rows; do not claim subgroup p95/p99.

- [ ] **Step 7: Run a randomized five-second keep-warm experiment**

Use cellular, OCI-only, and the same phone position. In each of two sessions at different times, alternate randomized blocks between:

- A: normal 20-second heartbeat, five-second keep-warm off;
- B: normal 20-second heartbeat, five-second keep-warm on.

Each arm must accumulate 100 recorded actions using the same mixed idle schedule. Keep the page visible throughout a block. Do not compare an all-off morning run to an all-on evening run.

Retain keep-warm only if its overall Posted estimatedActuationMs p95 improves by at least 15 percent and at least 20 ms in both sessions, Posted reliability does not decrease, and Unknown/reconnect counts do not increase. Otherwise remove the five-second loop and its setting before accepting Milestone 1.

- [ ] **Step 8: Finish the canonical cleanup before the Milestone 1 stop**

The imported repository already contains historical plan and prototype directories. Do not create duplicate copies. After Milestone 1 has passed:

- keep `archive/plans/PLAN-v5.md` historical and `FINAL-PLAN.md` canonical at the root;
- verify the existing historical plans and prototypes are already represented under `archive/`;
- list the contents of `_to_delete/_impl.tgz` and `_to_delete/_scaffold.tgz` without extracting them into the repository;
- compare those listings with the active and archived trees; delete the two ignored bundles only after confirming they contain no unique source, plan, or evidence;
- if either bundle contains something unique, extract only that specific item to the appropriate archive location, verify it, and then delete the bundle.

archive/README.md must state that the contents are non-authoritative historical evidence and are never imported, built, deployed, or linked as current instructions. FINAL-PLAN.md remains at the repository root. README.md points only to FINAL-PLAN.md.

Verify active files have no dependency on the archive:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
rg -n "fly.io|flyctl|libnut|receiver.js|PLAN-v4|fast-server" README.md relay mac deploy docs tests
~~~

Historical discussion inside FINAL-PLAN.md and archive files is allowed; active runtime or installation references are not.

- [ ] **Step 9: Verify and commit the real data and cleanup**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm ci
npm run check
node scripts/summarize-latency.mjs ../benchmarks/measurements.csv
~~~

Expected: the generated summary exactly matches docs/latency-report.md and every non-Posted row appears in reliability totals.

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
git add -A
git diff --cached --check
git commit -m "test: accept oci milestone with real latency data"
~~~

### Milestone 1 acceptance gate

- [ ] Clean npm ci and npm run check pass.
- [ ] Clean xcodebuild test and Release build pass.
- [ ] Public HTTPS and WSS are trusted.
- [ ] Phone PWA installs and operates in the foreground.
- [ ] Native Mac app reconnects, heartbeats, and publishes accurate state.
- [ ] PostEvent permission is the only input permission requested.
- [ ] One distinct action ID produces one Octo counter increment.
- [ ] Concurrent and sequential duplicates produce no second click.
- [ ] Expired or capacity-rejected actions produce no click.
- [ ] Relay, container, and VM restart produce no replay.
- [ ] Cellular physical matrix passes.
- [ ] Each baseline condition contains 100 recorded actions.
- [ ] Clock-corrected estimates include their uncertainty.
- [ ] No provider estimate is presented as measured data.
- [ ] FINAL-PLAN.md is the only active plan and the archive is non-authoritative.

This is the PWA/core OCI checkpoint. Continue through Task 10 before final handoff; stop before Task 11 if optional transport experiments are unnecessary.

---

### Task 10: Native iOS Foreground Volume Client

This task is required before final handoff. It adds a native SwiftUI iPhone client while leaving `relay/public/` unchanged as the fallback and making no wire-protocol change.

**Files:**

- Create: `ios/project.yml`
- Generate: `ios/ClickBridgePhone.xcodeproj/`
- Create: `ios/ClickBridgePhone/`
- Create: `ios/ClickBridgePhoneTests/`
- Create: `docs/ios-acceptance.md`

**Project and SOLID boundaries:**

- `ios/project.yml` is the project source and defines a shared scheme named exactly `ClickBridgePhone`.
- `VolumeChangeSource` emits old/new output-volume samples plus an observer generation. Its production adapter observes `AVAudioSession.sharedInstance().outputVolume` through supported KVO. It does not use `AVCaptureEventInteraction`, create a capture session, request camera permission, or activate the camera.
- `PhoneActionTransport` owns one authenticated WSS generation, strict frame parsing, heartbeat, reconnect, clock-health, and result routing. It reuses the existing phone messages and fixtures byte-for-byte; iOS adds no message type, field, acknowledgement, retry, or protocol exception.
- Inject `Clock`, `Scheduler`, and `Haptics` ports. Production adapters wrap wall/monotonic time, cancellable scheduling, and UIKit haptics; deterministic fakes control every race in tests.
- `PhoneSessionCoordinator` owns foreground generation, readiness, the one-in-flight action, and presentation state. Platform adapters never create action IDs or decide whether a delta is accepted.

- [ ] **Step 1: Create the iOS target and configuration storage**

Generate a SwiftUI iOS application and unit-test target from `ios/project.yml`. Store the relay WSS URL in app settings and `PHONE_TOKEN` in Keychain. Reject non-WSS public URLs, never place the token in a URL or log, and keep exactly one authenticated phone socket. A native client connection may replace the PWA connection under the relay's existing one-phone rule; it must not change that rule.

- [ ] **Step 2: Implement foreground volume-delta semantics**

Start a fresh session generation on foreground activation, reconnect, rerun the same five-sample clock-health gate, and permit actions only after relay, Mac, and clock state are ready. On background transition, disable sending first, stop KVO observation, cancel timers, and close/invalidate the socket generation. A callback from any earlier observer or socket generation sends nothing.

For each KVO callback, compare the prior accepted system volume with the new value:

- an upward or downward nonzero delta is eligible;
- an unchanged value or duplicate callback for the same value is noise;
- while one action is in flight, further deltas are ignored and never queued;
- after a terminal result, a distinct later delta may create a new action immediately; do not use a blanket debounce that merges separate presses;
- each accepted delta creates exactly one immutable action ID, with `issuedAtUnixMs`, `expiresAtUnixMs`, expiry validation, Unknown handling, and no-retry behavior identical to the PWA.

- [ ] **Step 3: Present complete readiness and result state**

Show `Ready`, `Not connected`, `Mac offline`, `Clock mismatch`, and `At volume boundary` explicitly. At 0%, explain that Volume Down cannot create another observable change; at 100%, explain the same for Volume Up. Do not simulate a delta or modify system volume to escape a boundary.

Document in the UI/help that Control Center, wired or Bluetooth headsets, and AirPods can also trigger because the supported API observes output-volume changes, not the physical button source. Produce haptic feedback only after the matching Mac `action.result`; `relay.ack` changes forwarding state but never produces haptics.

Expose the same click coordinator through a readiness-gated on-screen **Trigger Click** button and an iOS 17 **Trigger Click** App Shortcut. The shortcut may retain only the narrow launch-to-active handoff, makes one immediate attempt once active, and consumes not-ready, pending, failed, or backgrounded requests. It never queues or retries a delayed click.

- [ ] **Step 4: Prove the coordinator and transport with deterministic tests**

Tests must cover:

- upward and downward deltas;
- duplicate KVO callbacks and unchanged values;
- rapid separate changes after terminal completion, plus held/autorepeat changes while one action is pending;
- foreground/background races and callbacks after observation stops;
- stale observer and socket generations after reconnect;
- relay/Mac/clock readiness loss and expired actions;
- 0% and 100% boundary presentation and the still-detectable inward direction;
- no haptic on send or `relay.ack`, and one haptic after the matching Mac terminal result;
- exact one action ID per accepted delta, one action in flight, no queue, no retry, and no second send from callback noise;
- on-screen and App Shortcut actions using the same readiness/one-in-flight gate, including no delayed send after a not-ready, pending, failed, or backgrounded shortcut attempt;
- the existing canonical phone fixtures, heartbeat, clock-health, reconnect, result, strict-frame, and 4 KiB rules.

- [ ] **Step 5: Build, test, and record physical acceptance**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/ios
xcodegen generate --spec project.yml
xcodebuild -project ClickBridgePhone.xcodeproj -scheme ClickBridgePhone -showdestinations
~~~

Run the `ClickBridgePhone` unit tests on an installed iOS Simulator destination, then build the same shared scheme for a generic iOS device. Record the Xcode, Swift, simulator, SDK, and command results in `docs/ios-acceptance.md`. Simulator tests can prove coordinator, lifecycle, protocol, and UI logic, but simulator volume controls do not prove hardware-volume behavior.

On a physical signed iPhone, with the app foreground-active and the OCI relay/Mac/clock ready, prove Volume Up and Volume Down separately, duplicate/noise suppression, rapid separate presses, a held press while an action is pending, background/foreground revalidation, both volume boundaries, external volume-source disclosure, terminal-result-only haptics, and exactly one harmless Octo counter increment per accepted delta. This physical iPhone gate is mandatory.

- [ ] **Step 6: Commit the native client after all gates pass**

~~~bash
git add ios docs/ios-acceptance.md FINAL-PLAN.md README.md
git diff --cached --check
git commit -m "feat: add foreground ios volume client"
~~~

### Native iOS acceptance gate

- [ ] `ios/project.yml` generates the shared `ClickBridgePhone` scheme.
- [ ] Simulator unit tests and generic iOS device build pass.
- [ ] The PWA remains unchanged and passes its existing checks.
- [ ] The native client uses the existing OCI relay and exact phone wire protocol.
- [ ] Foreground/background, readiness, generation, expiry, boundary, one-in-flight, no-queue, and result-only haptic tests pass.
- [ ] Physical iPhone Volume Up and Volume Down each produce exactly one action and exactly one Octo counter increment per accepted delta.

---

### Task 11: Optional Tailscale Ingress and Direct-Route Measurement

**Files:**

- Create: mac/ClickBridgeMac/DirectWebSocketServer.swift
- Create: mac/ClickBridgeMacTests/DirectWebSocketServerTests.swift
- Create: relay/public/direct-transport.js
- Create: tests/manual/direct-ws-harness.html
- Modify: relay/public/app.js
- Modify: relay/public/phone-settings-store.js
- Modify: relay/test/phone-settings-store.test.js
- Modify: mac/ClickBridgeMac/AppState.swift
- Modify: mac/ClickBridgeMac/SettingsStore.swift
- Modify: mac/ClickBridgeMac/KeychainStore.swift
- Create: docs/phase-2-tailscale.md

**Interfaces:**

- DirectWebSocketServer listens only on 127.0.0.1:8787.
- Tailscale Serve terminates trusted WSS and proxies to the loopback server.
- Direct ingress uses independent DIRECT_TOKEN and the existing ActionProcessor.
- The PWA can select OCI-only or Tailscale-only; it does not hedge until Task 12. The native iOS client remains on the required OCI phone protocol unless a later separately tested change explicitly extends it.
- The UI says Tailscale until route evidence proves the connection is direct.
- DirectWebSocketServer receives immutable advertised-state updates from AppState through `updateAdvertisedState(_:)`, mirroring RelayClient; it never reads MainActor settings or permission services.

- [ ] **Step 1: Build an isolated Network.framework server spike**

DirectWebSocketServer must:

- create NWProtocolWebSocket.Options for version 13, maximum 4 KiB, and automatic protocol ping replies;
- install setClientRequestHandler before creating the listener;
- validate the exact Origin header against https://CLICK_BRIDGE_DOMAIN with no path or trailing slash;
- create and start NWListener on 127.0.0.1:8787;
- install newConnectionHandler, start each accepted NWConnection, and keep one authenticated phone generation;
- receive and send complete text messages using NWProtocolWebSocket.Metadata;
- pass every received text frame through StrictWireDecoder and close binary, oversized, or strictly invalid frames without invoking its injected `any ActionRequestSink` or `any DiagnosticCounterReading`;
- require hello within five seconds and compare DIRECT_TOKEN;
- return hello.ok plus current state;
- handle heartbeat and benchmark time sync, and answer counter requests through the separate injected DiagnosticCounterReading port;
- pass action.request to the injected ActionRequestSink with ingress tailscale; the production composition root supplies the one existing ActionProcessor;
- send the returned action.result on the same connection;
- close the old direct phone when a replacement authenticates.

AppState updates both RelayClient and DirectWebSocketServer with the same immutable MacState snapshot after the actor-owned runtime gate and permission state change. Each transport republishes only its retained snapshot on authentication.

Network.framework's server handshake exposes headers and subprotocols but is not used here to promise request-path validation. Loopback binding, Tailscale Serve, exact Origin, and DIRECT_TOKEN are the boundary. If path-level routing becomes mandatory, evaluate SwiftNIOHTTP1 plus NIOWebSocket as a separate change; do not add it preemptively.

- [ ] **Step 2: Prove browser interoperability on loopback**

Serve tests/manual/direct-ws-harness.html over plain loopback HTTP:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/tests/manual
python3 -m http.server 8790 --bind 127.0.0.1
~~~

For this isolated test only, inject http://127.0.0.1:8790 as the allowed Origin. Open http://127.0.0.1:8790/direct-ws-harness.html in Safari, connect to ws://127.0.0.1:8787, authenticate with the test DIRECT_TOKEN, send one fake action into an injected processor, receive its result, close, and reconnect. Production accepts only the exact OCI HTTPS Origin.

The automated spike and manual gate must prove actual Upgrade, a text frame in each direction, close handling, and reconnect. If this fails on the target macOS version, record the reproducible failure before considering SwiftNIO; do not add a local Node daemon.

- [ ] **Step 3: Configure Tailscale Serve and prove WSS Upgrade**

Prerequisites:

- Tailscale is signed in on phone and Mac in the same tailnet;
- MagicDNS and tailnet HTTPS are enabled;
- tailnet access permits phone-to-Mac TCP 443.

Inspect before mutation:

~~~bash
tailscale serve status --json
~~~

If status shows an unrelated handler on HTTPS 443, stop Phase 2 instead of replacing it. Otherwise generate the production DIRECT_TOKEN with openssl rand -hex 32, store it only in the phone and Mac settings, and configure:

~~~bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
tailscale serve status
~~~

From the installed OCI PWA on the physical phone, prove an authenticated WSS handshake, text request/result, close, and reconnect through the exact ts.net name. Tailscale's Serve documentation does not by itself prove WebSocket Upgrade compatibility for this application; this physical gate does.

If and only if the reverse-proxy form reproducibly fails Upgrade, test the bounded fallback:

~~~bash
tailscale serve --https=443 http://127.0.0.1:8787 off
tailscale serve --bg --tls-terminated-tcp=443 tcp://127.0.0.1:8787
tailscale serve status
~~~

Keep the first form that passes. Do not export or manually renew certificates in Swift.

- [ ] **Step 4: Add direct settings and transport ownership**

PhoneSettingsStore owns DIRECT_WSS_URL and DIRECT_TOKEN persistence; the PWA Settings screen only reads/writes through that adapter:

- require wss scheme;
- require the configured host to end in .ts.net;
- show replace and clear actions without echoing the token;
- clear closes only the Tailscale transport;
- visibility suspension applies to both sockets.

Its tests cover exact `.ts.net` URL validation, token replacement/clear without echo, storage failures, and preservation of the existing OCI token and keep-warm preferences.

The Mac stores DIRECT_TOKEN in Keychain and the exact allowed OCI Origin plus listener-enabled state in UserDefaults. `direct-transport.js` and `relay-transport.js` are configuration/validation factories around the same TransportController; they do not subclass it or duplicate authentication, heartbeat, reconnect, parsing, or visibility logic. app.js starts both controllers while visible and keeps lifecycle failures independent. TransportCoordinator still sees only the narrow transport ports and uses an injected single-path selection strategy in this task.

- [ ] **Step 5: Verify and label the actual Tailscale route**

While the phone-to-Mac WSS socket is active, capture:

~~~bash
tailscale status --json
tailscale status
tailscale ping "$PHONE_TAILSCALE_NAME"
~~~

The reverse-direction ping is supporting evidence only. Use the active connection details in status JSON and Tailscale logs/status to classify direct, peer relay, or DERP. Display Tailscale unless the active route is proven direct. Never infer direct merely because the WSS request succeeded.

- [ ] **Step 6: Run the paired Tailscale-only benchmark**

Across two cellular sessions, alternate randomized OCI-only and Tailscale-only blocks using the same 100-action mixed idle schedule and keep-warm off. Re-run clock alignment for each block. Record route evidence for every Tailscale block.

Prefer Tailscale for actions only if both sessions show:

- Posted estimatedActuationMs p95 improves by at least 15 percent and at least 10 ms;
- Posted success is at least 99 percent;
- zero physical double click;
- every claimed direct block has direct-route evidence.

Otherwise keep OCI as the preferred path. A measured Tailscale DERP path may remain as a selectable diagnostic path but must not be labeled direct.

- [ ] **Step 7: Commit**

~~~bash
git add mac relay/public relay/test tests/manual docs/phase-2-tailscale.md benchmarks docs/latency-report.md
git commit -m "feat: add measured tailscale ingress"
~~~

---

### Task 12: Optional Same-Action Dual-Path Hedging

**Files:**

- Create: relay/public/hedged-selection-strategy.js
- Create: relay/test/hedged-selection-strategy.test.js
- Modify: relay/public/app.js
- Modify: relay/public/state.js
- Modify: relay/test/phone-state.test.js
- Modify: mac/ClickBridgeMacTests/ActionProcessorTests.swift
- Modify: docs/latency-report.md
- Modify: benchmarks/measurements.csv

**Interfaces:**

- One activation creates one immutable request and sends it immediately on every ready selected transport.
- HedgedSelectionStrategy is injected into the existing action-only TransportCoordinator by app.js; the coordinator and transport implementations require no production-code modification in this task.
- First terminal result completes the phone UI.
- Later results are diagnostics only and cannot mutate the terminal state.
- The Mac actor reserves before posting and returns the exact original cached wire result to every identical later arrival.
- MacInputExecutor requires no hedging change; only its existing diagnostic counters are read for physical proof.

- [ ] **Step 1: Prove actor safety under adversarial arrival order**

Run at least 10,000 randomized test iterations:

- identical immutable request through fake OCI and fake Tailscale ingress;
- randomized arrival order, scheduling, cancellation, and caller timeout;
- fake poster called exactly once;
- every identical caller receives the exact cached ActionResult fields;
- zero id_conflict for identical fingerprints;
- changed payload always returns id_conflict;
- cache capacity fails closed;
- TTL cleanup never admits a duplicate during the protected five-minute window.

Expected: zero double-execution or cached-result mutation failures.

- [ ] **Step 2: Add coordinator and reducer tests**

Cover:

- one action ID generated before any send;
- the same immutable semantic request delivered over both ready transports;
- one unavailable transport still sends on the other;
- relay.ack never completes the action;
- first terminal result creates an absorbing terminal UI state;
- later result increments lateResultCount only;
- no new ID after send failure;
- Unknown at four seconds triggers no retry;
- hidden closes both transports and marks an in-flight result Unknown;
- visible reconnects without replay;
- pathsSent, acceptedVia, and firstResultVia remain distinct.
- HedgedSelectionStrategy returns the ready selected port list without creating an action, starting a timer, or sending; TransportCoordinator still performs the one immutable request creation and sends that same object to every returned port.

- [ ] **Step 3: Enable hedging behind a setting**

Default to the measured preferred single-path strategy until all gates pass. app.js replaces only the injected selector with HedgedSelectionStrategy when the setting is enabled. Hedged mode causes the unchanged coordinator to send immediately on both ready selected ports; it does not wait for a path timeout. If only one is ready, the strategy returns that one. The four-second result timer remains owned by TransportCoordinator.

Do not add a duplicate wire status. A second transport returning the cached posted result is a successful late delivery and is visible only in diagnostics.

- [ ] **Step 4: Run the physical double-click gate**

Take diagnostics.counters snapshots immediately before and after the run and use Octo Browser's harmless counter:

- 1,000 hedged logical actions;
- randomized artificial OCI/Tailscale delays during a separate local run;
- 1,000 Octo counter increments;
- exactly 1,000 diagnostic mouse-down posts and 1,000 mouse-up posts;
- zero second post for any action ID;
- zero automatic retry.

The Octo UI count alone is insufficient; run-evidence.csv must show counter deltas of exactly 1,000 down and 1,000 up.

- [ ] **Step 5: Collect randomized comparative data**

In each of two cellular sessions, randomize and alternate blocks of OCI-only, Tailscale-only, and Hedged using the identical 100-action mixed idle schedule, keep-warm state, phone position, and clock-alignment method. Do not compare three long runs collected at unrelated times.

Keep hedging as the default only if:

- Posted estimatedActuationMs p95 beats the better single path by at least 10 ms in both sessions;
- Posted success is at least 99 percent;
- the physical and actor double-execution gates have zero failures;
- extra battery/network use is acceptable for this personal tool.

Otherwise retain the two sockets for manual failover but select one transport per action, with OCI as the operational fallback.

- [ ] **Step 6: Commit**

~~~bash
git add relay/public relay/test mac/ClickBridgeMac mac/ClickBridgeMacTests benchmarks docs/latency-report.md
git commit -m "feat: add verified dual-path action racing"
~~~

---

### Task 13: Final Verification and Handoff

Run this task immediately after the chosen stopping point: after Task 10 for both OCI phone clients, after Task 11 for selectable PWA Tailscale, or after Task 12 for retained PWA hedging.

**Files:**

- Modify: README.md
- Verify: FINAL-PLAN.md remains at repository root
- Verify: archive/ remains non-authoritative

- [ ] **Step 1: Run the complete clean verification suite**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm ci
npm run check
~~~

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -configuration Release -derivedDataPath build build
codesign --verify --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements :- build/Build/Products/Release/ClickBridgeMac.app
~~~

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/ios
xcodegen generate --spec project.yml
xcodebuild -project ClickBridgePhone.xcodeproj -scheme ClickBridgePhone -showdestinations
~~~

Run the `ClickBridgePhone` tests on the recorded installed simulator destination and build the shared scheme for `generic/platform=iOS`.

Because local Docker is optional, perform the final Compose-model verification on the active OCI release:

~~~bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'set -eu; ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"; export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"; cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"; docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml config --quiet; docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml config --services; docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml config --images'
~~~

Expected: relay, Mac, and iOS tests pass; both native builds verify at their available gate; App Sandbox is absent from the Mac app; Compose contains no database; and only one relay replica is configured. This gate is required whether or not the optional Mac container smoke ran.

- [ ] **Step 2: Re-run the final physical and public smoke**

Using the exact Release build and physical phone:

- trusted OCI page and WSS;
- fresh Mac reconnect and ready state;
- one click in Octo;
- duplicate produces no second click;
- hidden/visible produces no replay;
- selected transport mode matches the UI label;
- diagnostics export contains no secret;
- the signed native iPhone build separately passes both volume directions, lifecycle revalidation, boundary disclosure, one-in-flight/no-queue behavior, result-only haptics, and exactly one action ID and Octo increment per accepted delta.

- [ ] **Step 3: Complete the operator README**

README.md contains:

- one-screen install/start sequence;
- exact PWA URL plus native iOS relay-URL and `PHONE_TOKEN` setup;
- the PWA fallback and the relay's one-live-phone replacement behavior;
- how to enable and disable remote control;
- where tokens are stored and how to replace them;
- how Checking clock, Clock mismatch, and Clock check unavailable differ, plus how to retry the check;
- native Ready, Not connected, Mac offline, Clock mismatch, and At volume boundary meanings;
- Control Center, headset, and AirPods volume-source behavior, plus the physical-iPhone-only acceptance limitation;
- normal 20-second heartbeat and optional keep-warm decision;
- selected transport based on measured data;
- recovery and rollback links;
- known foreground, cursor, crash-boundary, and OCI-reclamation limits.

- [ ] **Step 4: Commit the handoff**

~~~bash
git add README.md docs benchmarks
git diff --cached --check
git commit -m "docs: finalize personal click bridge handoff"
~~~

If Step 3 required no tracked change, do not create an empty commit; record the clean working tree as the handoff evidence.

---

## 9. Final Acceptance Checklist

### Functional

- [ ] A physical phone on cellular loads the OCI-hosted HTTPS PWA.
- [ ] The PWA installs to the Home Screen and works while foregrounded.
- [ ] The signed native iOS app connects to the same OCI relay with the same phone protocol while foreground-active.
- [ ] Physical iPhone Volume Up and Volume Down each create exactly one logical action ID per accepted delta.
- [ ] The native app shows Ready, Not connected, Mac offline, Clock mismatch, and At volume boundary accurately.
- [ ] The native Swift menu-bar app connects through WSS.
- [ ] The button enables only after connected, remote enabled, permission ready, and five valid clock-health responses pass.
- [ ] A missing time-sync response becomes Clock check unavailable within 3.5 seconds, shows Retry clock check, and sends no action.
- [ ] A successful Retry clock check reaches Ready; an actual skew shows Clock mismatch instead.
- [ ] One physical activation creates one logical action ID.
- [ ] One VoiceOver, Switch Control, or keyboard activation while Ready creates exactly one logical action ID.
- [ ] One accepted distinct action posts one mouse-down and one mouse-up.
- [ ] The Octo test counter increments exactly once.
- [ ] Duplicate or conflicting action IDs produce no second click.
- [ ] relay.ack and action.result remain visibly distinct.
- [ ] Unknown never triggers automatic retry.
- [ ] Unknown warns that the click may have occurred and tells the user to check the Mac.
- [ ] Long holds, pointer cancellation, and accessible activation cannot create a second action ID.

### Native clients

- [ ] CGPreflightPostEventAccess checks permission.
- [ ] CGRequestPostEventAccess is invoked only from a user action.
- [ ] The Mac rejects public plaintext ws relay URLs; loopback ws requires simulator mode.
- [ ] Input Monitoring and Screen Recording are not requested.
- [ ] Both events are created before either is posted.
- [ ] The smallest empirically reliable Octo down/up gap is recorded.
- [ ] No libnut, command process, AppleScript, or third-party input injector exists.
- [ ] Swift and PWA reject oversized, binary, unknown-field, wrong-version, and wrong-role inbound frames.
- [ ] `ios/project.yml` defines the shared `ClickBridgePhone` scheme; simulator tests and generic-device build pass.
- [ ] iOS observes only `AVAudioSession.sharedInstance().outputVolume` KVO and uses no camera or `AVCaptureEventInteraction` path.
- [ ] iOS accepts upward and downward deltas only while foreground-active, ready, and idle; background, stale-generation, duplicate, expired, and pending-action callbacks send nothing.
- [ ] iOS keeps one action in flight with no queue or retry and produces haptics only after the matching Mac terminal result.
- [ ] Physical iPhone acceptance proves hardware-volume behavior; simulator evidence is not presented as that proof.

### Design boundaries

- [ ] Node server parses/authenticates raw frames exactly once; RelayState receives validated objects and has no `ws`, parser, encoding, or environment dependency.
- [ ] PWA TransportController is the only socket-generation/reconnect/heartbeat owner.
- [ ] PWA TransportCoordinator owns actions only; ClockHealthController owns sync timers and BenchmarkSession owns diagnostic scheduling/data.
- [ ] iOS `PhoneSessionCoordinator` owns foreground/readiness/action state and depends only on injected `VolumeChangeSource`, `PhoneActionTransport`, `Clock`, `Scheduler`, and `Haptics` ports with deterministic fakes.
- [ ] iOS transport reuses the exact current phone fixtures, action-ID/expiry semantics, heartbeat, reconnect, clock-health, and result handling without relay changes.
- [ ] app.js and ClickBridgeApp are composition roots, not domain-logic or service-locator containers.
- [ ] RelayClient depends on separate ActionRequestSink, DiagnosticCounterReading, and WebSocketTransport ports, not concrete ActionProcessor or URLSession types.
- [ ] Binary WebSocket frames throw/close and are never converted into empty text.
- [ ] SettingsStore and AppState remain MainActor-isolated without `@unchecked Sendable`; Keychain failures are surfaced through SecretStoring.
- [ ] ActionProcessor is the one runtime remoteEnabled authority and remains non-suspending from reservation through result caching.
- [ ] Input construction/posting/sleep adapters are deterministic in tests while the production hot path contains no extra actor, event bus, middleware, or repository.
- [ ] OCI-only, direct-only, and hedged behavior differ only through the injected transport-selection strategy.
- [ ] No DI container, singleton registry, service locator, event bus, transport inheritance, generic command framework, or one-file-per-function abstraction was added.

### OCI

- [ ] Existing us-sanjose-1 VM architecture is recorded.
- [ ] Docker Engine and Compose pass the documented runtime gate; missing Docker on an unsupported OS stops without mutation.
- [ ] The hostname A record resolves only to the selected attached OCI IPv4; when it is ephemeral, replacement/DuckDNS recovery is documented and tested.
- [ ] The VNIC is in a public subnet with an Internet Gateway route and an attached NSG allowing stateful TCP 80/443.
- [ ] Exactly one relay and one Caddy service run.
- [ ] Caddy uses the tracked read-only Caddyfile mount and persistent data/config volumes.
- [ ] Only ports 80 and 443 are public.
- [ ] Port 8080 remains private.
- [ ] Trusted HTTPS and WSS pass externally.
- [ ] CLICK_BRIDGE_DOMAIN is an owned hostname or dedicated DuckDNS name, not sslip.io or nip.io.
- [ ] Container and VM restarts restore the application.
- [ ] Restart produces reconnect without replay.
- [ ] A failed new release rolls back with the previous release's Compose file, Caddyfile, and image.
- [ ] Recovery instructions account for possible Always Free idle reclamation.

### Data

- [ ] OCI Wi-Fi and cellular runs contain at least 100 recorded actions per condition.
- [ ] p50, p95, p99, maximum, success, rejection, and Unknown counts are reported.
- [ ] Within-component durations use their respective monotonic clocks.
- [ ] Cross-device estimated actuation uses the documented sync exchange and reports its uncertainty proxy.
- [ ] Each physical run records before/after Mac post-counter and Octo-counter evidence.
- [ ] No predicted radio, provider, or network latency appears as measured fact.
- [ ] Keep-warm remains only if its repeatable threshold passes.
- [ ] Tailscale is labeled direct only when route inspection proves it.
- [ ] Direct and hedged modes remain only if their comparative gates pass.

### Scope

- [ ] No database, persistent action state, queue, or offline action delivery exists.
- [ ] No Windows client or native mobile client other than the scoped foreground iOS app exists.
- [ ] The PWA remains available and behaviorally unchanged as the phone fallback.
- [ ] No Cloudflare Durable Object or Fly deployment exists.
- [ ] No security-hardening features beyond the minimum working boundary were added.
- [ ] FINAL-PLAN.md is the single active plan.

---

## 10. Known Limits

- The active phone client must remain foreground-active and the phone unlocked for dependable operation.
- Browser and native iOS background sending are intentionally not used; activation reconnects and revalidates before sending.
- Native iOS observes output-volume changes, not their physical source, so Control Center, wired or Bluetooth headsets, and AirPods can trigger while the app is ready.
- At 0% or 100%, the outward volume direction cannot create another delta and therefore cannot be detected; the inward direction remains available.
- Ready after every fresh Mac connection depends on five successful time-sync round trips; a missing response is surfaced as Clock check unavailable rather than leaving an unexplained disabled button.
- The Mac must be awake, unlocked, logged in, online, and running ClickBridgeMac.
- This simple version does not detect the lock screen as a separate readiness state; do not press the phone button while the Mac is locked.
- The click lands at the current cursor in the current foreground application.
- The system does not prove Octo performed a business action after receiving the native event.
- Some protected applications may ignore synthetic input.
- A rebuilt or differently signed Mac app may require permission to be granted again.
- OCI Always Free instances can be reclaimed when Oracle's documented idle criteria apply.
- Ubuntu 22.04/24.04 is the only in-plan Docker installation path. Another OS can be reused only with an already-working, reboot-persistent Docker/Compose runtime; missing Docker requires a separately approved runtime change or Ubuntu VM.
- Tailscale may use DERP or a peer relay when a direct UDP path cannot be established.
- OCI remains the PWA origin; the direct path is not independent page hosting.
- At-most-once deduplication is in memory and does not survive a Mac process crash.

---

## 11. Decision Record

| Decision | Chosen | Rejected | Reason |
| --- | --- | --- | --- |
| Primary relay | OCI us-sanjose-1 capacity using the existing VM when it passes the runtime gate | Fly.io | Already owned, fixed placement, controllable warm process |
| Deployment runtime | Verified Docker Engine plus Compose; Ubuntu 22.04/24.04 is the only installation path | Installing RHEL packages on Oracle Linux as if officially supported | Reuses a proven existing runtime without making an unsupported installation claim |
| Public address | Attached OCI IPv4 plus dedicated DuckDNS hostname; reserved IPv4 optional later | Permanent bare-IP TLS | The current ephemeral address is sufficient for one personal instance, while DuckDNS supplies the stable user-facing name and recovery path |
| Public edge | VNIC NSG plus Caddy on 80/443 | Public relay port 8080 | Only the TLS edge is host-published; relay stays Compose-private |
| Relay runtime | Node 24 LTS, exact tested patches | Node 26 Current during Milestone 1 | Prefer the stable LTS line; reconsider after Node 26 enters LTS |
| Alternative relay | None initially | Cloudflare Durable Object | Cannot pin to SJC and wake/placement latency must be measured |
| Phone clients | Foreground native iOS volume client plus unchanged PWA fallback | Replacing the PWA or changing the relay protocol for iOS | Native KVO supplies the requested volume input while both clients share one proven action contract |
| Mac receiver | Native Swift | Node, Electron, Tauri | Direct Core Graphics APIs and native lifecycle |
| Input API | Core Graphics CGEvent | libnut, cliclick, AppleScript | No process spawn or stale native add-on |
| Permission API | CGPreflight/CGRequestPostEventAccess | AXIsProcessTrustedWithOptions | Exact permission surface for posting events |
| Primary transport | Persistent WebSocket | Per-click HTTP | No new handshake on the click path |
| Direct transport | Tailscale Serve plus native loopback WebSocket | ws:// LAN socket | Valid WSS from an HTTPS PWA without mixed content |
| Dual-path safety | One actor and one action ID | Independent handlers | Atomic reserve before native side effect |
| Code architecture | Proportional SOLID with composition roots, narrow ports/adapters, reducer, coordinator, strategy, and one action actor | Full clean-architecture layers, DI container, service locator, inheritance | Clear ownership and deterministic tests without adding work to the latency-critical path |
| Persistence | None | PostgreSQL, Redis, queues | Live personal action has no durable data requirement |
| Latency truth | Physical p50/p95/p99 data | Provider estimates | Actual device and route determine performance |
| Keep-warm | Off until A/B gate | Always-on five-second traffic | Battery/network cost requires evidence |

---

## 12. Official References

- OCI San Jose region: https://docs.oracle.com/en-us/iaas/releasenotes/changes/884eb02f-f50a-4b17-9581-1c7446d9485d/index.htm
- OCI Always Free resources and idle reclamation: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- OCI public-subnet and public-IP requirements: https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingpublicIPs.htm
- OCI reserved public IP creation: https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-create.htm
- OCI reserved public IP assignment: https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-assign.htm
- OCI Network Security Groups: https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/networksecuritygroups.htm
- OCI web-server ingress rule example: https://docs.oracle.com/en/learn/publish-webserver-using-oci/index.html
- Node.js release status: https://nodejs.org/en/about/previous-releases
- Node Docker Official Image: https://hub.docker.com/_/node
- Docker Engine supported-platform matrix: https://docs.docker.com/engine/install/
- Docker Engine on Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- Docker Compose plugin on Linux: https://docs.docker.com/compose/install/linux/
- Docker packet filtering and host-firewall behavior: https://docs.docker.com/engine/network/packet-filtering-firewalls/
- Caddy Docker Official Image: https://hub.docker.com/_/caddy
- Caddy reverse proxy: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- Caddy automatic HTTPS and public-hostname behavior: https://caddyserver.com/docs/automatic-https
- Let's Encrypt IP certificate general availability: https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability.html
- Let's Encrypt registered-domain rate limits: https://letsencrypt.org/docs/rate-limits/
- Public Suffix List, including duckdns.org: https://publicsuffix.org/list/public_suffix_list.dat
- sslip.io shared certificate-limit incident: https://github.com/cunnie/sslip.io/issues/108
- Apple URLSessionWebSocketTask: https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- Apple AVAudioSession outputVolume: https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume
- Apple NWProtocolWebSocket: https://developer.apple.com/documentation/network/nwprotocolwebsocket
- Apple NWListener: https://developer.apple.com/documentation/network/nwlistener
- Apple WebSocket server handshake handler: https://developer.apple.com/documentation/network/nwprotocolwebsocket/options/setclientrequesthandler(_:handler:)
- Apple CGEvent posting: https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
- Apple CGPreflightPostEventAccess: https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()
- Apple CGRequestPostEventAccess: https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
- Tailscale connection types: https://tailscale.com/docs/reference/connection-types
- Tailscale Serve: https://tailscale.com/docs/reference/tailscale-cli/serve
- Tailscale HTTPS certificates: https://tailscale.com/docs/how-to/set-up-https-certificates
- WebSocket API: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket
- PWA installability and HTTPS requirement: https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable
- WebSocket mixed-content guidance: https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_client_applications
- Page Visibility: https://www.w3.org/TR/page-visibility-2/
- Screen Wake Lock: https://www.w3.org/TR/screen-wake-lock/
- WebKit Safari 18.4 Home Screen Wake Lock support: https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- High Resolution Time: https://www.w3.org/TR/hr-time-3/

---

## Stop Conditions

**Milestone 1 stop condition:** A physical phone on cellular opens the OCI-hosted foreground PWA, sees the Mac ready, sends one action, and the installed native Mac app posts exactly one left click into the harmless Octo Browser counter at the current cursor. Every specified protocol, permission, and remote-toggle rejection produces no native input; sleep, lock, restart, and visibility transitions produce no queued replay; and the OCI latency baseline is recorded.

**Native iOS stop condition:** The signed `ClickBridgePhone` build on a physical iPhone uses the same OCI relay and phone wire contract; foreground Volume Up and Volume Down each produce exactly one action ID and one harmless Octo increment per accepted delta; duplicate, autorepeat-while-pending, background, stale-generation, expiry, and boundary cases send no unintended action; and haptics occur only after the Mac terminal result. The unchanged PWA still passes as the fallback.

**Milestone 2 stop condition:** The PWA physical flow operates through the measured best optional path. If hedging is retained, 1,000 physical actions and 10,000 randomized actor trials produce zero double clicks, and two cellular benchmark runs show the required p95 improvement over the better single path.

**Final handoff stop condition:** Task 13 reruns relay, macOS, iOS simulator/build, OCI, PWA physical, and native physical-iPhone gates from clean inputs; records every limitation and selected optional transport; and leaves `FINAL-PLAN.md` as the only active plan with no unverified completion claim.
