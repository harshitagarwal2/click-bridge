# Personal Phone-to-Mac Click Bridge Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a simple phone web app is open, touching one large button posts exactly one left mouse click at the Mac's current cursor position over the internet.

**Architecture:** The phone web app and a native Swift macOS menu-bar app each make an outbound secure WebSocket connection to one stateless Node.js relay in Docker on an OCI VM. The relay forwards live click requests only; the Mac posts the native click and returns a separate result.

**Tech Stack:** HTML/CSS/browser JavaScript, Node.js 24 LTS, `ws` 8.x, Swift/SwiftUI, `URLSessionWebSocketTask`, macOS Accessibility APIs, Core Graphics `CGEvent`, Docker Compose, Caddy, and one OCI compute instance.

## 1. Final Scope

Version 1 contains only:

- One phone.
- One Mac running macOS 13 or newer.
- One large phone button: `CLICK`.
- One Mac action: left click at the cursor's current position.
- One OCI relay instance.
- One manually shared token.
- Live delivery only.
- A non-sandboxed, ad-hoc-signed personal Mac build installed at `/Applications/ClickBridgeMac.app`.

Version 1 explicitly excludes:

- Windows, Tauri, Rust, Electron, or a desktop Node process.
- A native iPhone or Android application.
- Space, Enter, shortcuts, scripts, or arbitrary commands.
- Cursor movement, coordinates sent by the phone, calibration, scrolling, dragging, right click, or double click.
- Multiple phones, Macs, users, accounts, or device selection.
- PostgreSQL, Redis, queues, history, offline actions, or automatic retries.
- WebRTC, WebTransport, Tailscale, push notifications, and background phone operation.
- Launch at login, auto-update, App Store distribution, and production security-hardening work.

## 2. Phone Application Decision

The phone application should be a simple responsive web app. A native mobile application adds no useful capability for this version.

The OCI relay serves the page at:

```text
https://CLICK_BRIDGE_HOST/
```

The page derives its socket endpoint from the same origin:

```text
wss://CLICK_BRIDGE_HOST/ws
```

The user may add the page to the phone's Home Screen. The page must remain open and foregrounded while controlling the Mac.

### Phone screen

```text
┌──────────────────────────────────┐
│  ● Mac ready                  ⚙  │
│                                  │
│       ┌──────────────────┐       │
│       │                  │       │
│       │      CLICK       │       │
│       │                  │       │
│       └──────────────────┘       │
│                                  │
│   Clicks at the current cursor   │
│          Last: Posted            │
└──────────────────────────────────┘
```

### Phone behavior

- First launch asks only for the shared token.
- The token is stored locally on the phone; there is no account or login service.
- The button is disabled until the socket is connected and the Mac reports ready.
- Touch sends on `pointerdown` for low latency.
- Keyboard and assistive activation use the button's normal `click` behavior.
- Pointer/click deduplication ensures one physical press sends one request.
- Only one request may be in flight.
- The page never retries a click automatically.
- The result line distinguishes `Sending`, `Forwarded`, `Posted`, `Rejected`, and `Unknown`.
- `Posted` appears only after the Mac result, never after the relay acknowledgement.
- Returning to the foreground reconnects without sending an action.
- The page uses a manifest and icons for Home Screen installation, but no service worker or offline mode.

### Phone states

| State | Button | Message |
| --- | --- | --- |
| Pairing required | Disabled | Enter the shared token |
| Connecting | Disabled | Connecting... |
| Mac offline | Disabled | Open Click Bridge on the Mac |
| Accessibility missing | Disabled | Enable Accessibility on the Mac |
| Remote disabled | Disabled | Enable remote control on the Mac |
| Ready | Enabled | Tap to click |
| Request pending | Disabled | Sending or forwarded |
| Posted | Enabled | Posted in N ms |
| Result timeout | Enabled | Click may have occurred; check the Mac before retrying |

## 3. Runtime Architecture

```text
Phone Safari/Chrome
  one-button web app
        │ HTTPS + WSS
        ▼
OCI VM
  Caddy :443
        │
  Node relay :8080
  - serves phone files
  - holds two live sockets
  - stores no actions
        │ WSS
        ▼
Native Swift menu-bar app
  URLSessionWebSocketTask
  Accessibility check
  CGEvent mouse down/up
```

Both clients connect outward. The home router needs no port forwarding. OCI exposes only ports 80 and 443; port 8080 remains inside the Docker network.

## 4. Click Flow

1. Phone and Mac authenticate with their first WebSocket messages.
2. Relay sends the phone the Mac's online, enabled, and permission state.
3. Phone `pointerdown` creates a UUID and sends an action with a two-second expiry.
4. Relay validates and immediately forwards it to the current Mac.
5. Relay sends `relay.ack`; this means forwarding only.
6. Mac rejects invalid, expired, duplicate, disabled, or permission-blocked actions.
7. Mac reads the current cursor position and posts left-down followed by left-up at that point.
8. Mac sends `action.result` with `posted` or a precise rejection reason.
9. Relay sends that result to the phone and forgets the request.
10. No component retries, queues, or replays the action.

## 5. Minimal Wire Protocol

All messages are UTF-8 JSON, at most 4 KiB, and contain `v: 1`.

### Authenticate

```json
{"type":"hello","v":1,"role":"phone","token":"64-hex-character-token"}
```

`role` is `phone` or `mac`. The token is sent in the first message, not in the URL, and is never logged.

### Mac state

```json
{"type":"state","v":1,"macOnline":true,"remoteEnabled":true,"permission":"ready"}
```

`permission` is `ready`, `required`, or `unknown`.

State ownership is directional:

- Mac to relay: Mac sends `remoteEnabled` and `permission` after authentication and whenever either changes. It does not author `macOnline`.
- Relay to phone: relay sets `macOnline` from the current authenticated Mac socket and copies the latest Mac-owned `remoteEnabled` and `permission` values.
- On Mac disconnect, relay immediately publishes `macOnline: false`.
- `remoteEnabled` defaults to `false` on first launch and then persists in user defaults across Mac app restarts.

### Click request

```json
{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"click","issuedAtMs":1786497600000,"expiresAtMs":1786497602000}
```

### Relay acknowledgement

```json
{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"forwarded"}
```

Relay status is `forwarded`, `mac_offline`, or `rejected`.

### Mac result

```json
{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"ok"}
```

Result status is `posted` or `rejected`. Rejection reasons are:

```text
permission_required
remote_disabled
duplicate
expired
event_creation_failed
invalid_request
```

### Delivery rules

- Only one authenticated phone and one authenticated Mac may be active.
- A newly authenticated same-role connection closes and replaces the old one.
- The relay retains only the phone route for an in-flight request, for at most three seconds.
- Socket close or relay restart deletes pending routes.
- The Mac holds the latest 128 action IDs in memory and rejects duplicates.
- The relay ignores any Mac-supplied `macOnline` field and computes connectivity itself.
- Automatic date and time must be enabled on the phone and Mac for the two-second expiry check.
- `posted` means both `CGEvent.post` calls were made; it does not prove the target application completed a higher-level operation.

## 6. Native Mac Application

The receiver is a SwiftUI menu-bar app using `MenuBarExtra` and a small Settings window.

The menu shows:

- Connected, connecting, or disconnected.
- Accessibility ready or required.
- `Remote control enabled` toggle.
- Last posted or rejected action.
- Reconnect, Settings, Request Accessibility Permission, and Quit.

Settings contain only:

- Relay URL.
- Shared token, stored in Keychain.

The remote-enabled setting defaults off on the first launch, is changed from the menu bar, and persists in user defaults.

Native click behavior:

- Check trust with `AXIsProcessTrustedWithOptions`.
- Prompt only when the user chooses Request Accessibility Permission.
- Read `CGEvent(source: nil)?.location` immediately before clicking.
- Create `.leftMouseDown` and `.leftMouseUp` events at the same point.
- Post both through `.cghidEventTap`.
- Request Accessibility only; do not request Input Monitoring or Screen Recording.
- Do not listen to global input or inspect the foreground application.

## 7. Planned Repository Layout

Implementation will reorganize `/Users/harshitagarwal/Desktop/clicker` into:

```text
clicker/
├── README.md
├── contracts/fixtures/                 # shared JSON examples
├── relay/
│   ├── package.json
│   ├── package-lock.json
│   ├── src/protocol.js
│   ├── src/server.js
│   ├── test/protocol.test.js
│   ├── test/relay.integration.test.js
│   ├── scripts/smoke-relay.mjs
│   └── public/
│       ├── index.html
│       ├── app.js
│       ├── styles.css
│       ├── manifest.webmanifest
│       └── icons/
├── mac/
│   ├── ClickBridgeMac.xcodeproj/
│   ├── ClickBridgeMac/
│   │   ├── ClickBridgeApp.swift
│   │   ├── AppState.swift
│   │   ├── WireMessage.swift
│   │   ├── RelayClient.swift
│   │   ├── ActionProcessor.swift
│   │   ├── MacInputExecutor.swift
│   │   ├── SettingsStore.swift
│   │   ├── KeychainStore.swift
│   │   └── ClickBridgeMac.entitlements
│   └── ClickBridgeMacTests/
├── infra/
│   ├── Dockerfile
│   ├── compose.yaml
│   ├── Caddyfile
│   └── .env.example
└── docs/
    ├── install-phone-web-app.md
    ├── install-macos.md
    ├── oci-runbook.md
    └── smoke-test.md
```

The current root `server.js`, `receiver.js`, `index.html`, `fly.toml`, and `PLAN (1).md` are prototype inputs. During implementation, useful phone styling is incorporated and these obsolete flat files are removed.

## 8. Implementation Tasks

### Task 1: Establish the contract and repository

**Files:** `README.md`, `contracts/fixtures/*`, `relay/package.json`, `relay/src/protocol.js`, `relay/test/protocol.test.js`

**Produces:** `parseClientMessage(raw, nowMs)` and fixed JSON fixtures for Node and Swift tests.

- [ ] Record the Mac-only scope and non-goals in `README.md`.
- [ ] Create fixtures for both hello roles, ready state, request, relay acknowledgement, and Mac result.
- [ ] Write failing tests for valid messages, wrong token shape, wrong version, unknown type, invalid role, invalid UUID, unsupported action, invalid expiry, expired request, invalid result reason, non-JSON input, and payload over 4 KiB.
- [ ] Implement the smallest plain-ESM validator that passes those tests.
- [ ] Use Node 24+, `ws` 8.x, `node --test`, and a committed lockfile.

Verification:

```bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm ci
npm test
npm run check
```

Expected: protocol tests pass.

### Task 2: Build the stateless relay

**Files:** `relay/src/server.js`, `relay/test/relay.integration.test.js`, `relay/scripts/smoke-relay.mjs`

**Produces:** `/`, `/healthz`, `/ws`, one-phone/one-Mac state, live forwarding, and result routing.

- [ ] Test authentication timeout, wrong token, role replacement, Mac state changes, forwarding, Mac-offline rejection, result routing, pending timeout, heartbeat cleanup, and restart with no replay.
- [ ] Serve phone assets and `/healthz`; accept WebSocket upgrade only on `/ws`.
- [ ] Require the authenticated hello within five seconds.
- [ ] Cap messages at 4 KiB and run 25-second ping/pong cleanup.
- [ ] Forward only valid current-session actions.
- [ ] Keep pending result routes for no more than three seconds.
- [ ] Add a smoke script that emulates one phone and one Mac through a complete request/result round trip.

Verification:

Terminal 1:

```bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test
AUTH_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef npm start
```

Terminal 2:

```bash
AUTH_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef node /Users/harshitagarwal/Desktop/clicker/relay/scripts/smoke-relay.mjs ws://127.0.0.1:8080/ws
```

Expected: one forwarded request, one result, no replay.

### Task 3: Build the one-button phone web app

**Files:** `relay/public/*`, `relay/test/phone-state.test.js`

**Produces:** the phone states and behavior in Section 2.

- [ ] Test the pure UI state reducer and action-request builder.
- [ ] Build the semantic one-screen layout and token Settings dialog.
- [ ] Derive `/ws` from the page origin and authenticate automatically after pairing.
- [ ] Implement foreground reconnect with bounded exponential backoff.
- [ ] Implement one-action-in-flight pointer and keyboard activation without duplicate sends.
- [ ] Display relay acknowledgement separately from Mac result.
- [ ] Add manifest, theme colors, icons, Apple touch icon, and standalone metadata.
- [ ] Do not add a service worker or offline action behavior.

Verification:

```bash
cd /Users/harshitagarwal/Desktop/clicker/relay
npm test
npm run check
```

Manual acceptance: one touch sends one request; the button is disabled outside Ready; returning from background reconnects without sending; `Posted` appears only after the Mac result.

### Task 4: Build the Swift menu-bar client

**Files:** `mac/ClickBridgeMac.xcodeproj`, `ClickBridgeApp.swift`, `AppState.swift`, `WireMessage.swift`, `RelayClient.swift`, `SettingsStore.swift`, `KeychainStore.swift`, `ClickBridgeMac.entitlements`, Mac unit tests

**Produces:** an authenticated native WebSocket client and menu-bar state without input injection.

- [ ] Create a macOS 13+ SwiftUI menu-bar target and test target with a stable bundle identifier.
- [ ] Remove the App Sandbox capability. `com.apple.security.app-sandbox` must be absent or false because this personal app uses Accessibility input APIs and is not an App Store target.
- [ ] Decode and encode every shared protocol fixture exactly.
- [ ] Test the WebSocket lifecycle through an injected transport.
- [ ] Use `URLSessionWebSocketTask`; add no third-party socket dependency.
- [ ] Reconnect with jittered exponential backoff capped at five seconds.
- [ ] Store the relay URL and remote-enabled setting in user defaults and the token in Keychain. Remote control starts disabled on first launch and preserves the user's later choice.
- [ ] Ensure Save/Reconnect creates one socket and one reconnect loop only.
- [ ] Build the menu and Settings UI described in Section 6.

Verification:

```bash
cd /Users/harshitagarwal/Desktop/clicker
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
```

Expected: protocol and socket tests pass; the app connects but does not click yet.

### Task 5: Add native click execution and package the Mac app

**Files:** `ActionProcessor.swift`, `MacInputExecutor.swift`, `ActionProcessorTests.swift`, `docs/install-macos.md`

**Produces:** `ActionProcessor.handle(request:now:)` and an injectable `InputPosting.postLeftClickAtCurrentCursor()`.

- [ ] Test valid, duplicate, expired, disabled, permission-blocked, and event-creation-failure cases with a fake event poster.
- [ ] Keep the recent-ID FIFO capped at 128.
- [ ] Implement Accessibility state and user-triggered permission prompting.
- [ ] Implement the Core Graphics down/up sequence at the current cursor.
- [ ] Send exactly one result for every accepted request and never retry the native action.
- [ ] Document local build, `/Applications` installation, token entry, and Accessibility permission.

Verification:

```bash
cd /Users/harshitagarwal/Desktop/clicker
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - build/Build/Products/Release/ClickBridgeMac.app
codesign --verify --deep --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements :- build/Build/Products/Release/ClickBridgeMac.app
```

Expected signing state: the app has an explicit ad-hoc signature and its entitlements do not contain `com.apple.security.app-sandbox=true`. Copy this exact Release build to `/Applications/ClickBridgeMac.app` before granting Accessibility. A rebuilt ad-hoc binary may require Accessibility permission to be granted again.

Physical acceptance: with the installed app running and the cursor over a harmless test button, one phone tap increments it once; revoking Accessibility produces no click and returns `permission_required`.

### Task 6: Deploy the relay on OCI and prove the internet path

**Files:** `infra/*`, `docs/install-phone-web-app.md`, `docs/oci-runbook.md`, `docs/smoke-test.md`

**Produces:** one custom relay image plus the standard Caddy container on one OCI VM.

- [ ] Build the relay from `node:24-alpine`, install production dependencies with `npm ci --omit=dev`, run as non-root, and include a health check.
- [ ] Configure Compose with `restart: unless-stopped`; expose only Caddy ports 80/443 and persist only Caddy certificate data.
- [ ] Generate the token with `openssl rand -hex 32`, verify it is exactly 64 lowercase hexadecimal characters, and store it as `AUTH_TOKEN` in a VM-local `.env` beside `CLICK_BRIDGE_HOST`. Never bake it into the image.
- [ ] Create one OCI VM in a nearby region, attach a stable public IP, point DNS at it, install Docker Compose, and allow TCP 80/443.
- [ ] Start the stack and verify trusted HTTPS, WSS, `/healthz`, container restart, and VM restart.
- [ ] Install the phone page through Add to Home Screen.
- [ ] Run the physical smoke matrix below from the phone on cellular.

Verification:

```bash
cd /Users/harshitagarwal/Desktop/clicker
docker build -f infra/Dockerfile -t click-bridge-relay:local .
docker compose -f infra/compose.yaml config
docker compose -f infra/compose.yaml up -d --build
docker compose -f infra/compose.yaml exec -T relay wget -qO- http://127.0.0.1:8080/healthz
export CLICK_BRIDGE_HOST="$(sed -n 's/^CLICK_BRIDGE_HOST=//p' infra/.env)"
curl -fsS "https://${CLICK_BRIDGE_HOST}/healthz"
```

Expected: local and public health checks return `ok`.

## 9. Physical Smoke Matrix

| Scenario | Required result |
| --- | --- |
| Mac app closed | Phone button disabled; no queued click |
| Mac ready | One phone tap posts one click |
| Accessibility revoked | No click; phone reports permission required |
| Remote toggle off | No click; phone reports remote disabled |
| Duplicate test request | One native click; second result is duplicate |
| Relay container restart | Both clients reconnect; no old action runs |
| OCI VM restart | Caddy and relay restart; no old action runs |
| Phone background then foreground | Reconnect; no buffered action is sent |
| Connection drops after forwarding | Phone reports unknown and never retries |

After correctness passes, record 30 phone-send-to-`posted` samples and report median, p95, and maximum. Do not add a different transport unless these measurements show a real problem.

## 10. Version 1 Acceptance Checklist

- [ ] Phone page works over trusted HTTPS and can be added to the Home Screen.
- [ ] Phone asks only for the shared token.
- [ ] Phone button is enabled only when the Mac is online, enabled, and Accessibility-ready.
- [ ] One physical phone press creates one request and never retries automatically.
- [ ] Relay permits one phone and one Mac and stores no action history.
- [ ] Mac receiver is a native Swift menu-bar app.
- [ ] Mac requests Accessibility only.
- [ ] Valid action posts one left-down and one left-up at the current cursor.
- [ ] Duplicate, expired, disabled, permission-blocked, and invalid actions post no input.
- [ ] Phone distinguishes relay forwarding from Mac event posting.
- [ ] Relay and VM restarts produce reconnect without replay.
- [ ] Physical phone-on-cellular to OCI to Mac smoke test passes.
- [ ] No deferred feature has been added.

## 11. Known Limits

- The phone page must stay foregrounded.
- The Mac must be awake, logged in, online, and running Click Bridge.
- Some protected applications may ignore synthetic input.
- `CGEvent.post` confirms event submission, not the target application's business result.
- The click occurs wherever the cursor currently is.
- A public DNS hostname is required for straightforward trusted HTTPS/WSS through Caddy.

## 12. Official References

- Apple `URLSessionWebSocketTask`: https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- Apple `MenuBarExtra`: https://developer.apple.com/documentation/swiftui/menubarextra
- Apple `CGEvent.post(tap:)`: https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
- Apple Accessibility trust check: https://developer.apple.com/documentation/applicationservices/axisprocesstrustedwithoptions(_:)
- MDN WebSocket API: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket
- MDN installable PWA guidance: https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable
- Node.js test runner: https://nodejs.org/api/test.html
- Caddy reverse proxy: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy

## Stop Condition

Version 1 is complete when a physical phone on cellular opens the HTTPS web app, reports the Mac ready, sends one request, and the native Mac app posts exactly one left click at the current cursor, while every negative case in the smoke matrix produces no native input and no stale replay.
