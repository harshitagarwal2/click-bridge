# Superpowers planning index

This file is the lifecycle authority for Superpowers planning artifacts. Files under
`archive/` are historical design and implementation records, not active task queues.
Unchecked boxes inside an archived plan preserve the plan as written; they do not
mean that the repository is still executing that plan.

Archiving implementation work never changes an evidence gate to `PASS`. Physical,
credentialed, or service-side acceptance remains `NOT RUN`, `BLOCKED`, or otherwise
unverified until direct evidence records a different result.

## Active plans

None.

New work belongs under `plans/`, with its approved design under `specs/`. Add it
to this section while it remains an active queue.

## Archived on 2026-08-12

- **Mac Settings and remote phone pairing:**
  [plan](archive/2026-08-12/plans/2026-08-12-mac-settings-pairing.md) and
  [design](archive/2026-08-12/specs/2026-08-12-mac-settings-pairing-design.md).
  Implementation is complete; physical iPhone scanning, public-relay
  enrollment, Accessibility-authorized clicking, signing, TestFlight, and
  production remain **NOT RUN**.

- **Native iOS volume client:**
  [plan](archive/2026-08-12/plans/2026-08-12-native-ios-volume-client.md) and
  [design](archive/2026-08-12/specs/2026-08-12-native-ios-volume-client-design.md).
  The signed physical-iPhone, public-relay, and harmless-target acceptance remains
  unproven by simulator or unit tests; follow the canonical
  [physical smoke gate](../physical-smoke-test.md), which remains **NOT RUN**.
- **Three independent clicks:**
  [plan](archive/2026-08-12/plans/2026-08-12-three-independent-clicks.md) and
  [design](archive/2026-08-12/specs/2026-08-12-three-independent-clicks-design.md).
  The real-phone/Octo acceptance remains **NOT RUN** until observed counts satisfy
  the physical smoke gate.
- **Dual-platform TestFlight:**
  [plan](archive/2026-08-12/plans/2026-08-12-dual-platform-testflight.md) and
  [design](archive/2026-08-12/specs/2026-08-12-dual-platform-testflight-design.md).
  Archive status does not assert current Apple agreements, signing access, upload,
  processing, or tester availability.
- **Private CI/CD:**
  [plan](archive/2026-08-12/plans/2026-08-12-private-ci-cd.md) and
  [design](archive/2026-08-12/specs/2026-08-12-private-ci-cd-design.md).
  Archive status does not assert current GitHub or OCI health, deployment success,
  rollback readiness, or repository visibility.
- **Xcode Cloud readiness:**
  [plan](archive/2026-08-12/plans/2026-08-12-xcode-cloud-readiness.md).
  Archive status does not assert that an external Xcode Cloud workflow has run.

## Lifecycle rules

1. Keep only current execution queues under `plans/` and their current approved
   designs under `specs/`.
2. When work leaves the active queue, move its plan and design together into a dated
   archive and add a direct entry above.
3. Keep implementation status separate from acceptance evidence. Never infer a
   physical-device, credentialed, deployment, or external-service result.
4. Preserve explicit `NOT RUN` and `BLOCKED` statements until the named environment
   is exercised and the observed result is recorded in its canonical evidence file.
