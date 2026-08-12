# Click Bridge — v4 (Merged, Corrected)

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax.
> Each task ends with a verify step and a commit.
> **Tasks 5–7 require macOS and cannot be run from a Linux shell.** See *Execution Environment* below.

**Goal:** While a web app is open on a phone, one large button posts exactly one left mouse click at the Mac's current cursor position, from anywhere on the internet.

**Lineage:** This plan supersedes v3 (`PLAN (1).md`), its trimmed variant (`PLAN.md`), and the native/OCI plan (`20260811nativephonedesktopcontroller.md`). It takes the receiver design from the native plan, the relay host and phone-side latency work from v3, and the wire protocol from the native plan. Section 13 records every decision and why the losing option lost.

---

## 1. Execution Environment (read first)

| Task | Runs where | Agent-executable? |
|---|---|---|
| 1–4 (contract, relay, phone page, tests) | Any Linux/macOS shell | ✅ Yes |
| 5–6 (Swift sources, Xcode project) | Agent may **write** sources | ⚠️ Sources yes, build no |
| 5–6 (`xcodebuild`, `codesign`) | **macOS only** | ❌ Human |
| 7 (Accessibility grant, physical smoke test) | **macOS + physical phone** | ❌ Human |
| 8 (Fly.io deploy) | Any shell with `flyctl` authed | ⚠️ Needs human `fly auth` |

An agent working through a Linux VM has no `xcodebuild`, `codesign`, or TCC database. It should write every Swift file, then stop and hand Tasks 5–7 to a human rather than attempting the build.

---

## 2. Final Scope

**Version 1 contains only:**

- One phone, one Mac (macOS 13+), one Fly.io relay, one shared master secret.
- One phone button: `CLICK`. One Mac action: left click at the cursor's current position.
- Live delivery only. No persistence, no replay, no retry.
- A non-sandboxed, ad-hoc-signed personal Mac build at `/Applications/ClickBridgeMac.app`.

**Version 1 explicitly excludes:**

- Windows, Tauri, Rust, Electron, or any desktop Node process.
- A native iPhone or Android app.
- Keystrokes, shortcuts, scripts, or arbitrary commands.
- Cursor movement, phone-supplied coordinates, calibration, scroll, drag, right click, double click.
- Multiple phones, Macs, users, accounts, or device selection.
- Postgres, Redis, queues, history, offline actions, automatic retries.
- WebRTC, WebTransport, Tailscale, LAN mode, push notifications, background phone operation.
- OCI, Terraform, Docker, Caddy, self-managed TLS.
- Launch at login, auto-update, App Store distribution, production security hardening.

---

## 3. Architecture

```text
Phone Safari/Chrome
  one-button web app (PWA, home screen)
        │ HTTPS + WSS
        ▼
Fly.io machine (always-on, region nearest both devices)
  Node relay
  - serves phone files
  - holds one phone socket + one Mac socket
  - stamps relayRecvAtMs, forwards, routes result
  - stores nothing
        │ WSS
        ▼
Native Swift menu-bar app (macOS 13+)
  URLSessionWebSocketTask
  Accessibility trust check
  CGEvent leftMouseDown / leftMouseUp
```

Both clients connect **outward**. No port forwarding, no inbound firewall rule, no VPN.

---

## 4. Timing and Size Constants

Every value in one place. All three prior plans scattered these through prose; several were mutually inconsistent.

| Constant | Value | Owner | Rationale |
|---|---|---|---|
| `ACTION_EXPIRY_MS` | 2000 | Mac | Measured from `relayRecvAtMs`, **not** phone clock |
| `RELAY_PENDING_TTL_MS` | 3000 | Relay | Must exceed `ACTION_EXPIRY_MS` |
| `PHONE_RESULT_TIMEOUT_MS` | 4000 | Phone | Must exceed `RELAY_PENDING_TTL_MS` |
| `AUTH_TIMEOUT_MS` | 5000 | Relay | Close socket if no valid `hello` |
| `HEARTBEAT_MS` | 25000 | Relay | Under Fly's and mobile NAT's idle timeouts |
| `MAX_MESSAGE_BYTES` | 4096 | All | Reject larger frames |
| `KEEPWARM_MS` | 5000 | Phone | Visible-only; under typical LTE RRC inactivity timer |
| `PHONE_BACKOFF` | 250 ms → 8 s | Phone | Capped exponential |
| `MAC_BACKOFF` | 500 ms → 5 s | Mac | Capped exponential, jittered |
| `RECENT_ID_CAP` | 128 | Mac | FIFO for duplicate rejection |
| `CLOCK_SKEW_WARN_MS` | 1000 | Mac | Surface skew before it causes silent expiry |

**Invariant:** `ACTION_EXPIRY_MS < RELAY_PENDING_TTL_MS < PHONE_RESULT_TIMEOUT_MS`. A test must assert this.

---

## 5. Security Model

### 5.1 Derived per-role tokens

The three prior plans all used **one shared secret for both roles**. That lets anyone holding it authenticate as `role: "mac"`, displace the real Mac under the replace-on-reconnect rule, and silently swallow every click — or authenticate as the phone and click the user's cursor.

v4 derives two tokens from a master that **only the relay ever holds**:

```bash
MASTER=$(openssl rand -hex 32)
PHONE_TOKEN=$(printf 'phone' | openssl dgst -sha256 -hmac "$MASTER" -r | cut -d' ' -f1)
MAC_TOKEN=$(printf 'mac'   | openssl dgst -sha256 -hmac "$MASTER" -r | cut -d' ' -f1)
```

- Relay stores `AUTH_TOKEN=$MASTER` as a Fly secret, derives both at startup, compares with a constant-time equality check.
- The phone is given **only** `PHONE_TOKEN`. The Mac is given **only** `MAC_TOKEN`.
- A compromised phone cannot impersonate the Mac, and vice versa.
- Rotation: regenerate the master, `fly secrets set`, re-enter both derived tokens.

### 5.2 Token transport

The token goes in the **first WebSocket message**, never in the URL. v3 and `PLAN.md` both used `?token=<secret>`, which lands the secret in Fly's HTTP access logs, any intermediate proxy log, and browser history. Fixed here.

### 5.3 Action surface

The phone can send exactly one message shape carrying no key, coordinate, or command. Even with both tokens leaked, an attacker can only trigger one left click at wherever the cursor already is. The Mac never executes a string supplied by the phone.

---

## 6. Wire Protocol

All messages are UTF-8 JSON, at most 4096 bytes, and contain `"v": 1`.

### Authenticate

```json
{"type":"hello","v":1,"role":"phone","token":"<64-hex derived token>"}
```

`role` is `phone` or `mac`. Never logged.

### State (relay → phone)

```json
{"type":"state","v":1,"macOnline":true,"remoteEnabled":true,"permission":"ready","clockSkewMs":12}
```

`permission` is `ready`, `required`, or `unknown`.

**State ownership is directional:**

- Mac → relay: sends `remoteEnabled`, `permission`, and `clockSkewMs` after auth and whenever any changes. It does **not** author `macOnline`.
- Relay → phone: sets `macOnline` from its own Mac socket, copies the latest Mac-owned fields.
- On Mac disconnect, the relay immediately publishes `macOnline: false`.
- The relay ignores any Mac-supplied `macOnline`.
- `remoteEnabled` defaults `false` on first launch, then persists in user defaults.

### Click request (phone → relay)

```json
{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"click","issuedAtMs":1786497600000}
```

`expiresAtMs` from the native plan is **removed** — expiry is a constant policy applied by the Mac, not a phone-supplied value, so the phone cannot extend its own deadline.

### Forwarded request (relay → Mac)

```json
{"type":"action.request","v":1,"actionId":"018f63f5-…","action":"click","issuedAtMs":1786497600000,"relayRecvAtMs":1786497600031}
```

The relay stamps `relayRecvAtMs` from its own clock. **The Mac measures age against this field, not `issuedAtMs`.** This is the clock-skew fix: only relay↔Mac skew can cause a false expiry, and both run NTP. `issuedAtMs` is carried through for latency display only.

### Relay acknowledgement (relay → phone)

```json
{"type":"relay.ack","v":1,"actionId":"018f63f5-…","status":"forwarded"}
```

Status: `forwarded`, `mac_offline`, `rejected`. **This means forwarding only — never that a click happened.**

### Mac result (Mac → relay → phone)

```json
{"type":"action.result","v":1,"actionId":"018f63f5-…","status":"posted","reason":"ok","postedAtMs":1786497600078}
```

Status is `posted` or `rejected`. Rejection reasons:

```text
permission_required
remote_disabled
duplicate
expired
clock_skew
event_creation_failed
invalid_request
```

`clock_skew` is distinct from `expired`: if the Mac's offset from `relayRecvAtMs` exceeds `CLOCK_SKEW_WARN_MS`, it reports `clock_skew` so the failure reads as a clock problem, not a bug. All three prior plans would have surfaced this as a generic rejection or silent failure.

### Delivery rules

- Exactly one authenticated phone and one authenticated Mac may be active.
- A newly authenticated same-role connection closes and replaces the old one.
- The relay retains only the phone route for an in-flight request, for at most `RELAY_PENDING_TTL_MS`.
- Socket close or relay restart deletes pending routes. No replay, ever.
- The Mac holds the latest `RECENT_ID_CAP` action IDs and rejects duplicates.
- **No fan-out.** v3 forwarded to every connected receiver; with a 25 s heartbeat a stale receiver lingers and one tap fires twice. One Mac only.
- `posted` means both `CGEvent.post` calls were made. It does not prove the target app completed anything.

---

## 7. Phone Web App

Served by the relay at `https://<app>.fly.dev/`, socket derived from same origin as `wss://<app>.fly.dev/ws`. Installable to the Home Screen. Must stay foregrounded.

### Screen

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
│        Last: Posted · 74 ms      │
└──────────────────────────────────┘
```

### Behavior

- First launch asks only for the phone token. Stored locally. No account, no login service.
- Button disabled until socket connected **and** Mac reports online + enabled + `permission: ready`.
- Touch sends on `pointerdown` for low latency (10–80 ms earlier than `click`).
- **Keyboard and assistive activation use the button's normal `click` behavior.** v3 called `e.preventDefault()` on `pointerdown`, which suppresses the synthetic click that VoiceOver and Switch Control rely on. v4 instead deduplicates: `pointerdown` sets a flag with a 400 ms window; a `click` arriving inside that window is ignored, one outside it is honored. One physical press → one request, and AT still works.
- Only one request in flight. The page never retries automatically.
- Result line distinguishes `Sending`, `Forwarded`, `Posted`, `Rejected`, `Clock skew`, and `Unknown`.
- **`Posted` appears only after the Mac result**, never after `relay.ack`.
- Returning to the foreground reconnects without sending an action.
- Manifest + icons for Home Screen install. **No service worker, no offline mode.**

### Latency measures (ported from v3, corrected)

- **`touch-action: manipulation` on `body`** — removes the 300 ms double-tap delay on some Android browsers without disabling zoom.
- **`navigator.wakeLock.request("screen")`** — keeps the screen on so the page stays foregrounded and the socket unthrottled. Supported in iOS Safari 16.4+, requires a secure context (satisfied by Fly's HTTPS). The native plan listed "must stay foregrounded" as an accepted limitation; this partially solves it.
- **Keep-warm ping every `KEEPWARM_MS` (5 s), only while `document.visibilityState === "visible"`.** v3 used 1.5 s and justified it as "shorter than any reasonable beacon/DTIM period" — that reasoning is wrong, since 1.5 s is fifteen times *longer* than a 100 ms beacon interval. The real mechanism is the cellular **RRC inactivity timer** (typically 5–10 s; an idle→connected transition costs 100 s of ms) and the WiFi power-save inactivity timer. 5 s sits under typical RRC timers at roughly a third of v3's battery cost. The relay ignores these frames.
- **Measure it.** Record 30 samples with keep-warm on and 30 with it off. Keep it only if the p95 actually improves. Do not ship an unmeasured battery cost.

### States

| State | Button | Message |
|---|---|---|
| Pairing required | Disabled | Enter the phone token |
| Connecting | Disabled | Connecting… |
| Mac offline | Disabled | Open Click Bridge on the Mac |
| Accessibility missing | Disabled | Enable Accessibility on the Mac |
| Remote disabled | Disabled | Enable remote control on the Mac |
| Ready | Enabled | Tap to click |
| Request pending | Disabled | Sending / Forwarded |
| Posted | Enabled | Posted in N ms |
| Clock skew | Enabled | Mac clock is off by N ms — enable automatic date & time |
| Result timeout (4 s) | Enabled | Click may have occurred; check the Mac before retrying |

---

## 8. Native Mac Application

SwiftUI menu-bar app using `MenuBarExtra` (macOS 13+) plus a `Settings` scene.

**Menu shows:** connection state · Accessibility ready/required · `Remote control enabled` toggle · last posted or rejected action · clock skew if over threshold · Reconnect · Settings · Request Accessibility Permission · Quit.

**Settings contain only:** relay URL, and the Mac token (stored in Keychain).

`remoteEnabled` defaults **off** on first launch, is toggled from the menu bar, and persists in user defaults.

### Click execution

- Check trust with `AXIsProcessTrustedWithOptions`. Prompt **only** when the user chooses Request Accessibility Permission.
- Read `CGEvent(source: nil)?.location` immediately before clicking. This returns global display coordinates with a top-left origin — the same space `CGEvent` mouse events expect. No conversion, no `NSEvent.mouseLocation` flip.
- Create `.leftMouseDown` and `.leftMouseUp` at that same point.
- **Set `mouseEventClickState` to 1 on both events.** Synthesized events default to a click state some apps treat as invalid and ignore. None of the prior plans mention this.
- Post both through `.cghidEventTap`.
- **Gap between down and up: start at 0 ms.** If a target app ignores the click, raise to 30–50 ms. Apple's developer forums report zero-gap synthetic clicks being dropped on Big Sur and later. Make it a named constant so it is one edit, not a hunt.
- **Request Accessibility only.** Posting events needs it; Input Monitoring is for *reading* input and Screen Recording is unrelated. Request neither.
- Never listen to global input or inspect the foreground application.

### Why native Swift, not `libnut`

v3 routed input through `@nut-tree-fork/libnut` — a community fork of a package whose original scope changed hands — shipping a prebuilt native binary that you would then grant full synthetic-input rights on your machine. Apple's own `CGEvent` has no third-party dependency, no supply chain, and is faster. v3 was right that process-spawn (`cliclick`, `osascript`, 30–150 ms) was the problem; it picked the wrong fix.

---

## 9. Repository Layout

```text
clicker/
├── README.md
├── PLAN-v4.md
├── .gitignore
├── contracts/fixtures/                 # shared JSON examples, one source of truth
├── relay/
│   ├── package.json
│   ├── package-lock.json
│   ├── fly.toml
│   ├── src/protocol.js
│   ├── src/server.js
│   ├── test/protocol.test.js
│   ├── test/relay.integration.test.js
│   ├── test/phone-state.test.js
│   ├── scripts/smoke-relay.mjs
│   └── public/
│       ├── index.html
│       ├── state.js                    # pure reducer — importable ESM, testable
│       ├── app.js                       # DOM + socket wiring, imports state.js
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
│   │   └── KeychainStore.swift
│   └── ClickBridgeMacTests/
└── docs/
    ├── install-phone-web-app.md
    ├── install-macos.md
    └── smoke-test.md
```

**Notes on the layout:**

- `public/state.js` is split out because the native plan specified `phone-state.test.js` while leaving the reducer inside a `<script>`-loaded `app.js`, which `node --test` cannot import.
- No `ClickBridgeMac.entitlements`. The app ships with **no** entitlements file; see Task 6.
- One copy of the phone page. v3 kept a duplicate in `fast-server/` guaranteed to drift.
- No `infra/`, no Dockerfile, no Caddyfile — Fly builds from `package.json` with no build step.

### `.gitignore` (required before `git init`)

```gitignore
node_modules/
build/
DerivedData/
.env
*.dmg
.DS_Store
```

**Before Task 1:** `Claude.dmg` (348 MB) currently sits in the repo root. Move it out of the folder — the `*.dmg` rule protects you, but a 348 MB file has no business in the working tree.

The current root `server.js`, `receiver.js`, `index.html`, `fly.toml`, `PLAN (1).md`, and `PLAN.md` are prototype inputs. Salvage the phone page styling from `index.html` and the `fly.toml` always-on settings; delete the rest in Task 1.

---

## 10. Implementation Tasks

### Task 1 — Contract, repo, and tooling

**Files:** `README.md`, `.gitignore`, `contracts/fixtures/*`, `relay/package.json`, `relay/src/protocol.js`, `relay/test/protocol.test.js`

- [ ] Move `Claude.dmg` out of the folder. Write `.gitignore`. `git init`.
- [ ] Record scope and non-goals in `README.md`.
- [ ] Add `relay/package.json`: `"type":"module"`, `"engines":{"node":">=22"}`, dep `ws ^8.18.0`, scripts `start`, `test` (`node --test`), and **`check`** (see below).
- [ ] **Define `check`** as `node --check src/*.js && node --test`. All three prior plans ran `npm run check` in a verification block without ever defining it.
- [ ] Create fixtures for both hello roles, state, request, forwarded request, relay ack, and Mac result. Node and Swift tests both read these.
- [ ] Write **failing** tests first: valid messages, wrong token shape, wrong version, unknown type, invalid role, invalid UUID, unsupported action, expired request, clock-skew request, invalid result reason, non-JSON input, payload over 4096 bytes.
- [ ] Add a test asserting `ACTION_EXPIRY_MS < RELAY_PENDING_TTL_MS < PHONE_RESULT_TIMEOUT_MS`.
- [ ] Implement the smallest plain-ESM validator that passes.

```bash
cd relay && npm ci && npm test && npm run check
```

- [ ] Commit `feat: protocol contract and fixtures`.

### Task 2 — Stateless relay

**Files:** `relay/src/server.js`, `relay/test/relay.integration.test.js`, `relay/scripts/smoke-relay.mjs`

- [ ] Fail closed at startup if `AUTH_TOKEN` is unset or not 64 hex characters. Derive `PHONE_TOKEN` and `MAC_TOKEN` per §5.1; compare with `crypto.timingSafeEqual`.
- [ ] Serve `public/` and `GET /healthz` → `ok`. Accept WebSocket upgrade **only** on `/ws`.
- [ ] `server.on("connection", s => s.setNoDelay(true))` — disable Nagle before upgrade. Up to 40 ms of tail latency on small single packets. v3 had this; the native plan dropped it.
- [ ] Require a valid `hello` within `AUTH_TIMEOUT_MS` or close.
- [ ] Cap frames at `MAX_MESSAGE_BYTES`. Run `HEARTBEAT_MS` ping/pong; terminate any socket that missed the previous pong.
- [ ] Hold at most one phone and one Mac. A new same-role auth replaces the old.
- [ ] On `action.request` from the phone: validate, stamp `relayRecvAtMs`, forward to the Mac, reply `relay.ack`, and hold the phone route for `RELAY_PENDING_TTL_MS`.
- [ ] Ignore keep-warm frames and any unrecognized type.
- [ ] Route `action.result` back to the phone and forget the request.
- [ ] Tests: auth timeout, wrong token, wrong-role token, role replacement, Mac state changes, forwarding, mac-offline rejection, result routing, pending-route timeout, heartbeat cleanup, restart-with-no-replay.
- [ ] Smoke script emulating one phone + one Mac through a full round trip.

```bash
cd relay && npm test
AUTH_TOKEN=<64-hex> npm start
# second terminal
AUTH_TOKEN=<64-hex> node scripts/smoke-relay.mjs ws://127.0.0.1:8080/ws
```

- [ ] Commit `feat: stateless relay with derived per-role tokens`.

### Task 3 — Phone web app

**Files:** `relay/public/*`, `relay/test/phone-state.test.js`

- [ ] `public/state.js`: pure reducer + action-request builder, exported ESM, zero DOM references.
- [ ] Test the reducer against every row of the §7 state table, plus the pointerdown/click dedup window.
- [ ] `public/app.js`: DOM and socket wiring, imports `state.js`. Derive `/ws` from `location.origin`.
- [ ] Build the one-screen layout and token settings dialog. Salvage styling from the prototype `index.html`.
- [ ] Foreground reconnect with `PHONE_BACKOFF`.
- [ ] Pointer/click dedup per §7 — assistive activation must work.
- [ ] Display `relay.ack` separately from `action.result`. `PHONE_RESULT_TIMEOUT_MS` → `Unknown`.
- [ ] Add `touch-action: manipulation`, wake lock, and visible-only keep-warm.
- [ ] Manifest, theme color, icons, Apple touch icon, standalone metadata. **No service worker.**

```bash
cd relay && npm test && npm run check
```

Manual: one touch sends one request; button disabled outside Ready; background→foreground reconnects without sending; `Posted` only after the Mac result; VoiceOver activation fires exactly one click.

- [ ] Commit `feat: phone web app with dedup and latency measures`.

### Task 4 — Deploy the relay to Fly.io

**Files:** `relay/fly.toml`, `docs/install-phone-web-app.md`

- [ ] `fly platform regions`; pick the city closest to **both** devices. This is the single largest controllable latency variable: same-city ≈ 1–5 ms per hop, wrong continent ≈ 80–150 ms per hop.
- [ ] Set `auto_stop_machines = false` and `min_machines_running = 1`. Without both, Fly idles the machine, the Mac disconnects, and the next click eats a 30–60 s cold start. The existing prototype `fly.toml` already has this right — keep it.
- [ ] `shared-cpu-1x`, 256 MB is sufficient.

```bash
cd relay
fly launch --no-deploy
fly secrets set AUTH_TOKEN=<master-hex>
fly deploy
curl -fsS https://<app>.fly.dev/healthz    # → ok
```

- [ ] Confirm the token appears in **no** request URL and no log line.
- [ ] Add the page to the Home Screen.
- [ ] Commit `chore: fly.io deploy config`.

### Task 5 — Swift client (no input injection yet)

> **macOS required from here.** An agent may write every Swift file but must not attempt the build.

**Files:** `mac/ClickBridgeMac.xcodeproj`, `ClickBridgeApp.swift`, `AppState.swift`, `WireMessage.swift`, `RelayClient.swift`, `SettingsStore.swift`, `KeychainStore.swift`, tests

- [ ] macOS 13+ SwiftUI menu-bar target and test target, stable bundle identifier.
- [ ] **No App Sandbox.** Do not add the capability; ship no entitlements file. Accessibility input APIs are incompatible with sandboxing and this is not an App Store target.
- [ ] Set `CODE_SIGN_IDENTITY = "-"` in the project so Xcode ad-hoc signs during a normal build. Do **not** build with `CODE_SIGNING_ALLOWED=NO` and re-sign afterward — that path silently strips any entitlements and needs the deprecated `--deep`.
- [ ] Decode and encode every fixture in `contracts/fixtures/` exactly.
- [ ] Test the socket lifecycle through an injected transport.
- [ ] `URLSessionWebSocketTask` only; no third-party socket dependency.
- [ ] Reconnect with `MAC_BACKOFF`, jittered.
- [ ] Relay URL + `remoteEnabled` in user defaults; Mac token in Keychain. Remote control starts **disabled**.
- [ ] Track clock offset: maintain a running estimate of `macNow − relayRecvAtMs`, report it as `clockSkewMs` in `state`, and surface it in the menu when it exceeds `CLOCK_SKEW_WARN_MS`.
- [ ] Ensure Save/Reconnect creates exactly one socket and one reconnect loop.
- [ ] Build the menu and Settings UI from §8.

```bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
```

Expected: protocol and socket tests pass; the app connects but does not click.

- [ ] Commit `feat: swift menu-bar relay client`.

### Task 6 — Native click execution and packaging

**Files:** `ActionProcessor.swift`, `MacInputExecutor.swift`, `ActionProcessorTests.swift`, `docs/install-macos.md`

- [ ] `ActionProcessor.handle(request:now:)` with an injectable `InputPosting` protocol.
- [ ] Test valid, duplicate, expired, clock-skew, disabled, permission-blocked, and event-creation-failure cases against a fake poster.
- [ ] Recent-ID FIFO capped at `RECENT_ID_CAP`.
- [ ] Accessibility state check and user-triggered prompting only.
- [ ] `MacInputExecutor`: read cursor, build down/up with `mouseEventClickState = 1`, post both to `.cghidEventTap`, gap as a named constant starting at 0 ms.
- [ ] Exactly one result per accepted request. Never retry the native action.

```bash
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac -destination 'platform=macOS' test
xcodebuild -project mac/ClickBridgeMac.xcodeproj -scheme ClickBridgeMac \
  -configuration Release -derivedDataPath build build
codesign --verify --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements :- build/Build/Products/Release/ClickBridgeMac.app
```

**Expected signing state:** a valid ad-hoc signature, and the entitlements dump is **empty** — no entitlements at all, therefore no `com.apple.security.app-sandbox`.

- [ ] Copy this exact Release build to `/Applications/ClickBridgeMac.app` **before** granting Accessibility. A rebuilt ad-hoc binary has a new cdhash and needs the permission granted again — expect to toggle it off and on in System Settings after every rebuild. Document this; it is the single most confusing part of the install.
- [ ] Commit `feat: native click execution`.

### Task 7 — Physical smoke matrix

| Scenario | Required result |
|---|---|
| Mac app closed | Button disabled; no queued click |
| Mac ready | One tap posts exactly one click |
| Accessibility revoked | No click; phone reports permission required |
| Remote toggle off | No click; phone reports remote disabled |
| Duplicate test request | One native click; second result is `duplicate` |
| Mac clock set 5 s off | Phone shows clock skew, not a generic rejection |
| Relay redeploy | Both reconnect; no old action runs |
| Phone background → foreground | Reconnect; no buffered action sent |
| Connection drops after forwarding | Phone reports `Unknown` at 4 s and never retries |
| VoiceOver activation | Exactly one click |
| Two rapid taps | Two distinct actionIds, or the second is suppressed while in flight |

- [ ] Run the whole matrix from the phone **on cellular**.
- [ ] Then record 30 tap→`posted` samples; report median, p95, max.
- [ ] Repeat 30 samples with keep-warm disabled. Keep keep-warm only if p95 improves.
- [ ] Do not change transport unless these numbers show a real problem.
- [ ] Commit `docs: smoke matrix results`.

---

## 11. Acceptance Checklist

- [ ] Phone page works over Fly's trusted HTTPS and installs to the Home Screen.
- [ ] Phone asks only for the phone token; the master secret exists only as a Fly secret.
- [ ] Token never appears in a URL, a log line, or a tracked file (`git grep` clean).
- [ ] Button enabled only when the Mac is online, enabled, and Accessibility-ready.
- [ ] One physical press → one request, never an automatic retry.
- [ ] Assistive activation produces exactly one click.
- [ ] Relay permits one phone and one Mac, stores no history, and never fans out.
- [ ] Mac receiver is a native Swift menu-bar app with no third-party input dependency.
- [ ] Mac requests Accessibility only — not Input Monitoring, not Screen Recording.
- [ ] A valid action posts one left-down and one left-up at the current cursor.
- [ ] Duplicate, expired, skewed, disabled, permission-blocked, and invalid actions post no input.
- [ ] Phone distinguishes relay forwarding from Mac event posting.
- [ ] Clock skew reports as clock skew, not as a generic failure.
- [ ] Relay redeploy produces reconnect without replay.
- [ ] Phone-on-cellular → Fly → Mac smoke test passes end to end.
- [ ] Latency baseline recorded, with and without keep-warm.
- [ ] No deferred feature has been added.

---

## 12. Known Limits

- The phone page must stay foregrounded; wake lock helps but does not guarantee it.
- The Mac must be awake, logged in, online, and running Click Bridge.
- Some protected applications ignore synthetic input regardless of permissions.
- `CGEvent.post` confirms event submission, not the target app's business result.
- The click lands wherever the cursor already is.
- Every Mac rebuild invalidates the Accessibility grant.
- Fly's always-on machine is a small recurring cost (`shared-cpu-1x`, 256 MB). This is the deliberate trade against self-managing a VM.

---

## 13. Decision Record

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Receiver | Native Swift + `CGEvent` | Node + `libnut` (v3) | No supply chain; sub-ms; `libnut` is a community fork you'd grant input rights |
| Receiver | Native Swift + `CGEvent` | Node + `cliclick`/`osascript` (`PLAN.md`) | 30–150 ms spawn; `cliclick` is an uninstalled brew dep |
| Relay host | Fly.io | OCI + Docker + Caddy (native plan) | One `fly deploy` vs a VM, DNS, TLS, firewall rules, and OS patching you own — for a stateless socket forwarder |
| Relay host | Fly.io | Self-hosted VM | Also avoids OCI's undocumented instance-level iptables rules that drop 80/443 even after the security list is opened |
| Token transport | First message | URL query param (v3, `PLAN.md`) | Query strings land in Fly access logs and browser history |
| Token scope | Derived per-role | One shared secret (all three) | Prevents role impersonation and Mac displacement |
| Expiry clock | Relay `relayRecvAtMs` | Phone `issuedAtMs` (native plan) | Removes phone clock skew from the critical path entirely |
| Routing | One Mac, no fan-out | Fan-out to all receivers (v3) | A stale receiver lingers up to 25 s and double-fires |
| Touch trigger | `pointerdown` + click dedup | `pointerdown` + `preventDefault` (v3) | `preventDefault` breaks VoiceOver and Switch Control |
| Transport | WebSocket | WebRTC DataChannel | 200–400 ms ICE setup per connect; TURN cost; gains only under sustained loss |
| Transport | WebSocket | WebTransport | Now Baseline as of 2026, so v3's "iOS unsupported" reason is stale — but still no benefit for rare single-packet events |
| Scope | macOS only | macOS + Windows (v3, `PLAN.md`) | Deliberate cut. Revisit only if you actually need Windows |
| LAN / Tailscale mode | Excluded from v1 | v3 Tasks 8–9 | Both are broken as written: an HTTPS-installed PWA cannot open `ws://`, so they need `tailscale cert` or a LAN cert first |

---

## Stop Condition

Version 1 is complete when a phone on cellular opens the HTTPS web app, sees the Mac reported ready, sends one request, and the native Mac app posts exactly one left click at the current cursor — while every negative row in the §10 Task 7 matrix produces no native input and no stale replay.
