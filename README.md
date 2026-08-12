# Click Bridge

Click Bridge is intended to let one foreground phone client send one action over
the internet so a macOS menu-bar app posts one real left mouse click at the
Mac's current pointer location. The native iOS client maps each accepted system
output-volume delta to that action; the existing tap-based PWA remains the
fallback.

The repository currently contains an **imported, unverified scaffold**. No
component is considered complete, deployable, or physically accepted until its
corresponding gate in [`FINAL-PLAN.md`](FINAL-PLAN.md) has been run and passed
with fresh evidence. Historical test counts and earlier "done" claims are not
carried forward.

## Canonical scope

- `FINAL-PLAN.md` is the only active implementation plan.
- Tasks 1 through 9 are **Milestone 1** and produce the first complete working
  PWA/core OCI application.
- Task 10 adds the required foreground native iOS client without changing the
  PWA or relay protocol. Its project source is `ios/project.yml` and its shared
  scheme is `ClickBridgePhone`.
- Tailscale (Task 11) and hedged delivery (Task 12) are latency experiments and
  must not be enabled before the Milestone 1 acceptance gate passes.
- Earlier plans and prototypes remain historical evidence until the mandatory
  cleanup inside Task 9. They are non-authoritative even while preserved.

The implementation branch is `codex/click-bridge-implementation`. The isolated
worktree and locally discoverable preflight facts are recorded in
[`docs/preflight.md`](docs/preflight.md).

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
| 10 | Native iOS simulator/build checks and physical iPhone Volume Up/Down acceptance pass |

Task 13 is the final repository verification pass. Tasks 11 and 12 remain
optional after Milestone 1 and are retained only if measured latency improves;
Task 10 is required before final handoff.

## Intended architecture

```text
Phone foreground client
  +-- native iOS volume client
  +-- unchanged PWA fallback
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
                 CGEvent click
```

The relay keeps only live connection and routing state; the Mac process owns
action deduplication and native click execution. The native iOS client keeps one
authenticated WSS connection, one action in flight, and no queue; it sends only
while foreground-active and relay/Mac/clock-ready. At 0% or 100%, one direction
cannot create another observable volume delta. Control Center, wired/Bluetooth
headsets, and AirPods can also trigger because iOS reports volume changes rather
than the physical source. Haptics wait for the Mac terminal result.

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

Use the dependency-ordered commands and acceptance criteria in
`FINAL-PLAN.md`; do not treat the imported scaffold itself as proof that any
step works.
