# Click Bridge

Click Bridge is intended to let one foreground phone page send one action over
the internet so a macOS menu-bar app posts one real left mouse click at the
Mac's current pointer location.

The repository currently contains an **imported, unverified scaffold**. No
component is considered complete, deployable, or physically accepted until its
corresponding gate in [`FINAL-PLAN.md`](FINAL-PLAN.md) has been run and passed
with fresh evidence. Historical test counts and earlier "done" claims are not
carried forward.

## Canonical scope

- `FINAL-PLAN.md` is the only active implementation plan.
- Tasks 1 through 9 are **Milestone 1** and produce the first complete working
  application.
- Tailscale (Task 10) and hedged delivery (Task 11) are latency experiments and
  must not be enabled before the Milestone 1 acceptance gate passes.
- Earlier plans and prototypes remain historical evidence until the mandatory
  cleanup inside Task 9. They are non-authoritative even while preserved.

The implementation branch is `codex/click-bridge-implementation`. The isolated
worktree and locally discoverable preflight facts are recorded in
[`docs/preflight.md`](docs/preflight.md).

## Milestone 1 acceptance path

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

Task 12 is the final repository verification pass. Tasks 10 and 11 remain
optional after Milestone 1 and are retained only if measured latency improves.

## Intended architecture

```text
Phone foreground PWA
        |
        | HTTPS + persistent WSS
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

Milestone 1 uses no database. The relay keeps only live connection and routing
state; the Mac process owns action deduplication and native click execution.

## Repository layout

```text
contracts/fixtures/   Canonical wire-protocol fixtures
relay/src/            Node relay implementation
relay/public/         Foreground phone web app
relay/test/           Relay and web-app tests
mac/                  Swift macOS app and tests
deploy/oci/           OCI Docker, Compose, and Caddy configuration
tests/manual/         Harmless physical click counter
docs/                 Preflight, deployment, smoke-test, and benchmark notes
archive/              Non-authoritative historical material
```

Use the dependency-ordered commands and acceptance criteria in
`FINAL-PLAN.md`; do not treat the imported scaffold itself as proof that any
step works.
