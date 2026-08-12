# Private CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fast private CI and automatic rollback-capable OCI deployment for every verified `main` commit.

**Architecture:** Parallel Linux and Apple CI jobs validate the source, container, macOS app, and optional iOS app. A separate `workflow_run` deployment checks out the exact successful SHA, transfers an immutable release over pinned-host SSH, builds natively on OCI Arm64, smoke-tests it, and rolls back automatically on failure.

**Tech Stack:** GitHub Actions, Node.js 24, Docker Compose, Bash, XcodeGen, xcodebuild, rsync, SSH, OCI Compute, Caddy.

## Global Constraints

- The GitHub repository remains private.
- No image is published to a public or private registry.
- Relay role tokens remain only in `/opt/click-bridge/shared/secrets.env` on OCI.
- All external actions use full-length commit SHA pins.
- Default workflow permission is `contents: read`.
- The iOS project interface is `ios/project.yml` with shared scheme `ClickBridgePhone`.
- Physical iPhone volume-button and macOS Accessibility behavior remain explicit hardware gates.

---

### Task 1: Lock the CI workflow contract

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/ci/verify-workflows.mjs`
- Create: `scripts/ci/test-workflows.mjs`

**Interfaces:**
- Consumes: `relay/package-lock.json`, `mac/project.yml`, optional `ios/project.yml`.
- Produces: deterministic validation of workflow triggers, permissions, action pins, runner labels, and job names.

- [ ] **Step 1: Write the workflow contract test**

Create fixtures in the test itself and assert that CI has `pull_request`,
`push`, `workflow_dispatch`, `contents: read`, concurrency cancellation, Linux
and Apple jobs, Node 24, Docker health, `ClickBridgeMac`, and conditional
`ClickBridgePhone` commands. Assert every `uses:` value ends in a 40-character
hex SHA.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
node scripts/ci/test-workflows.mjs
```

Expected: failure because `.github/workflows/ci.yml` does not exist.

- [ ] **Step 3: Implement the verifier and CI workflow**

Use unique jobs named `relay-container` and `apple-clients`. Linux uses
`ubuntu-24.04`; Apple uses `macos-15`. Both have explicit timeouts. Pin
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (`v7.0.1`) and
`actions/setup-node@820762786026740c76f36085b0efc47a31fe5020`
(`v7.0.0`).

- [ ] **Step 4: Verify GREEN locally**

Run:

```bash
node scripts/ci/test-workflows.mjs
node scripts/ci/verify-workflows.mjs
```

Expected: both exit zero and print no secret values.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml scripts/ci
git commit -m "ci: validate relay and Apple clients"
```

### Task 2: Add immutable OCI deployment scripts

**Files:**
- Create: `deploy/oci/deploy-release.sh`
- Create: `deploy/oci/rollback-release.sh`
- Create: `deploy/oci/test-release-scripts.sh`
- Modify: `docs/oci-deployment.md`
- Modify: `docs/oci-recovery.md`

**Interfaces:**
- Consumes: `CLICK_BRIDGE_RELEASE` as a 40-character lowercase git SHA and `/opt/click-bridge/shared/secrets.env`.
- Produces: `/opt/click-bridge/current-release`, `/opt/click-bridge/previous-release`, one healthy Compose stack, and automatic rollback.

- [ ] **Step 1: Write fake-Docker deployment tests**

Create a temporary fake command directory that records `docker compose build`,
candidate `docker run`, health polling, `up -d`, WSS smoke, and rollback calls.
Cover successful first deployment, successful replacement, candidate failure,
post-switch smoke failure, missing previous release, invalid release ID, and
mode-not-0600 secrets.

- [ ] **Step 2: Run tests and verify RED**

```bash
bash deploy/oci/test-release-scripts.sh
```

Expected: failure because the release scripts do not exist.

- [ ] **Step 3: Implement deploy and rollback scripts**

Use `set -Eeuo pipefail`, validate every resolved path is under
`/opt/click-bridge/releases/<sha>`, capture the previous release before the
switch, trap post-switch errors, and never run recursive deletion. Use the
shared env file directly with `docker compose --env-file`. Run the existing
authenticated `relay/scripts/smoke-relay.mjs` without shell tracing.

- [ ] **Step 4: Verify scripts**

```bash
bash -n deploy/oci/deploy-release.sh
bash -n deploy/oci/rollback-release.sh
bash -n deploy/oci/test-release-scripts.sh
bash deploy/oci/test-release-scripts.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add deploy/oci docs/oci-deployment.md docs/oci-recovery.md
git commit -m "ops: automate immutable OCI releases"
```

### Task 3: Add the private deployment workflow and dependency automation

**Files:**
- Create: `.github/workflows/deploy-oci.yml`
- Create: `.github/dependabot.yml`
- Modify: `scripts/ci/test-workflows.mjs`

**Interfaces:**
- Consumes: successful `CI` workflow run on a push to `main`; GitHub secret `OCI_DEPLOY_SSH_KEY`; variables `OCI_DEPLOY_HOST`, `OCI_DEPLOY_USER`, `OCI_DEPLOY_KNOWN_HOSTS`, and `CLICK_BRIDGE_DOMAIN`.
- Produces: one serialized `production` environment deployment for the exact successful SHA.

- [ ] **Step 1: Extend contract tests and verify RED**

Assert `workflow_run` is restricted to `CI`, the job checks conclusion/event/
branch, checkout uses `head_sha`, production concurrency does not cancel an
active deploy, SSH uses a dedicated key plus pinned known-hosts data, rsync
targets a SHA release directory, and no token or registry secret exists.

- [ ] **Step 2: Implement deployment workflow**

Use only SHA-pinned `actions/checkout`; prepare the key under `$RUNNER_TEMP`
with mode 0600; write known-hosts with mode 0600; use
`StrictHostKeyChecking=yes`; rsync the exact checkout; invoke
`deploy/oci/deploy-release.sh` remotely; verify public health from the runner.

- [ ] **Step 3: Add grouped Dependabot updates**

Configure weekly update groups for npm in `/relay`, Docker in `/`, and
`github-actions` in `/`, with a maximum of three open PRs per ecosystem.

- [ ] **Step 4: Verify**

```bash
node scripts/ci/test-workflows.mjs
node scripts/ci/verify-workflows.mjs
bash deploy/oci/test-release-scripts.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add .github deploy/oci scripts/ci
git commit -m "ci: deploy verified main commits to OCI"
```

### Task 4: Configure private GitHub and OCI credentials

**Files:**
- Modify through GitHub settings: Actions policy, retention, merge settings, repository variables/secrets, `production` environment.
- Modify on OCI: append one dedicated public key to `opc` authorized keys.

**Interfaces:**
- Consumes: a newly generated `ed25519` deployment keypair.
- Produces: GitHub secret/variables and an OCI account that accepts only the corresponding public key.

- [ ] **Step 1: Generate a dedicated deployment key**

Generate it in a mode-0700 temporary directory with comment
`click-bridge-github-actions`; verify the public-key fingerprint and never
print the private key.

- [ ] **Step 2: Install only the public key on OCI**

Append idempotently to `~opc/.ssh/authorized_keys`, preserve mode 0600, and
prove a read-only SSH command succeeds with the dedicated key.

- [ ] **Step 3: Configure GitHub through Chrome**

Store the private key only as `OCI_DEPLOY_SSH_KEY`; create the four variables;
create the `production` environment; retain private visibility; select read-only
workflow permissions; require SHA pins; restrict allowed actions; set retention
to 14 days; enable squash merge, stale-branch updates, and branch deletion.

- [ ] **Step 4: Remove the local private key after a successful deployment**

The exact temporary key path is deleted only after GitHub deploys successfully
and a second SSH verification confirms the installed public key. The GitHub
secret is then the only private-key copy.

### Task 5: Deliver, observe, merge, and verify production

**Files:**
- Modify as needed after real runner feedback: `.github/**`, `scripts/ci/**`, `deploy/oci/**`.

**Interfaces:**
- Consumes: completed app/OCI commits and the final iOS path/scheme contract.
- Produces: merged CI/CD PR and a verified private production deployment.

- [ ] **Step 1: Rebase on current private `origin/main`**

Require a clean worktree, fetch, and rebase without force-pushing any shared
branch. Re-run all local checks after the rebase.

- [ ] **Step 2: Push and open the PR**

Push `codex/click-bridge-ci-cd`, open a ready PR to `main`, and include the
validation commands, private-deployment design, required variables, and
hardware-only acceptance gaps.

- [ ] **Step 3: Watch GitHub Actions in Chrome**

Inspect every job. Fix root causes on the same branch and rerun until Linux,
macOS, iOS (when present), and container checks are all green.

- [ ] **Step 4: Squash merge only when green**

Verify the PR merge base is current and no checks are pending or skipped
unexpectedly. Squash merge, verify the branch is deleted, and confirm the
repository remains private.

- [ ] **Step 5: Verify automatic OCI deployment**

Watch the `Deploy OCI` run, verify its source SHA equals merged `main`, then
confirm `/healthz`, HTTPS, WSS smoke, `current-release`, one relay replica, and
private TCP 8080.

- [ ] **Step 6: Record final evidence**

Update the deployment docs with workflow run/commit identifiers, runner
results, OCI release SHA, and the remaining physical iPhone/macOS acceptance
gates. Do not record tokens, private keys, or private OCI identifiers.
