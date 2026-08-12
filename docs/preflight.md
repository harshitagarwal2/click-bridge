# Task 1 preflight record

Captured on 2026-08-11 before implementation work. This document records only
locally discoverable, non-secret facts. It deliberately contains no credential,
token, hardware serial number, device UUID, or other unique hardware identifier.

## Repository starting state

| Item | Recorded value |
|---|---|
| Isolated worktree | `/private/tmp/clicker-codex-implementation` |
| Branch | `codex/click-bridge-implementation` |
| Starting status | Clean index and worktree before Task 1 edits |
| Starting HEAD | `6c54ea2 docs: finalize click bridge implementation plan` |
| Imported baseline | `b3d7729 chore: polish repository setup` |
| Initial scaffold commit | `ab0fc92 Initial commit: Click Bridge application` |
| Ancestry check | `ab0fc92` is an ancestor of `HEAD`; `b3d7729` exists in history |
| Active plan | `FINAL-PLAN.md`, already committed at `6c54ea2` |

The worktree uses a `codex/` feature branch by explicit user request. The old
Task 1 assertion that execution must occur directly on `main` is therefore
superseded; no baseline commit was reset or rewritten.

The ignored `_to_delete/_impl.tgz` and `_to_delete/_scaffold.tgz` bundles are
not materialized in this isolated worktree because Git does not track them.
Both remain present in the original local checkout, and `_to_delete/` remains
ignored. They are historical inputs only and were not opened, copied, staged,
or modified.

## Local Mac and toolchain

| Item | Recorded value | Readiness |
|---|---|---|
| CPU architecture | `arm64` | Recorded for native build selection |
| Mac model | MacBook Pro (`MacBookPro18,3`) | Non-unique model identifier only |
| macOS | 27.0, build 26A5388g | Recorded |
| Default-path Node.js | 26.7.0 | Do not use for the Node 24-pinned tasks |
| Task Node.js | 24.19.0 at `/opt/homebrew/opt/node@24/bin/node` | Installed and ready |
| Task npm | 11.17.0 at `/opt/homebrew/opt/node@24/bin/npm` | Installed and ready |
| XcodeGen | 2.46.0 | Installed and ready |
| Docker client | 29.7.2, darwin/arm64, context `colima` | Installed and connected |
| Docker engine | 29.5.2, linux/arm64 | Running through Colima |
| Docker Compose | Standalone `docker-compose` 5.4.0 | Installed; `docker compose` plugin discovery is unavailable |
| Docker buildx | Standalone `docker-buildx` 0.36.1 | Installed; `docker buildx` plugin discovery is unavailable |

### NODE-01 — Node 24 selection

Node 24.19.0 and npm 11.17.0 are installed under
`/opt/homebrew/opt/node@24/bin`. The default shell path still resolves Node
26.7.0, so Task 2 and later Node-pinned commands must prepend the Node 24 bin
directory to `PATH` or invoke those binaries explicitly. Record that task's
fresh `node --version` and `npm --version` evidence before dependency work.

Local container validation is now available through the Colima Docker context.
Because CLI plugin discovery does not expose the space-form commands, use the
verified standalone `docker-compose` and `docker-buildx` executables locally.
The OCI host still requires its own Docker/Compose inspection; the local arm64
engine does not establish the VM architecture or production readiness.

## OCI SJC and public endpoint gates

The gates that were unknown during Task 1 were closed on 2026-08-12 UTC through
the authenticated OCI CLI, an SSH inspection, public DNS/TLS probes, and an
authenticated WebSocket smoke. This record deliberately omits tenancy, user,
VNIC, subnet, NSG, API-key, and token identifiers.

| Gate | Required recorded fact | Verified value |
|---|---|---|
| OCI-01 | SSH user and public IPv4 | `opc@146.235.216.172`; the host key is pinned in the operator's SSH known-hosts data |
| OCI-02 | Region | `us-sanjose-1`, confirmed as the tenancy home region |
| OCI-03 | Shape and architecture | `VM.Standard.A1.Flex`, Arm64/aarch64, 1 OCPU, 6 GB RAM |
| OCI-04 | Operating system and container runtime | Oracle Linux 9.8; Docker Engine 29.7.2; Compose 5.4.0 |
| OCI-05 | Public IPv4 status | `146.235.216.172`, ephemeral and attached to the instance's primary private IP |
| OCI-06 | Public network path | Public subnet, Internet Gateway/default route, instance NSG, and subnet security-list path verified |
| OCI-07 | Ingress and host firewall | Public HTTP/HTTPS and operator SSH only; TCP 8080 is not published and is externally closed |
| DOMAIN-01 | Final hostname and DNS | `clickbridge-sjc.duckdns.org` resolves to `146.235.216.172`; no AAAA record |

The ephemeral address is acceptable for this personal Milestone 1 deployment:
it persists for the current instance/VNIC lifetime. If the instance or primary
private IP is replaced, update DuckDNS before starting Caddy on the replacement.
A reserved IP remains an optional durability improvement, not a correctness
dependency. Shared `sslip.io`/`nip.io` names and bare-IP TLS remain out of scope.

The initial OCI-native release `20260812T020129Z` passed HTTPS, TLS, health, and
an authenticated 11/11 WebSocket smoke. It must still be replaced by an image
built from the reviewed and merged Milestone 1 commit before repository
delivery is considered complete.

## Physical target gates

| Gate | Required recorded fact | Current value |
|---|---|---|
| MAC-01 | Mac model and OS | MacBook Pro (`MacBookPro18,3`), macOS 27.0 (26A5388g) |
| OCTO-01 | Installed Octo Browser version | Not found in standard `/Applications` or user `Applications` locations; confirm before Task 7 |
| PHONE-01 | Target phone model and OS | Not supplied |
| PHONE-02 | Target carrier | Not supplied |
| NETWORK-01 | Whether the Mac uses wired Ethernet or Wi-Fi during the benchmark | Restricted local inspection could not establish this safely |
| TARGET-01 | Harmless physical click-counting page | `tests/manual/click-target.html` exists |

Phone, carrier, and Octo details are operational inputs rather than repository
secrets. Record them when the physical devices are available; do not infer them.

## Canonical repository boundary

- `FINAL-PLAN.md` is the only active plan.
- Tasks 1 through 9 form Milestone 1.
- Tailscale and hedging stay disabled until Milestone 1 passes.
- Earlier plans and prototypes remain non-authoritative historical evidence
  until the required Task 9 cleanup.
- The imported application scaffold remains unverified until each task's
  acceptance gate passes with fresh evidence.
- Root Docker context excludes repository metadata, secrets, dependencies,
  build products, archives, bundles, Mac sources, benchmarks, tests, docs, and
  plans while retaining `relay/package*.json`, `relay/src/`, and
  `relay/public/` as build inputs.

## Task 1 handoff gates

- [x] Feature branch/worktree, baseline commits, and clean starting state recorded.
- [x] Mac architecture, model, OS, and local toolchain recorded without unique hardware identifiers.
- [x] Canonical plan and milestone boundaries documented.
- [x] Historical bundles preserved and ignored.
- [x] Harmless physical click target identified.
- [x] NODE-01: Node 24.19.0/npm 11.17.0 installed; explicitly select its bin directory for Task 2.
- [x] OCI-01 through OCI-07: inspected through authenticated OCI CLI, SSH, and public probes.
- [x] DOMAIN-01: `clickbridge-sjc.duckdns.org` resolves to the active OCI IPv4.
- [ ] OCTO-01, PHONE-01, PHONE-02, NETWORK-01: record the physical test setup.
