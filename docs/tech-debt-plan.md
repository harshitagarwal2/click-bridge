# Tech-debt remediation record

Status: **all eight scoped items implemented on 2026-08-12**. This is an
as-built decision record, not a source of mutable test totals or line numbers.
The pull request and merge commit carry the exact verification evidence.

The scope is code, configuration, and operations documentation. It does not
claim physical iPhone acceptance, the physical smoke matrix, latency results,
production deployment, App Store upload, or TestFlight processing.

## 1. Collapse duplicated JavaScript timing constants

`relay/src/constants.js` used to redefine all ten values already owned by
`relay/public/runtime-constants.js`, even though the PWA imported the public
module. It now imports and re-exports all ten values. The local `INVARIANTS`
block continues to consume the imports.

The former copies had different Node-side use patterns: four were only
re-exported from `src/constants.js`, three also fed its `INVARIANTS`, and three
had additional Node/test consumers. None of that made the canonical public
values dead: clock refresh, reconnect backoff, keep-warm, heartbeat, and result
timeouts are all live PWA inputs.

**Does not fix:** Swift must still mirror cross-language values by hand; item 5
makes that drift fail tests.

## 2. Separate takeover from credential replacement

Role takeover remains close code `4004`; authentication rejection remains
`4005`; credential replacement now has its own close code, `4006`. The PWA and
iOS client expose credential replacement as an unreclaimable terminal state
with re-pair guidance, while takeover remains reclaimable. Regression tests
cover automatic lifecycle reconnects and successful credential promotion.

**Does not fix:** older clients do not know `4006`; relay and clients must be
released together.

## 3. Document poisoned auth-store recovery

The auth store deliberately poisons itself after an ambiguous persist/rollback
failure. The OCI runbook now documents the runtime log signal, `/readyz`
diagnostic, restart procedure, and the important fact that the new credential
may already be authoritative on disk.

**Does not fix:** the fail-closed wedge remains by design, and no external
monitor is configured here.

## 4. Record and secure the manual backup procedure

The OCI runbook now backs up `secrets.env` and `auth/` to an explicit absolute,
off-repository destination. It applies `umask 077` before creating a partial
archive, removes partial output on failure, atomically renames completed output,
and verifies mode `0600`.

**Does not fix:** this repository cannot prove an operator ran the backup or
that the external destination is durable.

## 5. Enforce JS-to-Swift runtime-value parity

`contracts/config/runtime-constants.json` records the reviewed values mirrored
by Swift. Relay tests bind the public runtime/wire modules and every relay
runtime re-export (including the PWA-only keep-warm value) to their owners. iOS
tests bind the explicit Swift mirror to the shared contract. The wire-message
shape corpus remains separately under `contracts/fixtures/`.

**Does not fix:** this is parity enforcement, not cross-language code
generation. A newly mirrored value must be added explicitly to the contract and
both test maps.

## 6. Enforce deployment-identity parity

`contracts/config/deployment.json` is a reviewed parity contract for the iOS
pairing host, associated-domain entitlement, compiled bundle identifier, and
the relay's live Apple App Site Association response. Tests exercise the
compiled iOS representation and the relay HTTP boundary.

**Does not fix:** the values remain represented in platform/runtime files; this
is drift detection, not a generated single source. Domain changes still require
deployment configuration and Apple Developer portal updates.

## 7. Document the deauthorized-phone snapshot boundary

`relay/src/pairing.js` now names and validates the exact detached connection
snapshot it consumes during credential replacement. `server.js` constructs the
wrapper and pairing code validates it before use.

**Does not fix:** the repository does not enable JavaScript type checking, so
the JSDoc contract is documentation plus runtime validation, not a compiler-
enforced cross-module type.

## 8. Add a separate pairing-readiness diagnostic

`/healthz` intentionally remains pure liveness because Caddy and the container
healthcheck depend on it; turning a pairing-only fault into failed liveness
would take healthy clicking offline. `/readyz` separately probes the auth-store
snapshot and returns a closed, redacted status contract. Missing, invalid, or
throwing probes fail closed.

**Does not fix:** `/readyz` is not wired to the container healthcheck or an
external alert. It is an operator diagnostic surface.

## Verification contract

The merge gate is: the full relay, macOS, and iOS suites pass with zero skipped
tests; release-workflow validators pass; generated Xcode projects match their
XcodeGen specs; and `git diff --check` is clean. Exact counts belong in the PR
because they change whenever a regression test is added.
