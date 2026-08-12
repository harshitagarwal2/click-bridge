# Private CI/CD Design

## Goal

Automate Click Bridge validation and OCI production deployment while keeping
the repository, container images, relay tokens, and deployment credentials
private.

## Scope

The delivery system covers:

- Node 24 relay and PWA checks;
- the production Dockerfile and Compose model;
- macOS Swift build and unit tests;
- the native iOS project at `ios/project.yml`, scheme `ClickBridgePhone`, when
  that project lands;
- immutable deployment to the existing OCI SJC VM;
- post-deployment HTTPS/WSS verification and automatic rollback;
- dependency update PRs for npm, Docker, and GitHub Actions.

Physical iPhone volume-button behavior, macOS Accessibility authorization, and
an OctoBrowser click remain device acceptance tests. Hosted CI cannot prove
those hardware and TCC behaviors.

## Architecture

### Pull-request CI

`.github/workflows/ci.yml` runs for pull requests, pushes to `main`, and manual
dispatches. It grants `contents: read`, cancels superseded runs on the same ref,
and uses unique job names.

The Linux job runs on `ubuntu-24.04` and:

1. selects Node 24;
2. runs `npm ci` and `npm run check` in `relay/`;
3. validates shell and workflow files;
4. validates Compose using fixed non-production test tokens;
5. builds the production image;
6. starts the relay on loopback and waits for `/healthz`.

The Apple job runs on the ARM `macos-15` runner and:

1. installs XcodeGen;
2. regenerates the macOS Xcode project and rejects generated-project drift;
3. runs the `ClickBridgeMac` tests and an unsigned Release build;
4. when `ios/project.yml` exists, generates the iOS project and runs the
   `ClickBridgePhone` simulator tests and unsigned build.

The jobs run in parallel so the expensive Apple lane does not delay Linux
feedback.

### OCI deployment

`.github/workflows/deploy-oci.yml` is triggered by a successful `CI` workflow
run whose source event is a push to `main`. The deployment workflow checks out
the exact successful commit, serializes production deploys, and uses a GitHub
`production` environment.

GitHub stores only a dedicated deployment SSH private key. Its corresponding
public key is installed for the OCI `opc` account. The existing personal SSH
key is not uploaded. The following repository configuration is required:

- secret `OCI_DEPLOY_SSH_KEY`;
- variable `OCI_DEPLOY_HOST`;
- variable `OCI_DEPLOY_USER` with value `opc`;
- variable `OCI_DEPLOY_KNOWN_HOSTS` containing the pinned host-key line;
- variable `CLICK_BRIDGE_DOMAIN` with value
  `clickbridge-sjc.duckdns.org`.

`PHONE_TOKEN` and `MAC_TOKEN` remain only in the mode-0600 OCI file
`/opt/click-bridge/shared/secrets.env`. They never enter GitHub.

The workflow rsyncs the exact commit into
`/opt/click-bridge/releases/<40-character-git-sha>`, then invokes the tracked
deployment script. OCI builds the image natively on Arm64 and reuses Docker's
layer cache. The script candidate-tests the image before switching Compose,
runs the authenticated WSS smoke from the VM without printing tokens, and
writes `current-release` only after every gate succeeds. Any failure after the
switch restores `previous-release` and rechecks health.

No image is published to GHCR, OCIR, Docker Hub, or another registry.

## GitHub repository settings

The repository remains private. Configure:

- default workflow token: read-only;
- fork pull-request workflows: disabled;
- action sources: only repository-owned actions and the explicitly used
  `actions/*` actions;
- required full-length SHA pins for every `uses:` reference;
- artifact/log retention: 14 days;
- squash merging enabled as the canonical merge mode;
- automatic head-branch deletion enabled;
- stale-branch update suggestions enabled.

Private-repository branch protection/rulesets are not available on the
current GitHub Free plan. Delivery therefore performs the equivalent operator
gate: watch every PR check to completion and merge only when all checks pass.

## Failure handling

- A PR failure never reaches deployment.
- A superseded PR run is cancelled.
- Production deployment concurrency is one; a newer main commit queues rather
  than interrupting an active deployment.
- SSH host identity is pinned; `StrictHostKeyChecking` remains enabled.
- The remote candidate must become healthy before Compose changes.
- A failed live health or WSS smoke invokes rollback.
- A missing previous release produces a failed deployment and preserves all
  diagnostic state; it never deletes the current installation.
- Release directories and images are immutable by git SHA. Cleanup retains the
  active, previous, and newest third release.

## Acceptance criteria

1. CI passes on the delivery PR for Linux, Docker, macOS, and the iOS target if
   it has landed.
2. Workflow YAML passes `actionlint`; shell passes `shellcheck` and `bash -n`.
3. Every external action is pinned to a full commit SHA.
4. The PR is inspected in Chrome and merged only after all checks are green.
5. The successful `main` CI run triggers exactly one production deployment.
6. OCI reports the new git SHA as `current-release`; HTTPS health and the
   authenticated WSS smoke pass.
7. Repository visibility remains private and no container package is public.

