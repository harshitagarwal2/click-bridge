# Click Bridge

Tap one button on a phone; a Mac posts one real left mouse click at wherever
its cursor already is. Over the internet, through one relay.

`PLAN-v5.md` is the authoritative plan. This README is the operator guide.

---

## What is built

| Piece | State |
|---|---|
| Wire protocol + fixtures | **Done, tested** — 38 tests |
| Relay state machine | **Done, tested** — 19 tests, fake transports |
| Relay HTTP/WebSocket server | **Done, tested** — real `ws` socket coverage included |
| Phone web app | **Done, tested** — 31 reducer tests + 10 asset/CSP tests |
| Browser/server parity | **Done, tested** — 7 tests |
| Mac Swift app | **Done, tested** — 23 unit tests, including shared wire fixtures |
| OCI deploy config | **Written, never deployed** |
| Physical smoke + benchmark | **Not started** — needs phone, Mac, Octo |

198 Node tests pass with 0 skips. The macOS unit suite has 23 passing tests
with 0 skips.

---

## Run the relay locally

```bash
cd relay
npm install                 # first run only; creates package-lock.json
npm run check               # syntax + full test suite

PHONE_TOKEN=$(openssl rand -hex 32) \
MAC_TOKEN=$(openssl rand -hex 32) \
npm start
```

Open <http://127.0.0.1:8080>, paste the `PHONE_TOKEN`, and the page connects.
It will sit at "Mac offline" until the Swift app is running.

Prove the whole path without a Mac:

```bash
cd relay
PHONE_TOKEN=<hex> MAC_TOKEN=<hex> node scripts/smoke-relay.mjs ws://127.0.0.1:8080/ws
```

---

## Build the Mac app

Requires macOS 13+, Xcode, and XcodeGen (`brew install xcodegen`).

```bash
cd mac
xcodegen generate
xcodebuild -project ClickBridgeMac.xcodeproj -scheme ClickBridgeMac \
  -destination 'platform=macOS' test

xcodebuild -project ClickBridgeMac.xcodeproj -scheme ClickBridgeMac \
  -configuration Release -derivedDataPath build build
codesign --verify --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements :- build/Build/Products/Release/ClickBridgeMac.app
```

The entitlements dump should be **empty** — no App Sandbox.

Copy the Release build to `/Applications/ClickBridgeMac.app` **before** granting
permission. Then: open it, choose **Grant Input Permission**, and allow it under
System Settings → Privacy & Security → Accessibility.

> Every ad-hoc rebuild changes the binary's cdhash, so macOS treats it as a new
> app and the permission must be granted again. Copy
> `mac/Config/Local.xcconfig.example` to `Local.xcconfig` and set a real Apple
> Development identity to stop this.

---

## Deploy

Full steps in `docs/oci-deployment.md`. Short version:

1. Point a hostname at the OCI instance. **A domain you own is best**;
   DuckDNS is the free fallback. Do not use sslip.io or nip.io — their
   Let's Encrypt quota is shared across every user and runs out.
2. Open 80/443 in the VCN security list **and** the instance firewall — Oracle's
   images drop them regardless of the security list.
3. `rsync` the repo to the VM, write `deploy/oci/.env` (mode 0600), build there.
4. `docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml up -d`

---

## Using it

1. Open `https://<your-domain>` on the phone
2. Gear → paste `PHONE_TOKEN` → Save
3. Share → **Add to Home Screen**
4. On the Mac: enter the relay URL and `MAC_TOKEN`, then flip **Remote control
   enabled** on

The button turns green when the Mac is online, remote is on, permission is
granted, and the clocks agree. Any phone with a current browser works — the
token is the only per-device setup.

---

## Things worth knowing

**One phone at a time.** A second phone authenticating replaces the first.

**The page must stay open and in front.** Sockets close when it is hidden;
returning reconnects but sends nothing. No clicks from the background.

**"Unknown" is an answer, not a bug.** If the reply is lost, the phone cannot
know whether the click landed, so it says so and stops. It never re-sends —
that is the one behaviour that could produce two clicks from one tap.

**Guarantee.** At-most-once per action while the Mac process is alive.
Exactly-once across a Mac crash is not claimed.

**Tokens.** Three, all independent. `PHONE_TOKEN` and `MAC_TOKEN` live in
`deploy/oci/.env` on the VM and in their clients. `DIRECT_TOKEN` is Milestone 2
only and never enters the relay's environment.

---

## Layout

```
contracts/fixtures/   canonical JSON — read by BOTH the Node and Swift suites
relay/src/            protocol, relay state machine, HTTP + WebSocket server
relay/public/         the phone web app (no inline script or style: CSP)
relay/test/           198 passing tests
mac/                  Swift menu-bar app + XcodeGen spec
deploy/oci/           Dockerfile, compose, Caddyfile
tests/manual/         click-target.html — the harmless counter for Octo
docs/                 deployment, install, smoke test, benchmark method
```

The relay serves `public/` with a Content-Security-Policy that forbids inline
script and style, and Caddy passes that header through unchanged. `relay/test/
assets.test.js` fails the build if anything inline creeps into the page — so
the breakage happens where it is caused, not in production four tasks later.
