# Click Bridge — Complete Implementation Plan (v3, Internet-First)

> **For agentic workers:** implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax for tracking. Each task ends with a verify step and a commit.

---

## Goal

Tap a button on a phone → a Mac or Windows laptop fires a real mouse click or keystroke,
over the internet, with the lowest achievable latency from anywhere.

---

## What changed from previous plans

| Earlier plan | This plan |
|---|---|
| OCI / Oracle Cloud, Terraform, Postgres, OIDC, FCM, Tauri, 20 tasks | Removed entirely |
| LAN-only fast path | Internet is the primary path |
| Cloud relay only | Cloud relay + optional Tailscale for direct device-to-device |
| Process-spawn input (30–150 ms) | In-process native input (<1 ms) |
| `click` event on phone (waits for finger lift) | `pointerdown` (instant on finger land) |
| No Nagle control | `TCP_NODELAY` on every socket |
| No WiFi keep-warm | 1.5 s ping keeps radio awake |

---

## Architecture

Three small pieces:

```
phone PWA  ──[wss]──▶  relay (cloud, close to both devices)  ──[wss]──▶  receiver (laptop)
                                                                              │
                                                                         libnut native call
                                                                         (<1 ms, in-process)
```

Or, with Tailscale, the relay can run ON the laptop and the phone dials it
over a direct WireGuard tunnel — removing the cloud relay hop entirely:

```
phone PWA  ──[WireGuard / Tailscale]──▶  laptop (relay + receiver in one process)
                                                │
                                           libnut native call
```

---

## Latency budget (internet path, honest numbers)

| Layer | Optimised | Unoptimised |
|---|---|---|
| Phone touch → JS event | ~10–20 ms | ~10–20 ms (hardware floor, irreducible) |
| `pointerdown` vs `click` | +0 ms | +10–80 ms (saved) |
| WiFi radio wake (first tap) | +0 ms (keep-warm) | +50–150 ms |
| Phone WiFi → relay | ~20–60 ms | ~20–60 ms (geography) |
| Relay → laptop | ~20–60 ms | ~20–60 ms (geography) |
| TCP Nagle | +0 ms (disabled) | +0–40 ms (removed) |
| Input injection | <1 ms (libnut) | +30–150 ms (process spawn) |
| **End-to-end total** | **~50–140 ms** | **~120–500 ms** |

Key insight: relay region is the dominant controllable variable. A relay in
the same city as both devices gives ~1–5 ms each way. The wrong continent
gives 80–150 ms each way. Pick the Fly.io region closest to you.

---

## Transport decision (why plain WebSocket)

Three browser transports exist; this plan uses **WebSocket** and that is the
right call for this use case. Here is why the others were rejected:

**WebRTC DataChannel** — peer-to-peer SCTP over DTLS.
  - 200–400 ms of ICE negotiation overhead on every new connection.
  - Needs a STUN server to find the peer path, and a TURN server when
    direct-path fails (~10–15% of connections on mobile networks).
  - Does beat WebSocket slightly under sustained packet loss (unordered/
    unreliable mode skips retransmit waits) — but click events are rare,
    single-packet, and loss doesn't cascade; the gain doesn't justify the
    complexity and setup cost.
  - Mobile browser (especially iOS) has quirks with aggressive NAT and
    background throttling that make it unreliable as the primary path.

**WebTransport / QUIC datagrams** — QUIC-based client→server.
  - Excellent for streaming under loss; datagrams skip HOL blocking.
  - iOS Safari does not support WebTransport as of mid-2026.
  - Without iOS support this is not a viable primary transport.

**WebSocket (chosen)** — TCP-based, RFC 6455, universally supported.
  - Works on every mobile browser, every OS, every network.
  - `TCP_NODELAY` removes the Nagle batching penalty (~0–40 ms).
  - `wss://` over TLS 1.3 with session resumption adds <1 ms per message
    once the session is established.
  - For rare single-packet events, TCP's reliable-ordered delivery is an
    asset not a liability — no dedup logic needed.

---

## Off-network path: relay vs Tailscale

When the phone and laptop are on different networks (phone on cellular,
laptop at home), two options exist:

### Option A — Cloud relay (simpler, default)
Run the relay on Fly.io in the region closest to both devices. Phone and
laptop both connect out to it. Works with zero configuration on the laptop
(no port forwarding, no VPN).

Latency: internet RTT phone→relay + internet RTT relay→laptop.
Typical: 40–120 ms total relay hop.

### Option B — Tailscale direct (lower latency, ~5 min setup)
Tailscale builds a WireGuard mesh. On a direct path, phone and laptop talk
peer-to-peer with ~0.8 ms WireGuard overhead. The relay then runs ON the
laptop and the phone dials it via its Tailscale address.

When a direct path is impossible (symmetric NAT, CGNAT), Tailscale falls
back to a DERP relay, adding 18–45 ms. About 5% of connections end up
relayed. For the other 95%, you pay only internet RTT + 0.8 ms.

Tailscale Peer Relays (beta Oct 2025): you can designate your own VPS as a
relay within your tailnet, running on UDP (lower overhead than DERP's HTTPS)
and placed geographically where you want it.

**Recommendation:** start with Option A (cloud relay). If measured latency
is unacceptable, add Tailscale. The code is the same either way — only
RELAY_URL changes.

---

## Repository layout

```
click-bridge/
├── PLAN.md
├── README.md
├── internet-server/           ← cloud relay (deploy to Fly.io / Render / VPS)
│   ├── package.json
│   ├── server.js
│   ├── fly.toml
│   └── public/
│       └── index.html         ← phone PWA (pointerdown, keep-warm, wake lock)
├── receiver/                  ← runs on the laptop (macOS or Windows)
│   ├── package.json
│   └── receiver.js            ← libnut fast path + process-spawn fallback
└── fast-server/               ← single-process version for same-WiFi LAN (optional)
    ├── package.json
    ├── server.js
    └── public/
        └── index.html
```

---

## Stable interfaces

**WebSocket URL:**
`wss://<relay-host>/?token=<secret>&role=sender|receiver`
Upgrade rejected with `401` when token is wrong.

**Message format (minimal JSON):**

```
sender  → relay     { "t": "c", "at": <epoch-ms> }       click with timestamp
relay   → receiver  { "t": "c", "at": <epoch-ms> }       forwarded click
relay   → sender    { "t": "a", "at": <epoch-ms>, "n": <receivers> }  ack
sender  → relay     { "t": "p" }                         keep-warm ping (ignored by relay)
```

`"t"` instead of `"type"`, no extra fields — smallest payload, fastest parse.

**ACTION env var (receiver, same names on both OSes):**

```
key:space      Press Space (default)
key:enter      Press Enter / Return
key:esc        Press Escape
key:up/down/left/right   Arrow keys
key:tab / key:backspace / key:delete
key:home / key:end / key:pageup / key:pagedown
char:a         Type a literal character
click          Left-click at current cursor position
```

---

## Task dependency order

```
1 (bootstrap) → 2 (relay) → 3 (phone page) → 4 (receiver) → 5 (end-to-end test)
                                                                    ↓
                                                            6 (deploy relay)
                                                                    ↓
                                                            7 (security gates)
                                                                    ↓
                                                   8 (optional: Tailscale direct)
                                                   9 (optional: LAN single-process)
```

---

## Task 1 — Bootstrap the repository

**Files:** `package.json` files for relay and receiver, directory tree.

- [ ] Create the directory tree from Repository Layout above.
- [ ] `relay/package.json` and `receiver/package.json`: `"type":"module"`, Node >=18,
      dep `ws ^8.18.0`, dep `@nut-tree-fork/libnut ^4.2.6` (receiver only).
- [ ] `cd internet-server && npm install` — confirm `ws` resolves.
- [ ] `cd receiver && npm install` — confirm `ws` and `@nut-tree-fork/libnut` both
      resolve with a prebuilt binary (no compiler needed). If the binary fails,
      see Task 4 fallback note.
- [ ] `git init && git add . && git commit -m "chore: bootstrap click-bridge"`

---

## Task 2 — Build the internet relay

**File:** `internet-server/server.js`

The relay is stateless. It holds connected senders and receivers in memory only.
Restarting it loses no durable data — only live connections, which reconnect.

- [ ] **Fail-closed on startup.** If `AUTH_TOKEN` is unset or shorter than 16 chars,
  log an error and `process.exit(1)`.

- [ ] **HTTP handler.**
  - `GET /` → serve `public/index.html` with `content-type: text/html; charset=utf-8`.
  - `GET /healthz` → `200 ok` (used by Fly.io health check and for monitoring).
  - All other paths → `404`.

- [ ] **TCP_NODELAY on every socket.**
  ```js
  server.on("connection", (s) => s.setNoDelay(true));
  ```
  This disables Nagle's algorithm, removing up to ~40 ms of batching tail
  latency on small single-packet messages. Apply it here on the raw TCP
  connection before the WebSocket upgrade.

- [ ] **Token gate on upgrade.**
  ```js
  if (url.searchParams.get("token") !== TOKEN) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }
  ```

- [ ] **Receiver tracking.** Role `receiver` connections go into a `Set`. On close,
  remove from the set. Log connect/disconnect with current count.

- [ ] **Sender message handler.**
  - Accept `{"t":"c","at":<ms>}` (click with timestamp) or bare `"c"`.
  - Ignore any other message (keep-warm pings, malformed JSON).
  - Fan the click out to every open receiver as `{"t":"c","at":<ms>}`.
  - Ack the sender with `{"t":"a","at":<ms>,"n":<count>}` where `n` is the
    number of receivers that were open at fan-out time.

- [ ] **25-second heartbeat.**
  ```js
  setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false;
      ws.ping();
    }
  }, 25_000);
  ws.on("pong", () => { ws.isAlive = true; });
  ```
  Keeps connections alive through proxy and host idle timeouts, which vary
  from 30 s to 60 s on common cloud hosts and mobile networks.

- [ ] **Verify locally.**
  ```bash
  AUTH_TOKEN=testsecret1234567890 npm start
  ```
  Use `wscat` or a test script to:
  - Open a `?role=receiver&token=testsecret1234567890` connection — expect no error.
  - Open a `?role=sender&token=testsecret1234567890` connection and send
    `{"t":"c","at":1000}` — expect the receiver to get `{"t":"c","at":1000}`
    and the sender to get `{"t":"a","at":1000,"n":1}`.
  - Open a connection without a token — expect `401` and socket drop.

- [ ] `git commit -m "feat: websocket relay with token gate and heartbeat"`

---

## Task 3 — Build the phone sender page

**File:** `internet-server/public/index.html`

The phone page is a single HTML file served by the relay. It is installable
to the home screen as a PWA. All latency optimisations for the phone-side are
implemented here.

- [ ] **PWA meta tags.**
  ```html
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"/>
  <meta name="apple-mobile-web-app-capable" content="yes"/>
  <meta name="theme-color" content="#0b0d10"/>
  ```

- [ ] **`touch-action: manipulation` on `body`.** Prevents the 300 ms double-tap
  delay on some Android browsers without having to disable zoom entirely.

- [ ] **Settings dialog.** Persists relay URL and shared secret in `localStorage`.
  Entered once, remembered forever.

- [ ] **WebSocket connection.** Connect to `wss://<relay>/?token=<secret>&role=sender`.
  Show connected/disconnected status with a dot indicator. Auto-reconnect
  with backoff capped at 6 s. Reconnect immediately on visibility change
  (app foregrounded after backgrounding).

- [ ] **`pointerdown` trigger — NOT `click`.**
  ```js
  btn.addEventListener("pointerdown", e => {
    e.preventDefault();         // suppress ghost click
    ws.send(`{"t":"c","at":${Date.now()}}`);
    if (navigator.vibrate) navigator.vibrate(8);
  }, { passive: false });
  ```
  `pointerdown` fires the instant the finger touches the screen, before lift.
  `click` fires on lift. Difference: 10–80 ms depending on tap duration.
  `e.preventDefault()` on `pointerdown` suppresses the 300 ms synthetic
  `click` that follows on touch devices.

- [ ] **Keep-warm ping every 1.5 s.**
  ```js
  setInterval(() => { if (ws?.readyState === 1) ws.send('{"t":"p"}'); }, 1500);
  ```
  Phone WiFi radios enter power-save between beacons (~100 ms interval).
  Without traffic, the first packet after a gap can be delayed 50–150 ms
  waiting for the radio to wake. The 1.5 s interval is shorter than any
  reasonable beacon/DTIM period and keeps the radio in active mode.
  The relay ignores `"t":"p"` messages (not `"t":"c"`).

- [ ] **Screen wake lock.**
  ```js
  navigator.wakeLock?.request("screen");
  ```
  Best-effort (requires `https://`, silently fails otherwise). Keeps the
  screen on so the app stays foregrounded and the browser doesn't throttle
  the WebSocket.

- [ ] **Ack display.** On receiving `{"t":"a","at":<ms>,"n":<n>}`, show
  `"<rtt> ms · <n> receiver(s)"` using `Date.now() - at` for round-trip.
  Show `"no receiver connected"` when `n === 0`.

- [ ] **Quality floor.** Responsive on a phone viewport. Visible focus ring.
  `prefers-reduced-motion: reduce` respected (no transitions).

- [ ] **Verify.** Load in a mobile browser (or devtools responsive mode).
  Enter settings, confirm status goes live, tap, confirm ack with latency.

- [ ] `git commit -m "feat: phone sender pwa with pointerdown and keep-warm"`

---

## Task 4 — Build the cross-platform receiver

**File:** `receiver/receiver.js`

The receiver runs as a Node process on the laptop. It connects OUT to the
relay so no port forwarding or inbound firewall rule is needed on the laptop.

- [ ] **Require `RELAY_URL` and `AUTH_TOKEN`.** Default `ACTION=key:space`.
  Exit with a clear error if either is missing.

- [ ] **Try to load `@nut-tree-fork/libnut` (fast path).** If the prebuilt
  binary is present (after `npm install`), all input synthesis goes through
  it — a synchronous N-API call with sub-millisecond latency and no process
  spawn. If the module fails to load, log a warning and fall through to the
  process-spawn fallback.

- [ ] **Pre-resolve `ACTION` before any click arrives.** Parse the action
  string once at startup and build a `fire()` closure. The hot path on each
  click calls only `fire()` — no string parsing, no conditional, no lookup.

- [ ] **libnut fast path dispatch.**
  ```js
  if (KIND === "click")      fire = () => libnut.mouseClick("left");
  else if (KIND === "key")   fire = () => libnut.keyTap(ARG.toLowerCase());
  else if (KIND === "char")  fire = () => libnut.typeString(ARG);
  ```
  libnut key names for common keys: `"space"`, `"enter"`, `"escape"`,
  `"tab"`, `"up"`, `"down"`, `"left"`, `"right"`, `"backspace"`, `"delete"`,
  `"home"`, `"end"`, `"pageup"`, `"pagedown"`.

- [ ] **Process-spawn fallback — macOS.**
  - `click` → `cliclick c:.` (requires `brew install cliclick`).
  - `key:<name>` → `osascript -e 'tell application "System Events" to key code N'`.
    Key code table: space=49 enter=36 esc=53 tab=48 up=126 down=125 left=123
    right=124 backspace=51 delete=117 home=115 end=119 pageup=116 pagedown=121.
  - `char:<c>` → `osascript -e 'tell application "System Events" to keystroke "c"'`.

- [ ] **Process-spawn fallback — Windows (PowerShell).**
  - `click` → `Add-Type [DllImport("user32")] mouse_event(2,…) then (4,…)`.
  - `key:<name>` → `SendKeys` token: space=" " enter="{ENTER}" esc="{ESC}"
    tab="{TAB}" up="{UP}" down="{DOWN}" left="{LEFT}" right="{RIGHT}"
    backspace="{BACKSPACE}" delete="{DELETE}" home="{HOME}" end="{END}"
    pageup="{PGUP}" pagedown="{PGDN}".
  - `char:<c>` → `SendKeys` with metacharacters `+^%~(){}[]` brace-escaped.

- [ ] **Message handler.** On each WS message, parse `t` field. If `t !== "c"`,
  return. Extract `at` for latency logging. Call `fire()`. Log
  `click relay_rtt=<ms> ACTION=<action> input=<native|spawn>`.

- [ ] **Reconnect with capped backoff.** Start at 500 ms, double each attempt,
  cap at 10 s. Log disconnect and reconnect.

- [ ] **macOS permissions note (in code comment and README).** The process needs
  Accessibility permission or input silently fails:
  System Settings → Privacy & Security → Accessibility → enable Terminal
  (or whatever shell/app runs the receiver).

- [ ] **Windows elevation note.** To send input into an app running as
  Administrator, the receiver must also run as Administrator. Windows blocks
  input from a lower-integrity process into a higher-integrity window.

- [ ] **Verify.** Start with `RELAY_URL=wss://... AUTH_TOKEN=... ACTION=key:space npm start`.
  Focus a text editor. Tap the phone. Confirm the key fires and the log shows
  the relay latency. Confirm `native` appears in the log if libnut loaded.

- [ ] `git commit -m "feat: cross-platform receiver with libnut fast path"`

---

## Task 5 — End-to-end test (local relay)

Before deploying, verify the full pipeline locally with the relay running on
localhost and the phone reaching it via the laptop's LAN IP.

- [ ] Generate a test secret: `openssl rand -hex 24`.
- [ ] Start relay: `cd internet-server && AUTH_TOKEN=<secret> npm start`.
- [ ] Start receiver: `RELAY_URL=ws://<LAN-IP>:8080 AUTH_TOKEN=<secret> ACTION=key:space npm start`.
- [ ] Open `http://<LAN-IP>:8080` on the phone (same WiFi). Enter settings.
- [ ] Tap. Verify:
  - Phone shows ack with latency and `1 receiver`.
  - Laptop fires the key.
  - Receiver log shows `relay_rtt=` and `input=native`.
- [ ] Kill receiver, tap again. Verify phone shows `no receiver connected`.
- [ ] Kill relay, confirm receiver reconnects after it restarts.

---

## Task 6 — Deploy the relay

**File:** `internet-server/fly.toml`

- [ ] **Choose the right region.** Run `fly platform regions` and pick the city
  closest to where phone and laptop both are. This is the single biggest
  controllable latency variable. Same-city = ~1–5 ms relay hop each way.
  Wrong continent = 80–150 ms each way.

- [ ] **Set `auto_stop_machines = false` and `min_machines_running = 1`.** Without
  this, Fly idles the machine after inactivity. The receiver would disconnect,
  and the 30–60 s cold-start latency would hit the next click. Always-on is
  the only correct setting for a persistent relay.

- [ ] Deploy:
  ```bash
  cd internet-server
  fly launch --no-deploy
  fly secrets set AUTH_TOKEN=<your-secret>
  fly deploy
  ```

- [ ] Verify: `curl https://<app>.fly.dev/healthz` → `ok`.

- [ ] Update receiver and phone settings to point at `wss://<app>.fly.dev`.

- [ ] Measure end-to-end latency. The phone ack shows round-trip. Receiver log
  shows relay RTT (phone→relay→laptop). Record baseline numbers.

- [ ] `git commit -m "chore: relay deploy config"`

---

## Task 7 — Security gates (required before sharing with anyone)

- [ ] **Token gate verified:** connection without correct token → `401`.
- [ ] **No injection surface:** phone can only send `{"t":"c"}`. The receiver
  never executes any string from the sender — `fire()` is fixed at startup.
  Even with a leaked token, an attacker can only trigger your one configured action.
- [ ] **Secret hygiene:** `AUTH_TOKEN` exists only as a host secret and local env.
  `git grep` finds no secret-like strings in tracked files.
- [ ] **Reconnect verified:** sleep phone, change networks, restart relay —
  all recover automatically without manual intervention.
- [ ] **Rotation verified:** change `AUTH_TOKEN` (fly secrets set + restart receiver
  + update phone settings) fully cuts off the old secret.
- [ ] **Permissions documented:** macOS Accessibility and Windows elevation caveats
  are in README and in code comments.
- [ ] `git commit -m "docs: security gates verified"`

---

## Task 8 — Optional: Tailscale for lower internet latency

When the cloud relay hop is too slow (or you want zero cloud dependency),
Tailscale builds a direct WireGuard tunnel between phone and laptop.

**How it works:**
- Install Tailscale on both the phone and the laptop.
- The laptop gets a stable Tailscale IP (e.g. `100.x.x.x`) or MagicDNS name.
- Run `internet-server/server.js` on the laptop (same code, no changes).
- Set `RELAY_URL=ws://100.x.x.x:8080` on the receiver (also on laptop, so
  this is localhost effectively).
- Set the phone's relay URL to `ws://100.x.x.x:8080` in the settings dialog
  (the Tailscale address of the laptop).

**Latency:**
- Direct path (95% of connections): internet RTT + ~0.8 ms WireGuard overhead.
  The relay hop disappears — phone talks directly to laptop.
- DERP relay fallback (5% of connections): adds 18–45 ms on top of internet RTT.
  Better than a geographically wrong cloud relay; worse than a well-placed one.

**Checklist:**
- [ ] Install Tailscale: `brew install tailscale && sudo tailscale up` (macOS),
  Tailscale app from the Play/App Store (phone).
- [ ] Confirm both devices appear in the Tailscale admin console.
- [ ] Find laptop's Tailscale IP: `tailscale ip -4`.
- [ ] Open port 8080 in any local firewall: `sudo ufw allow 8080` (Linux) or
  macOS Firewall → Allow incoming connections for Node.
- [ ] Start relay on laptop: `AUTH_TOKEN=<secret> node internet-server/server.js`.
- [ ] Start receiver on laptop: `RELAY_URL=ws://100.x.x.x:8080 AUTH_TOKEN=<secret> ACTION=key:space node receiver/receiver.js`.
- [ ] Update phone settings: relay URL = `ws://100.x.x.x:8080`.
- [ ] Tap and record latency. Compare to cloud relay baseline from Task 6.
- [ ] Confirm reconnect after phone switches between WiFi and cellular.

**Tailscale Peer Relay (advanced, Oct 2025 beta):** if direct paths fail often
(CGNAT on phone's carrier) and you want lower latency than DERP, designate a
cheap VPS in your tailnet as a peer relay. It runs on UDP (lower than DERP's
HTTPS), is geographically placed by you, and performance is close to a direct
connection.

---

## Task 9 — Optional: LAN single-process (lowest possible latency)

When phone and laptop are on the same WiFi and you need single-digit latency:

- [ ] Use `fast-server/server.js` — it runs the relay and receiver in one process,
  dispatches input inline, and serves the phone page.
- [ ] `cd fast-server && npm install && ACTION=key:space npm start`.
- [ ] The server prints the `http://<LAN-IP>:8080` URL — open it on the phone.
- [ ] No relay URL to configure — the page is served by the same process that
  fires the click.
- [ ] Expected latency: WiFi RTT (~2–10 ms) + libnut call (<1 ms) + phone touch
  pipeline (~10–20 ms) = **~15–30 ms total**. This is the hardware floor.

---

## Deployment runbook (quick reference)

```bash
# 1. Generate a secret
openssl rand -hex 24

# 2. Deploy relay (once)
cd internet-server
fly launch --no-deploy            # edit app name and region in fly.toml
fly secrets set AUTH_TOKEN=<secret>
fly deploy
# Verify: curl https://<app>.fly.dev/healthz

# 3. Start receiver on your laptop
cd receiver && npm install

# macOS:
RELAY_URL=wss://<app>.fly.dev AUTH_TOKEN=<secret> ACTION=key:space npm start
# Grant Accessibility: System Settings → Privacy & Security → Accessibility → Terminal ✓

# Windows PowerShell:
$env:RELAY_URL="wss://<app>.fly.dev"; $env:AUTH_TOKEN="<secret>"; $env:ACTION="key:space"; npm start
# Run as admin if targeting an elevated app.

# 4. Phone
# Open https://<app>.fly.dev → ⚙ → enter relay URL + secret → Save → Add to Home Screen
```

---

## Latency optimisation checklist (run down this list before declaring done)

- [ ] Relay region is the closest available to phone + laptop geography.
- [ ] `TCP_NODELAY` confirmed set (it's in `server.js` already; verify with `wireshark` or by measuring ack latency — should be no ~40 ms spikes).
- [ ] Phone is on 5 GHz or 6 GHz WiFi, not 2.4 GHz, and close to the AP.
- [ ] Laptop is on Ethernet (removes laptop WiFi variance from the Tailscale path).
- [ ] `ACTION` is a `key:` not `char:` where possible — `keyTap` is marginally faster than `typeString`.
- [ ] libnut loaded (receiver log says `input=native`, not `input=spawn`).
- [ ] Screen stays on during use (wake lock works on `https://`; for `ws://` keep screen manually on).
- [ ] Phone not in Low Power Mode (iOS throttles background tasks and timers; keep-warm may fire less reliably).
- [ ] Measured round-trip (from phone ack) is consistent — occasional spikes > 200 ms usually mean DERP relay fallback on Tailscale or a congested WiFi channel.
