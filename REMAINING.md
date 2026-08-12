# What's left

Audited against `PLAN-v5.md`'s declared file list and acceptance gates.
Status as of the last sync: **198/198 Node tests pass, 0 skipped**, against both
the minimal RFC 6455 test server and the real production `ws`.

---

## A. Only you can do these — I have no toolchain for them

These are the ones that decide whether the thing actually works. Nothing I write
increases confidence in them.

- [ ] **Compile the Mac app.** No Swift toolchain exists in either sandbox, so
      ~1,400 lines have never been parsed, let alone run.
      ```bash
      brew install xcodegen
      cd ~/Desktop/clicker/mac && xcodegen generate
      xcodebuild -project ClickBridgeMac.xcodeproj -scheme ClickBridgeMac \
        -destination 'platform=macOS' test
      ```
      Expect errors around actor isolation between `AppState` (`@MainActor`) and
      `RelayClient` (an `actor`). `ToggleReader.isRemoteEnabled()` uses
      `MainActor.assumeIsolated`, which traps if called off the main actor —
      that is the most likely first failure.

- [x] **Run `ActionProcessorTests`.** The macOS suite now has 23 passing tests,
      including 1,000 concurrent duplicates across two ingresses. This proves
      the in-memory at-most-once behavior, not physical input delivery.

- [ ] **Build the Docker image on the OCI VM** (not on the Mac — architecture).
- [ ] **Deploy**: DNS → firewall (both layers) → `.env` → compose up → smoke.
- [ ] **Grant PostEvent permission** and confirm `CGPreflightPostEventAccess()`
      returns true from the installed `/Applications` build.
- [ ] **Calibrate `CLICK_GAP_MS` against Octo** — 0 → 5 → 10 → 20 → 30 ms, stop
      at the first value giving 100/100 increments.
- [ ] **Run the physical smoke matrix** (17 rows, `docs/smoke-test.md`).
- [ ] **Collect the benchmark**: 100 samples per condition, then the keep-warm
      A/B. The summarizer and its 15 tests are ready and waiting for real data.

---

## B. I can finish these here

### Swift test files (4 missing)

- [ ] `RelayClientTests.swift` — injected transport, one receive loop, one
      reconnect task, heartbeat timeout, stale-generation isolation
- [ ] `PermissionServiceTests.swift` — preflight vs request separation
- [ ] `MacInputExecutorTests.swift` — both events built before either is posted;
      `mouseEventClickState` set on both
- [ ] `DirectWebSocketServerTests.swift` — Milestone 2

They still won't *run* here, but they're the specification the compiler checks.

### Milestone 2 phone side

- [ ] `relay/public/direct-transport.js`
- [ ] Wire the second transport into `app.js` (the coordinator already supports
      it and is tested — 15 tests including hedging)
- [ ] Settings UI for `DIRECT_WSS_URL` + `DIRECT_TOKEN`, with the `.ts.net` and
      `wss:` validation the plan requires
- [ ] `tests/manual/direct-ws-harness.html` — the loopback gate before Tailscale

### Tests the plan names that I haven't written

- [ ] `relay/test/negative-matrix.test.js` + `scripts/run-negative-matrix.mjs` —
      drives every rejection reason end to end through the relay

### Docs (5 missing; 3 exist)

- [ ] `docs/preflight.md` — record OCI arch, IP, hostname, Mac/Octo versions
      **before** anything else. Task 1 of the plan; skipping it is how the
      arm64/x86_64 image mismatch happens.
- [ ] `docs/install-macos.md`
- [ ] `docs/install-phone-pwa.md`
- [ ] `docs/oci-recovery.md` — including Always Free reclamation
- [ ] `docs/phase-2-tailscale.md`
- [ ] `benchmarks/README.md`, `docs/latency-report.md` template

### Assets

- [ ] `mac/ClickBridgeMac/Assets.xcassets/` — the app icon. `xcodegen` will
      build without it, but the menu bar item will be generic.
- [ ] `relay/public/icons/apple-touch-icon-180.png` — `index.html` currently
      points the Apple touch icon at the 192px file. Works, but iOS prefers 180.

---

## C. Naming deviations to reconcile

I merged some types the plan lists as separate files. Functionally identical,
but Swift convention is one primary type per file and the plan's list is the
better one. **Recommend splitting to match:**

| Plan says | I put it in |
|---|---|
| `ActionIngress.swift` | `ActionProcessor.swift` |
| `AppState.swift` | `ClickBridgeApp.swift` |
| `KeychainStore.swift` | `SettingsStore.swift` |
| `PostEventPermissionService.swift` | `MacInputExecutor.swift` |
| `StrictWireDecoder.swift` | `WireMessage.swift` |
| `wire-protocol.js` | `public/protocol-lite.js` |
| `relay-transport.js` | `public/transport-controller.js` |
| `relay.integration.test.js` | split → `relay.state.test.js` + `relay.socket.test.js` |

The split of the integration test was deliberate and I'd keep it: the state half
runs with no dependencies, the socket half needs a WebSocket server. Merging
them back would make the whole file unrunnable on a fresh clone.

**Either** rename my files to match the plan, **or** update the plan's §7 layout
to match the code. They should not stay out of sync.

---

## D. Files that are correctly absent

Not gaps — these are secrets or generated:

- `deploy/oci/.env` — gitignored; `.env.example` exists
- `mac/Config/Local.xcconfig` — gitignored; `.example` exists
- `mac/ClickBridgeMac.xcodeproj` — generated by `xcodegen generate`
- `relay/node_modules` — `npm install`

---

## E. Judgment calls I should not make for you

- [ ] **Hostname.** Buy a domain (~$10–15/yr, most reliable) or use DuckDNS
      (free, on the Public Suffix List so its Let's Encrypt quota is its own).
      Not sslip.io.
- [ ] **Signing identity.** Ad-hoc means re-granting input permission after
      *every* rebuild. An Apple Development identity in `Local.xcconfig` stops
      that. Worth it if you'll iterate.
- [ ] **Whether Milestone 2 happens at all.** Tailscale costs an always-on phone
      VPN. The plan makes it earn its place with numbers; you may look at the
      Milestone 1 benchmark and decide it's already fast enough.

---

## Honest summary

The Node half is done and genuinely verified — protocol, relay, phone reducer,
transports, CSP, and the latency summarizer, all green against the production
dependency, plus a live smoke test on your machine.

The Mac unit-test half is verified. Physical input delivery, permission state,
and phone-to-Mac behavior still require the environment-specific checks above.

Section B is real work I can finish, but be clear-eyed: it adds completeness,
not confidence.
