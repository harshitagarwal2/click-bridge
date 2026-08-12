# Click Bridge — Final OCI-First, Low-Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Use the xcodebuildmcp-cli skill for the macOS build, test, run, and diagnostic steps. Steps use checkbox syntax for tracking.

**Canonical file:** `FINAL-PLAN.md`. `PLAN-v5.md` and earlier plans are preserved as historical inputs only; implementation status and future edits belong here.

**Goal:** While a foreground phone PWA is open, one physical press produces at most one native left mouse click at the Mac's current cursor position within the running-process reliability boundary, initially through the existing OCI San Jose relay and later through an optional measured Tailscale path.

**Architecture:** Milestone 1 uses one persistent WebSocket from the phone to a stateless Node.js relay on the existing OCI us-sanjose-1 VM and one persistent WebSocket from that relay to a native Swift menu-bar application. Milestone 2 adds a Tailscale Serve-backed WebSocket directly into the same Mac action processor; optional hedging sends one immutable action ID over both paths and lets the Mac's serialized processor accept the first arrival.

**Tech Stack:** Foreground HTML/CSS/JavaScript PWA, Node.js 24 LTS, ws 8.21.3, Node's built-in test runner, Swift and SwiftUI, URLSessionWebSocketTask, Network.framework, Core Graphics CGEvent, Docker Compose, Caddy, OCI Compute in us-sanjose-1, and optional Tailscale Serve.

## Global Constraints

- macOS 13 or newer only.
- One phone, one Mac, one user, one OCI relay process.
- The phone application is a foreground installable PWA, not a native mobile app.
- The OCI relay serves that PWA at one public HTTPS origin; there is no App Store submission, mobile signing, or native phone build.
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

---

## 1. Why This Is a Complete Replacement

PLAN-v4 chose Fly.io and explicitly excluded OCI, Docker, Caddy, and Tailscale. This plan replaces those decisions because an existing OCI VM is already available in the exact us-sanjose-1 region.

Current folder facts to preserve during implementation:

- The folder is not currently a Git repository.
- A partial `contracts/` and `relay/` scaffold now exists, but it is not the final protocol or deployment implementation.
- `relay/package.json` currently permits Node 22+ and `ws` with a caret range; Task 2 replaces that with the exact Node 24 and `ws@8.21.3` contract and creates the missing lockfile.
- Existing fixtures, relay state/server files, and tests are incomplete and use a different layout from the canonical browser-shared parser; treat them as scaffold to replace or reconcile through the task tests, not as verified production code.
- No `relay/public/`, native Mac application, or `deploy/oci/` deployment files exist yet.
- The flat server.js expects a public directory that does not exist in the current flat layout.
- The flat receiver.js is a macOS/Windows Node prototype and calls an unsupported raw libnut API.
- The flat relay fans out to receivers and does not implement the final result contract.
- fly.toml is obsolete for the chosen host.
- The useful visual styling in index.html may be reused, but its behavior is not the contract.
- PLAN-v5.md and earlier plans remain historical inputs. FINAL-PLAN.md is the only active implementation plan.

Do not edit the prototypes into production files. Build the replacement structure, prove it, then archive the flat prototypes in the final cleanup task.

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

Milestone 1 is independently usable and is the first stop condition. It requires no Tailscale installation on the phone.

### Milestone 2 — Measured lowest-latency path

~~~text
                         +-- Tailscale direct WSS --------+
Phone PWA -- one action -|                                |--> one Mac ActionProcessor --> CGEvent
                         +-- OCI relay WSS ---------------+
~~~

The phone keeps both sockets connected while visible. After the Tailscale path proves faster and the concurrency gate proves at-most-once execution, one press may send the same action ID on both transports. The Mac executes whichever reaches the shared actor first and returns the exact cached result to the later copy.

Milestone 2 improves latency and path resilience while the PWA is already loaded. Because OCI still hosts the PWA, it is not complete page-load failover when OCI is unavailable.

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

The page:

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

Phone setup is deliberately small:

1. Open https://CLICK_BRIDGE_DOMAIN in a current mobile browser.
2. Open Settings and enter PHONE_TOKEN once.
3. Add the site to the Home Screen.
4. Launch it from the Home Screen and keep it visible while sending clicks.

The token is the only per-phone setup. A second authenticated phone replaces the first because the product deliberately supports one live phone.

Production HTTPS is part of the working architecture, not a hardening project. Installable PWAs and Screen Wake Lock rely on a secure context, and an HTTPS page must use WSS. Wake Lock is best-effort: it prevents dimming while granted but does not guarantee foreground scheduling or keep the radio warm. For an installed iPhone Home Screen web app, require iOS/iPadOS 18.4 or newer before offering the Wake Lock toggle; older versions continue without it.

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

Generate each token independently with openssl rand -hex 32 when its milestone begins: PHONE_TOKEN and MAC_TOKEN in Task 8, DIRECT_TOKEN only in Task 10. The phone receives PHONE_TOKEN and, only for Milestone 2, DIRECT_TOKEN. The Mac receives MAC_TOKEN and, only for Milestone 2, DIRECT_TOKEN. Tokens are first-message data, never URL query parameters.

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
|   +-- ClickBridgeMac.xcodeproj/
|   +-- Config/
|   +-- ClickBridgeMac/
|   +-- ClickBridgeMacTests/
+-- deploy/
|   +-- oci/
|       +-- Dockerfile
|       +-- compose.yaml
|       +-- Caddyfile
|       +-- .env.example
+-- tests/
|   +-- manual/
|       +-- click-target.html
+-- benchmarks/
|   +-- measurements.csv
|   +-- README.md
+-- docs/
    +-- preflight.md
    +-- install-phone-pwa.md
    +-- install-macos.md
    +-- oci-deployment.md
    +-- oci-recovery.md
    +-- physical-smoke-test.md
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
relay/test/relay.integration.test.js
relay/test/phone-state.test.js
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
~~~

The root .dockerignore excludes at least .git, every .env except .env.example, node_modules, build, DerivedData, archive, benchmarks, mac, docs, tests, and *.dmg. The root build context must never transmit deploy/oci/.env to Docker.

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
                  +-> stop with complete OCI application
                  +-> Task 10 Tailscale ingress
                        -> optional Task 11 hedging and comparison
                  -> Task 12 final verification and handoff
~~~

Tasks 1 through 9 produce the complete application. Tasks 10 and 11 are latency upgrades, not prerequisites for a usable clicker.

---

### Task 1: Preflight, Repository, and Canonical Boundaries

**Files:**

- Create: README.md
- Modify: .gitignore
- Create: .dockerignore
- Create: docs/preflight.md
- Preserve: FINAL-PLAN.md
- Preserve as historical: PLAN-v5.md and earlier plan files
- Inspect only: current flat prototypes and existing OCI instance

**Interfaces:**

- Produces a recorded CPU architecture, OCI public address, domain decision, Mac and Octo versions, and final repository boundary.
- Later deployment tasks consume CLICK_BRIDGE_DOMAIN and the OCI architecture recorded here.

- [ ] **Step 1: Record the local starting state**

Run:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
pwd
git status --short
uname -m
sw_vers
node --version
npm --version
~~~

Expected: the directory is not yet a Git repository; record the actual Mac architecture and macOS version in docs/preflight.md. Task 2 requires Node 24.x and a compatible npm; install the current Node 24 LTS patch if another major is active.

- [ ] **Step 2: Inspect the existing OCI VM without changing it**

Run through the existing SSH access:

~~~bash
export OCI_SSH_TARGET='ACTUAL_SSH_USER@ACTUAL_OCI_PUBLIC_IP'
ssh "$OCI_SSH_TARGET" 'uname -m; cat /etc/os-release; docker version --format "{{.Server.Arch}}" 2>/dev/null || true; docker compose version 2>/dev/null || true'
~~~

Replace ACTUAL_SSH_USER and ACTUAL_OCI_PUBLIC_IP with the instance login recorded for this VM before running.

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

- [ ] **Step 4: Establish repository ignores before Git initialization**

Reconcile the existing .gitignore with Section 7 and create .dockerignore, then run:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
git init
git add .gitignore .dockerignore FINAL-PLAN.md README.md docs/preflight.md
git diff --cached --check
~~~

Expected: no generated files, secret files, or prototypes are staged accidentally.

- [ ] **Step 5: Document the two milestone boundaries**

README.md must state:

- Tasks 1 through 9 are Milestone 1;
- Tailscale and hedging are not enabled before Milestone 1 passes;
- FINAL-PLAN.md is the only active plan;
- all earlier files are preserved until the mandatory cleanup inside Task 9.

- [ ] **Step 6: Commit**

~~~bash
git commit -m "docs: establish final click bridge scope"
~~~

---

### Task 2: Protocol Contract and Test Fixtures

**Files:**

- Modify or replace: contracts/fixtures/*.json
- Modify: relay/package.json
- Create: relay/package-lock.json
- Modify: relay/src/constants.js
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

Generate the lockfile before using npm ci:

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm install --package-lock-only
npm ci
~~~

Expected: package-lock.json exists and npm ci exits zero.

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

Expected: FAIL because parseClientMessage does not exist.

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
git add contracts relay/package.json relay/package-lock.json relay/src/constants.js relay/public/wire-protocol.js relay/test/protocol.test.js relay/scripts/check.mjs
git commit -m "feat: define click bridge wire contract"
~~~

---

### Task 3: Stateless One-Phone, One-Mac Relay

**Files:**

- Modify or replace: relay/src/relay.js
- Modify or replace: relay/src/server.js
- Create: relay/test/relay.integration.test.js
- Create: relay/scripts/smoke-relay.mjs

**Interfaces:**

- HTTP: GET /healthz returns ok, WebSocket upgrade occurs only at /ws, and a static-file handler is tested against an injected temporary fixture until the real PWA exists in Task 4.
- Environment: PHONE_TOKEN, MAC_TOKEN, CLICK_BRIDGE_DOMAIN, and PORT defaulting to 8080.
- Holds one current phone socket, one current Mac socket, latest Mac state, temporary actionId-to-phone routes, and three-second benchmark time-sync/diagnostic routes.

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

- [ ] **Step 2: Run one targeted test and verify failure**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test -- --test-name-pattern="old socket cannot clear replacement"
~~~

Expected: FAIL because relay ownership does not exist.

- [ ] **Step 3: Implement the relay state object**

Required ownership shape:

~~~javascript
export class RelayState {
  phone = null;
  mac = null;
  macState = {remoteEnabled: false, permission: "unknown"};
  pending = new Map();

  replaceRole(role, socket) {}
  detachIfCurrent(role, socket) {}
  handlePhoneMessage(socket, message) {}
  handleMacMessage(socket, message) {}
}
~~~

All pending timers are cleared when their entry is removed. No request body is persisted outside memory.

- [ ] **Step 4: Implement the HTTP and WebSocket server**

Requirements:

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
git add relay/src relay/test/relay.integration.test.js relay/scripts/smoke-relay.mjs
git commit -m "feat: add stateless websocket relay"
~~~

---

### Task 4: Foreground Installable Phone PWA

**Files:**

- Create: relay/public/index.html
- Create: relay/public/styles.css
- Create: relay/public/state.js
- Create: relay/public/app.js
- Create: relay/public/transport-controller.js
- Create: relay/public/relay-transport.js
- Create: relay/public/transport-coordinator.js
- Create: relay/public/manifest.webmanifest
- Create: relay/public/icons/apple-touch-icon-180.png
- Create: relay/public/icons/icon-192.png
- Create: relay/public/icons/icon-512.png
- Create: relay/test/phone-state.test.js

**Interfaces:**

- createActionRequest() returns one immutable action.request with crypto.randomUUID() and a fixed two-second expiry.
- TransportController owns exactly one WebSocket generation, reconnect timer, and heartbeat timer; it owns no logical action state.
- TransportCoordinator owns the single pending logical action and remains the owner when a second transport is added in Milestone 2.
- The pure reducer owns all user-visible button and status states.

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

- [ ] **Step 2: Run and verify the first failure**

~~~bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test -- --test-name-pattern="relay ack cannot produce Posted"
~~~

Expected: FAIL because the reducer is absent.

- [ ] **Step 3: Implement the transport controller**

Required public surface:

~~~javascript
export class TransportController {
  constructor({url, token, role, createSocket, clock, random}) {}
  connect() {}
  close(reason) {}
  send(message) {}
  get state() {}
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

TransportCoordinator creates the immutable action, sends it through the selected ready transport, owns the four-second result timer, and routes ack/result events to the reducer. After a fresh Mac-ready state it owns the sequential five-exchange clock-health gate, per-exchange timeout, explicit unavailable state, manual sync-only retry, and five-minute refresh. It permits only one outstanding syncId, cancels the batch on transport generation change, and never lets a clock check create an action. Every inbound text frame passes through parseServerMessage before dispatch. Binary or invalid frames produce no UI/action side effect. Transport callbacks cannot directly mutate a terminal UI state.

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

The five-second keep-warm control exists only inside a Diagnostics section, defaults off, runs only while visible and authenticated, and never replaces the 20-second heartbeat.

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
git add relay/public relay/test/phone-state.test.js
git commit -m "feat: add foreground click controller pwa"
~~~

---

### Task 5: Native SwiftUI Shell and OCI Relay Client

**Files:**

- Create: mac/ClickBridgeMac.xcodeproj
- Create: mac/Config/Local.xcconfig.example
- Create: mac/ClickBridgeMac/ClickBridgeApp.swift
- Create: mac/ClickBridgeMac/AppState.swift
- Create: mac/ClickBridgeMac/WireMessage.swift
- Create: mac/ClickBridgeMac/StrictWireDecoder.swift
- Create: mac/ClickBridgeMac/ActionIngress.swift
- Create: mac/ClickBridgeMac/RelayClient.swift
- Create: mac/ClickBridgeMac/SettingsStore.swift
- Create: mac/ClickBridgeMac/KeychainStore.swift
- Create: mac/ClickBridgeMacTests/WireMessageTests.swift
- Create: mac/ClickBridgeMacTests/RelayClientTests.swift

**Interfaces:**

- RelayClient is the only OCI socket owner.
- ActionIngress identifies oci or tailscale and forwards validated requests to ActionProcessor.
- No input event is posted in this task.

- [ ] **Step 1: Create the macOS project**

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
    func connect() async throws
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

protocol ActionRequestSink: Sendable {
    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult
}
~~~

Production uses URLSessionWebSocketTask with text frames only. A binary, oversized, or strictly invalid inbound frame closes that relay generation and enters normal reconnect backoff without posting input. Tests use a deterministic fake.

- [ ] **Step 5: Implement one reconnect owner**

RelayClient must:

- validate the saved relay URL as wss with path /ws, no user information, query, or fragment;
- allow ws only for localhost or 127.0.0.1 when the explicit local-simulator option is enabled;
- authenticate before connected becomes true;
- keep exactly one receive loop;
- keep exactly one reconnect task;
- use jittered backoff capped at five seconds;
- cancel the old generation before Save or Reconnect starts a new one;
- publish mac.state after hello.ok and whenever permission or remoteEnabled changes;
- originate heartbeat.request every 20 seconds after authentication;
- close and reconnect when its matching heartbeat.ack is not received within 10 seconds;
- reply to clock-health and benchmark time-sync requests immediately using wall-clock receipt/send samples without blocking the action actor;
- answer diagnostics.request with a serialized ActionProcessor counter snapshot;
- never resend an action.

RelayClientTests use an injected fake clock to prove one heartbeat owner, acknowledgement cancellation, timeout reconnect, stale-generation isolation, no heartbeat while disconnected, public plaintext URL rejection, and explicit loopback-only simulator allowance. StrictWireDecoder tests prove the 4 KiB limit and exact-key rejection independently of the Node tests.

- [ ] **Step 6: Implement storage and UI state**

- relay URL and remoteEnabled in UserDefaults;
- MAC_TOKEN in Keychain;
- remoteEnabled defaults false only when no stored value exists;
- menu shows connection, permission, toggle, last result, reconnect, settings, permission action, and quit.

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

- Create: mac/ClickBridgeMac/ActionProcessor.swift
- Create: mac/ClickBridgeMac/PostEventPermissionService.swift
- Create: mac/ClickBridgeMac/MacInputExecutor.swift
- Create: mac/ClickBridgeMacTests/ActionProcessorTests.swift
- Create: mac/ClickBridgeMacTests/PermissionServiceTests.swift
- Create: mac/ClickBridgeMacTests/MacInputExecutorTests.swift

**Interfaces:**

- ActionProcessor is the only authority allowed to call InputPosting.
- InputPosting is synchronous so the actor never suspends inside the reserve-to-result critical section.
- PostEventPermissionChecking wraps the Core Graphics permission functions.

- [ ] **Step 1: Write the actor concurrency tests first**

Required protocol:

~~~swift
protocol InputPosting: Sendable {
    func postLeftClickAtCurrentCursor() -> InputPostOutcome
    func diagnosticPostCounts() -> InputPostCounts
}

actor ActionProcessor: ActionRequestSink {
    func receive(
        _ request: ActionRequest,
        via ingress: ActionIngress
    ) async -> ActionResult

    func diagnosticPostCounts() -> InputPostCounts
}
~~~

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

- [ ] **Step 2: Verify the concurrency test fails**

~~~bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' -only-testing:ClickBridgeMacTests/ActionProcessorTests test
~~~

Expected: FAIL because ActionProcessor does not exist.

- [ ] **Step 3: Implement the non-reentrant critical path**

Algorithm:

1. Validate the click-only request, exact lifetime relation, and current expiry; compute its fingerprint.
2. Remove completed entries older than five minutes.
3. If an entry exists with another fingerprint, return id_conflict.
4. If a completed identical entry exists, return the exact cached ActionResult without changing any field.
5. If every cache slot is protected by an unexpired or processing entry, return capacity_exceeded.
6. Insert processing state before checking permission or posting.
7. Check remoteEnabled.
8. Check PostEvent permission.
9. Call the synchronous input poster at most once.
10. Replace processing with the terminal result before returning.
11. Never await between steps 6 and 10.

- [ ] **Step 4: Implement the correct permission API**

~~~swift
struct PostEventPermissionService {
    func isGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    func requestFromUserAction() -> Bool {
        CGRequestPostEventAccess()
    }
}
~~~

Request permission only when the user chooses the menu action. Refresh state on app activation, menu display, after a request, and immediately before posting.

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

- Create: tests/manual/click-target.html
- Create: docs/install-macos.md
- Create: docs/physical-smoke-test.md

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

- Create: deploy/oci/Dockerfile
- Create: deploy/oci/compose.yaml
- Create: deploy/oci/Caddyfile
- Create: deploy/oci/.env.example
- Create: docs/oci-deployment.md
- Create: docs/oci-recovery.md

**Interfaces:**

- Public: TCP 80 and 443 to Caddy.
- Private Compose network: Caddy to relay:8080.
- Inputs: CLICK_BRIDGE_DOMAIN, CLICK_BRIDGE_RELEASE, PHONE_TOKEN, MAC_TOKEN.
- No application volume or database.

- [ ] **Step 1: Gate the OCI operating system and network prerequisites**

Run this read-only inspection before changing the VM:

~~~bash
export OCI_SSH_TARGET='ACTUAL_SSH_USER@ACTUAL_OCI_PUBLIC_IP'
ssh "$OCI_SSH_TARGET" 'set -eu; uname -m; cat /etc/os-release; ip route; command -v rsync || true; docker version 2>/dev/null || true; docker compose version 2>/dev/null || true; systemctl is-enabled docker 2>/dev/null || true; sudo ss -ltnp | awk "NR == 1 || \$4 ~ /:(80|443|8080)$/"'
~~~

Record the output in `docs/oci-deployment.md`. Docker's current supported-platform matrix does not list Oracle Linux; do not present the RHEL repository as an officially supported Oracle Linux installation. The runtime gate passes in either of these cases:

1. `/etc/os-release` reports Ubuntu 22.04 or 24.04 LTS, so Step 2 can install or verify Docker through its official Ubuntu repository; or
2. another OS already has Docker Engine and Compose v2, and `docker version`, `docker compose version`, `docker run --rm hello-world`, and `systemctl is-enabled docker` all pass without installing or replacing the engine. Step 12 supplies the controlled reboot/recheck before final acceptance.

If neither case passes, stop this task without changing the VM and choose one of these separately authorized branches:

1. provision or select an Ubuntu 22.04/24.04 instance in OCI us-sanjose-1 and continue this exact Docker Compose plan; or
2. revise Task 8 into a separately reviewed Podman/Quadlet or manually maintained Docker-static-binary deployment.

Do not reimage, terminate, or replace the existing VM automatically. Also verify in OCI that the instance VNIC is in a public subnet with an Internet Gateway and a `0.0.0.0/0` route to that gateway. Missing network prerequisites block deployment until corrected.

- [ ] **Step 2: Install Docker Engine when the VM uses the canonical Ubuntu path**

Skip package installation when `docker version` and `docker compose version` already succeed. Otherwise, run Docker's Ubuntu repository procedure on the VM:

~~~bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl rsync
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
ARCHITECTURE="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" "$ARCHITECTURE" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
~~~

Disconnect and reconnect once so the Docker group membership is active, then verify:

~~~bash
docker version
docker compose version
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
- relay receives PHONE_TOKEN, MAC_TOKEN, and CLICK_BRIDGE_DOMAIN from the ignored env file;
- Caddy receives CLICK_BRIDGE_DOMAIN from Compose interpolation of the same ignored env file;
- relay health check.

Caddyfile:

~~~caddyfile
{$CLICK_BRIDGE_DOMAIN} {
    encode zstd gzip
    reverse_proxy relay:8080
}
~~~

Caddy must pass through the relay's canonical Content-Security-Policy unchanged. Do not maintain a second policy string here.

- [ ] **Step 4: Validate the containers locally before touching OCI**

Create ignored deploy/oci/.env from .env.example with CLICK_BRIDGE_DOMAIN=example.test, CLICK_BRIDGE_RELEASE=local, and the two fixed test tokens from Task 3. Do not use real deployment tokens for local Compose validation.

~~~bash
cd /Users/harshitagarwal/Desktop/clicker
docker build -f deploy/oci/Dockerfile -t click-bridge-relay:local .
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --quiet
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --services
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --images
docker run --rm --detach --name click-bridge-relay-smoke -p 127.0.0.1:18080:8080 -e PHONE_TOKEN=1111111111111111111111111111111111111111111111111111111111111111 -e MAC_TOKEN=2222222222222222222222222222222222222222222222222222222222222222 click-bridge-relay:local
curl -fsS http://127.0.0.1:18080/healthz
docker stop click-bridge-relay-smoke
~~~

Expected: the relay image builds, the Compose model validates, and relay-only health passes. Do not start the production-domain Caddyfile locally: DNS is not local and Caddy would attempt public ACME. TLS/Caddy validation occurs on OCI after DNS and firewall readiness.

- [ ] **Step 5: Attach a durable OCI address and instance-scoped ingress**

Use the OCI Console and record the resulting resource names and public IPv4 in `docs/oci-deployment.md`:

1. Under **Networking > IP management > Reserved public IPs**, create a regional reserved IPv4 in the instance's compartment.
2. Open **Compute > Instances > the relay instance > Attached VNICs > the primary VNIC > IPv4 Addresses**.
3. Edit the primary private IP and assign the reserved public IP. An ephemeral public IP cannot be converted in place; detach it and attach the new reserved address, then update `OCI_SSH_TARGET`.
4. Under the instance VCN, create or reuse a Network Security Group attached only to this VNIC.
5. Add two stateful ingress rules with source CIDR `0.0.0.0/0`, protocol TCP, all source ports, and destination port `80` for HTTP and `443` for HTTPS/WSS.
6. Keep the existing SSH path usable. Do not add an OCI ingress rule for `8080`.

A subnet security list is acceptable only if its wider subnet scope is explicitly recorded; the instance-scoped NSG is the default. Do not add IPv6 ingress unless a public IPv6 address and end-to-end IPv6 path will be tested.

- [ ] **Step 6: Choose the hostname and verify DNS before Caddy starts**

Point `CLICK_BRIDGE_DOMAIN` to the reserved OCI public IPv4. An owned domain is the default; a dedicated DuckDNS hostname is the free fallback. Do not use `sslip.io` or `nip.io` as the permanent address because certificate issuance for their shared registered domains can be affected by other users.

Let's Encrypt supports short-lived IP-address certificates as of 2026, but the stock Caddy automatic-public-HTTPS path used by this plan is hostname-based. Do not add a second ACME client and six-day IP-certificate renewal path to avoid choosing a hostname.

Verify from the Mac, not only from the VM:

~~~bash
export CLICK_BRIDGE_DOMAIN='ACTUAL_CLICK_BRIDGE_DOMAIN'
export OCI_RESERVED_PUBLIC_IP='ACTUAL_RESERVED_PUBLIC_IPV4'
test "$(dig +short A "$CLICK_BRIDGE_DOMAIN" | tail -n 1)" = "$OCI_RESERVED_PUBLIC_IP"
test -z "$(dig +short AAAA "$CLICK_BRIDGE_DOMAIN")"
~~~

Expected: the A record is exactly the reserved OCI IPv4. The AAAA record is empty unless the VM has a configured, firewall-open, tested public IPv6 address. Remove stale AAAA records before Caddy startup. Do not start Caddy until this passes; repeated ACME failures create avoidable backoff.

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

On a reused Oracle Linux VM whose existing Docker runtime passed Step 1, inspect `firewalld`, select the single active zone, and add HTTP/HTTPS only when it is running:

~~~bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
ACTIVE_ZONE="$(sudo firewall-cmd --get-active-zones | awk 'NR == 1 {print $1}')"
test -n "$ACTIVE_ZONE"
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=http
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=https
sudo firewall-cmd --reload
sudo firewall-cmd --zone="$ACTIVE_ZONE" --list-services
~~~

If neither UFW nor `firewalld` is the active host-firewall tool, stop and record the actual tool before changing rules; do not paste rules for the wrong distribution.

Stop if another process already owns port 80 or 443; identify and resolve that service deliberately rather than killing it from this plan. Docker-published ports can bypass UFW, so the actual boundary is both of the following: OCI permits only 80/443, and Compose publishes only Caddy's 80/443 mappings. The relay uses `expose: 8080` on the private Compose network and has no host `ports` entry.

- [ ] **Step 8: Generate and install the role-token environment**

On the Mac, generate a temporary mode-0600 transfer file without printing either token:

~~~bash
umask 077
export CLICK_BRIDGE_DOMAIN='ACTUAL_CLICK_BRIDGE_DOMAIN'
PHONE_TOKEN="$(openssl rand -hex 32)"
MAC_TOKEN="$(openssl rand -hex 32)"
{
  printf 'CLICK_BRIDGE_DOMAIN=%s\n' "$CLICK_BRIDGE_DOMAIN"
  printf 'PHONE_TOKEN=%s\n' "$PHONE_TOKEN"
  printf 'MAC_TOKEN=%s\n' "$MAC_TOKEN"
} > /private/tmp/click-bridge-secrets.env
test "$(wc -l < /private/tmp/click-bridge-secrets.env | tr -d ' ')" = 3
~~~

Transfer it and install the VM copy outside every release:

~~~bash
export OCI_SSH_TARGET='ACTUAL_SSH_USER@ACTUAL_RESERVED_PUBLIC_IPV4'
scp /private/tmp/click-bridge-secrets.env "$OCI_SSH_TARGET:/tmp/click-bridge-secrets.env"
ssh "$OCI_SSH_TARGET" 'sudo install -d -m 0700 -o "$USER" -g "$(id -gn)" /opt/click-bridge/shared && install -m 0600 /tmp/click-bridge-secrets.env /opt/click-bridge/shared/secrets.env && rm -f /tmp/click-bridge-secrets.env && test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600'
~~~

Keep `/private/tmp/click-bridge-secrets.env` at mode 0600 only until the Step 11 WSS smoke and client setup finish. Configure the phone with `PHONE_TOKEN` and the Mac Keychain with `MAC_TOKEN`; after the smoke passes, remove that exact temporary file and unset the two shell variables. Never place either token in a URL, tracked file, shell transcript, or deployment log. Generate `DIRECT_TOKEN` only if Task 10 begins.

- [ ] **Step 9: Transfer an immutable release**

Define the real values recorded in Task 1 before running the commands:

~~~bash
export OCI_SSH_TARGET='ACTUAL_SSH_USER@ACTUAL_RESERVED_PUBLIC_IPV4'
export CLICK_BRIDGE_DOMAIN='ACTUAL_CLICK_BRIDGE_DOMAIN'
export CLICK_BRIDGE_RELEASE="$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$CLICK_BRIDGE_RELEASE" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || exit 1
ssh "$OCI_SSH_TARGET" 'sudo mkdir -p /opt/click-bridge/releases /opt/click-bridge/shared && sudo chown -R "$USER":"$USER" /opt/click-bridge && command -v rsync && docker version && docker compose version && test -f /opt/click-bridge/shared/secrets.env'
ssh "$OCI_SSH_TARGET" "test ! -e /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE && mkdir /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
rsync -az --delete --exclude .git --exclude node_modules --exclude build --exclude DerivedData --exclude deploy/oci/.env /Users/harshitagarwal/Desktop/clicker/ "$OCI_SSH_TARGET":/opt/click-bridge/releases/"$CLICK_BRIDGE_RELEASE"/
~~~

Replace every ACTUAL value before execution and verify `CLICK_BRIDGE_RELEASE` matches only fourteen UTC digits plus `T` and `Z`. The `--delete` target is the newly created exact release directory; never point it at `/opt/click-bridge`, a home directory, or an unresolved variable. A failed prerequisite check stops deployment; do not improvise a different container engine inside this step.

- [ ] **Step 10: Build and start the release on the OCI VM**

Build on the VM so Docker selects the VM's recorded amd64 or arm64 architecture:

~~~bash
export CLICK_BRIDGE_RELEASE='ACTUAL_RELEASE_FROM_STEP_9'
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
cp /opt/click-bridge/shared/secrets.env deploy/oci/.env
printf '\nCLICK_BRIDGE_RELEASE=%s\n' "$CLICK_BRIDGE_RELEASE" >> deploy/oci/.env
chmod 0600 deploy/oci/.env
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --quiet
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml build --pull
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml up -d
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml ps
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
docker volume ls --filter label=com.docker.compose.project=click-bridge
~~~

Expected: exactly one relay and one Caddy container run. Caddy publishes host ports 80 and 443; relay port 8080 is absent from the host-published-port list. The named Caddy data and config volumes exist so certificate state survives container replacement.

- [ ] **Step 11: Verify HTTPS, WSS, and the public port boundary**

From the Mac:

~~~bash
export CLICK_BRIDGE_DOMAIN='ACTUAL_CLICK_BRIDGE_DOMAIN'
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
rm -f /private/tmp/click-bridge-secrets.env
~~~

On the VM, verify the bindings and logs:

~~~bash
export CLICK_BRIDGE_RELEASE='ACTUAL_RELEASE_FROM_STEP_9'
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml ps
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
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

- [ ] **Step 12: Verify rollback and recovery behavior**

Before bringing up a later release, capture the current release:

~~~bash
cp /opt/click-bridge/current-release /opt/click-bridge/previous-release
~~~

If the new release fails its smoke test, roll back with the previous release's own Compose file, Caddyfile, env selector, and retained image:

~~~bash
export PREVIOUS_RELEASE="$(cat /opt/click-bridge/previous-release)"
cd "/opt/click-bridge/releases/$PREVIOUS_RELEASE"
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml up -d --no-build
docker compose -p click-bridge --env-file deploy/oci/.env -f deploy/oci/compose.yaml ps
printf '%s\n' "$PREVIOUS_RELEASE" > /opt/click-bridge/current-release
~~~

The first deployment has no previous application release, so its recovery path is a clean rebuild from its immutable release directory plus shared/secrets.env. Do not delete retained release directories or tagged images until a newer release has passed reboot recovery.

Test:

- relay-container restart;
- Caddy-container restart;
- full OCI VM reboot.

After requesting the reboot, reconnect through the reserved IP, rerun the public health/WSS smoke, and confirm Docker's enabled service plus each container's `restart: unless-stopped` policy restored the stack.

After each:

- both clients reconnect;
- no old action executes;
- /healthz returns ok;
- exactly one relay replica is running.

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
- Modify: relay/public/app.js
- Modify: relay/public/transport-coordinator.js
- Modify: relay/public/wire-protocol.js
- Modify: mac/ClickBridgeMac/RelayClient.swift
- Modify: mac/ClickBridgeMac/ActionProcessor.swift
- Modify: mac/ClickBridgeMac/MacInputExecutor.swift
- Create: docs/latency-report.md
- Create: archive/README.md
- Modify: docs/physical-smoke-test.md
- Modify: README.md
- Move: historical plans to archive/plans/
- Move: flat prototypes to archive/prototypes/

**Interfaces:**

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

The PWA Diagnostics screen owns sync collection, benchmark scheduling, in-memory rows, counter snapshots, and explicit CSV export. Take one diagnostics.counters snapshot before and after a run, outside the timed action sequence, and write the pair to run-evidence.csv. Unit tests use fake clocks/transports and prove export column order, no secret fields, counter-delta calculation, and no benchmark-generated automatic retry.

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

- [ ] **Step 8: Make FINAL-PLAN.md canonical before the Milestone 1 stop**

Move these historical inputs:

- PLAN.md, PLAN (1).md, PLAN-v4.md, PLAN-v5.md, and 2026-08-11-native-phone-desktop-controller.md to archive/plans/ when present;
- flat server.js, receiver.js, index.html, fly.toml, and `_scaffold.tgz` to archive/prototypes/ when present.

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

Stop here if a simple, working personal application is sufficient.

---

### Task 10: Optional Tailscale Ingress and Direct-Route Measurement

**Files:**

- Create: mac/ClickBridgeMac/DirectWebSocketServer.swift
- Create: mac/ClickBridgeMacTests/DirectWebSocketServerTests.swift
- Create: relay/public/direct-transport.js
- Create: tests/manual/direct-ws-harness.html
- Modify: relay/public/transport-coordinator.js
- Modify: relay/public/app.js
- Modify: mac/ClickBridgeMac/AppState.swift
- Modify: mac/ClickBridgeMac/SettingsStore.swift
- Modify: mac/ClickBridgeMac/KeychainStore.swift
- Create: docs/phase-2-tailscale.md

**Interfaces:**

- DirectWebSocketServer listens only on 127.0.0.1:8787.
- Tailscale Serve terminates trusted WSS and proxies to the loopback server.
- Direct ingress uses independent DIRECT_TOKEN and the existing ActionProcessor.
- The phone can select OCI-only or Tailscale-only; it does not hedge until Task 11.
- The UI says Tailscale until route evidence proves the connection is direct.

- [ ] **Step 1: Build an isolated Network.framework server spike**

DirectWebSocketServer must:

- create NWProtocolWebSocket.Options for version 13, maximum 4 KiB, and automatic protocol ping replies;
- install setClientRequestHandler before creating the listener;
- validate the exact Origin header against https://CLICK_BRIDGE_DOMAIN with no path or trailing slash;
- create and start NWListener on 127.0.0.1:8787;
- install newConnectionHandler, start each accepted NWConnection, and keep one authenticated phone generation;
- receive and send complete text messages using NWProtocolWebSocket.Metadata;
- pass every received text frame through StrictWireDecoder and close binary, oversized, or strictly invalid frames without invoking ActionProcessor;
- require hello within five seconds and compare DIRECT_TOKEN;
- return hello.ok plus current state;
- handle heartbeat, benchmark time sync, and diagnostic counter snapshots;
- pass action.request to the existing ActionProcessor with ingress tailscale;
- send the returned action.result on the same connection;
- close the old direct phone when a replacement authenticates.

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

The PWA Settings screen owns DIRECT_WSS_URL and DIRECT_TOKEN in localStorage:

- require wss scheme;
- require the configured host to end in .ts.net;
- show replace and clear actions without echoing the token;
- clear closes only the Tailscale transport;
- visibility suspension applies to both sockets.

The Mac stores DIRECT_TOKEN in Keychain and the exact allowed OCI Origin plus listener-enabled state in UserDefaults. direct-transport.js remains transport-only. The existing TransportCoordinator owns the one pending logical action, starts both controllers while visible, keeps failures independent, and selects one path per action in this task.

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

### Task 11: Optional Same-Action Dual-Path Hedging

**Files:**

- Modify: relay/public/transport-coordinator.js
- Modify: relay/public/state.js
- Modify: relay/test/phone-state.test.js
- Modify: mac/ClickBridgeMacTests/ActionProcessorTests.swift
- Modify: mac/ClickBridgeMac/MacInputExecutor.swift
- Modify: docs/latency-report.md
- Modify: benchmarks/measurements.csv

**Interfaces:**

- One activation creates one immutable request and sends it immediately on every ready selected transport.
- First terminal result completes the phone UI.
- Later results are diagnostics only and cannot mutate the terminal state.
- The Mac actor reserves before posting and returns the exact original cached wire result to every identical later arrival.

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

- [ ] **Step 3: Enable hedging behind a setting**

Default to the measured preferred single path until all gates pass. Hedged mode sends immediately on both ready transports; it does not wait for a path timeout. If only one is ready, send once on that path. The four-second result timer remains owned by TransportCoordinator.

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

### Task 12: Final Verification and Handoff

Run this task immediately after the chosen stopping point: after Task 9 for OCI-only, after Task 10 for selectable Tailscale, or after Task 11 for retained hedging.

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
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --quiet
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --services
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --images
~~~

Expected: tests pass, the Release app verifies, App Sandbox is absent, Compose contains no database, and only one relay replica is configured.

- [ ] **Step 2: Re-run the final physical and public smoke**

Using the exact Release build and physical phone:

- trusted OCI page and WSS;
- fresh Mac reconnect and ready state;
- one click in Octo;
- duplicate produces no second click;
- hidden/visible produces no replay;
- selected transport mode matches the UI label;
- diagnostics export contains no secret.

- [ ] **Step 3: Complete the operator README**

README.md contains:

- one-screen install/start sequence;
- exact phone URL;
- how to enable and disable remote control;
- where tokens are stored and how to replace them;
- how Checking clock, Clock mismatch, and Clock check unavailable differ, plus how to retry the check;
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

### Native

- [ ] CGPreflightPostEventAccess checks permission.
- [ ] CGRequestPostEventAccess is invoked only from a user action.
- [ ] The Mac rejects public plaintext ws relay URLs; loopback ws requires simulator mode.
- [ ] Input Monitoring and Screen Recording are not requested.
- [ ] Both events are created before either is posted.
- [ ] The smallest empirically reliable Octo down/up gap is recorded.
- [ ] No libnut, command process, AppleScript, or third-party input injector exists.
- [ ] Swift and PWA reject oversized, binary, unknown-field, wrong-version, and wrong-role inbound frames.

### OCI

- [ ] Existing us-sanjose-1 VM architecture is recorded.
- [ ] Docker Engine and Compose pass the documented runtime gate; missing Docker on an unsupported OS stops without mutation.
- [ ] A reserved public IPv4 is attached to the instance VNIC and the hostname A record resolves only to it.
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
- [ ] No Windows or native mobile application exists.
- [ ] No Cloudflare Durable Object or Fly deployment exists.
- [ ] No security-hardening features beyond the minimum working boundary were added.
- [ ] FINAL-PLAN.md is the single active plan.

---

## 10. Known Limits

- The phone page must remain visible and unlocked for dependable operation.
- Browser and iOS background scheduling are intentionally not used.
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
| Public address | OCI reserved IPv4 plus owned/DuckDNS hostname | Ephemeral address or permanent bare IP | DNS remains stable across instance recovery and Caddy manages hostname TLS |
| Public edge | VNIC NSG plus Caddy on 80/443 | Public relay port 8080 | Only the TLS edge is host-published; relay stays Compose-private |
| Relay runtime | Node 24 LTS, exact tested patches | Node 26 Current during Milestone 1 | Prefer the stable LTS line; reconsider after Node 26 enters LTS |
| Alternative relay | None initially | Cloudflare Durable Object | Cannot pin to SJC and wake/placement latency must be measured |
| Phone client | Foreground PWA | Native phone app | One button and WebSocket need no native mobile capability |
| Mac receiver | Native Swift | Node, Electron, Tauri | Direct Core Graphics APIs and native lifecycle |
| Input API | Core Graphics CGEvent | libnut, cliclick, AppleScript | No process spawn or stale native add-on |
| Permission API | CGPreflight/CGRequestPostEventAccess | AXIsProcessTrustedWithOptions | Exact permission surface for posting events |
| Primary transport | Persistent WebSocket | Per-click HTTP | No new handshake on the click path |
| Direct transport | Tailscale Serve plus native loopback WebSocket | ws:// LAN socket | Valid WSS from an HTTPS PWA without mixed content |
| Dual-path safety | One actor and one action ID | Independent handlers | Atomic reserve before native side effect |
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

**Milestone 2 stop condition:** The same physical flow operates through the measured best path. If hedging is retained, 1,000 physical actions and 10,000 randomized actor trials produce zero double clicks, and two cellular benchmark runs show the required p95 improvement over the better single path.
