# Click Bridge

Click Bridge lets one foreground phone client send one action over the internet
so a macOS menu-bar app can post exactly three independent ordinary left mouse clicks at the Mac's current
pointer location. The native iOS client supports system output-volume changes,
an on-screen **Trigger 3 Clicks** button, and a **Trigger 3 Clicks** App Shortcut. The
tap-based PWA remains available as the fallback phone client.

The relay/PWA, macOS, and native iOS implementations are present with automated
test and build evidence recorded in this repository. Physical iPhone volume and
haptic behavior, macOS Accessibility-authorized clicking, and an end-to-end
Octo Browser click session still require the explicit hardware acceptance runs;
the automated evidence does not stand in for those gates.

## Canonical scope

- `FINAL-PLAN.md` is the only active implementation plan.
- The foreground native iOS client reuses the existing phone role and protocol.
  Its XcodeGen source is `ios/project.yml`, and its shared scheme is
  `ClickBridgePhone`.
- Native volume changes, the on-screen **Trigger 3 Clicks** button, and the App
  Shortcut all feed the same readiness and one-action-in-flight boundary.
- The existing installable PWA is preserved as the tap-based fallback.
- Tailscale (Task 11) and hedged delivery (Task 12) are latency experiments and
  must not be enabled before the Milestone 1 acceptance gate passes.
- Earlier plans and prototypes are non-authoritative historical evidence under
  `archive/`.

Repository and environment facts are recorded in
[`docs/preflight.md`](docs/preflight.md).
Xcode Cloud setup, workflow ownership, and TestFlight rollout are recorded in
[`docs/xcode-cloud.md`](docs/xcode-cloud.md).

## Delivery acceptance path

| Task | Gate |
|---|---|
| 1 | Repository boundaries and preflight facts are recorded |
| 2 | One canonical wire contract passes Node and Swift fixture tests |
| 3 | Relay behavior passes unit, socket, and lifecycle tests |
| 4 | The foreground phone PWA passes state, asset, CSP, and browser checks |
| 5 | The macOS shell and relay client build and pass tests |
| 6 | Permission, at-most-once action processing, and `CGEvent` click tests pass |
| 7 | A local phone-to-relay-to-Mac click works on the harmless counter page |
| 8 | The relay is deployed to the selected OCI SJC VM behind public HTTPS/WSS |
| 9 | Physical Octo Browser acceptance and latency benchmarking pass; canonical cleanup finishes |
| 10 | Native iOS automated checks pass; physical iPhone volume/haptic acceptance remains a separate required gate |

Task 13 is the final repository verification pass. Tasks 11 and 12 remain
optional after Milestone 1 and are retained only if measured latency improves;
Task 10 is required before final handoff.

## Intended architecture

```text
Phone foreground client
  +-- native iOS client
  |     +-- output-volume changes
  |     +-- on-screen Trigger 3 Clicks
  |     +-- Trigger 3 Clicks App Shortcut
  +-- preserved PWA fallback
        |
        | HTTPS/WSS + existing phone protocol
        v
OCI SJC: Caddy -> Node relay
                       |
                       | persistent WSS
                       v
              macOS menu-bar app
                       |
                       v
          three ordinary CGEvent clicks
```

The relay keeps only live connection and routing state; the Mac process owns
action deduplication and native click execution. The native iOS client keeps one
authenticated WSS connection, one action in flight, and no queue; every native
entry point uses the current foreground, relay, Mac, and clock-readiness gates.
At 0% or 100%, one direction cannot create another observable volume delta.
Control Center, wired/Bluetooth headsets, and AirPods can also trigger because
iOS reports volume changes rather than the physical source. Haptics wait for the
Mac terminal result.

One accepted phone input still creates one logical action ID, one terminal
result, and at most one terminal-result haptic. The Mac expands that logical
action into exactly three independent ordinary click pairs; the wire action
remains `click`.

## Repository layout

```text
contracts/fixtures/   Canonical wire-protocol fixtures
relay/src/            Node relay implementation
relay/public/         Foreground phone web app
relay/test/           Relay and web-app tests
mac/                  Swift macOS app and tests
ios/project.yml       Native iOS XcodeGen source; shared ClickBridgePhone scheme
ios/                  Native iOS app and deterministic tests
deploy/oci/           OCI Docker, Compose, and Caddy configuration
tests/manual/         Harmless physical click counter
docs/                 Preflight, deployment, smoke-test, and benchmark notes
archive/              Non-authoritative historical material
```

Use the acceptance criteria in `FINAL-PLAN.md` and the current evidence records
under `docs/`. Treat any gate marked `NOT RUN` as outstanding.
