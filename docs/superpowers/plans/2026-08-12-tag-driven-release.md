# Tag-driven Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically start TestFlight, GHCR, and draft macOS releases from a matching version tag while retaining manual App Store submission.

**Architecture:** Three tag-triggered workflows derive their release tag from `github.ref_name` and their Apple version/build from the shared version reader after checkout. The App Store workflow remains manual because processed TestFlight builds and an explicit review decision are prerequisites.

**Tech Stack:** GitHub Actions YAML, Bash, Ruby workflow contract validation, Node.js workflow contract tests.

## Global Constraints

- Do not change environment-scoped secrets or variables.
- Retain existing immutable-tag, exact-SHA, main-reachability, and CI-success guards.
- Do not automate App Store review submission.
- Do not add dependencies.

---

### Task 1: Specify automatic trigger and version-resolution contracts

**Files:**
- Modify: `.github/scripts/validate-release-workflows.rb`
- Test: `.github/scripts/validate-release-workflows.rb`

**Interfaces:**
- Consumes: release workflow YAML documents.
- Produces: validation that the three publication workflows trigger on `v*` tags and the App Store workflow remains dispatch-only.

- [ ] **Step 1: Write the failing contract assertions**

Require `testflight.yml`, `ghcr-relay.yml`, and `macos-notarized-release.yml` to declare `push.tags: ["v*"]` in addition to `workflow_dispatch`, and require their source guard to obtain `RELEASE_TAG` from `github.ref_name` for tag pushes. Require `app-store-submit.yml` to keep only `workflow_dispatch`.

- [ ] **Step 2: Run the validator to verify it fails**

Run: `ruby .github/scripts/validate-release-workflows.rb`

Expected: failure because all three publication workflows are currently dispatch-only and use `inputs.release_tag`.

- [ ] **Step 3: Implement the minimal validator changes**

Replace the uniform manual-trigger assertion with per-workflow trigger expectations. Keep the existing tag/SHA, main-reachability, and CI-success assertions unchanged.

- [ ] **Step 4: Run the validator to verify it passes**

Run: `ruby .github/scripts/validate-release-workflows.rb`

Expected: the validator reaches the workflow contracts after the YAML updates in Task 2.

### Task 2: Make non-review release lanes tag-driven

**Files:**
- Modify: `.github/workflows/testflight.yml`
- Modify: `.github/workflows/ghcr-relay.yml`
- Modify: `.github/workflows/macos-notarized-release.yml`
- Test: `.github/scripts/test-workflows.mjs`

**Interfaces:**
- Consumes: `github.ref_name`, `github.sha`, and `.github/scripts/read-apple-version.sh`.
- Produces: automatic release workflows that read a matching tag and shared build/version without dispatch inputs.

- [ ] **Step 1: Write the failing workflow-contract assertions**

Add assertions that each automatic workflow contains `push:` with a `v*` tag filter, resolves `RELEASE_TAG` from `github.ref_name`, and has no required `release_tag` or `build_number` dispatch input. Assert `app-store-submit.yml` retains both manual inputs.

- [ ] **Step 2: Run the workflow contract suite to verify it fails**

Run: `node .github/scripts/test-workflows.mjs`

Expected: failure because current workflows declare only manual dispatch and use dispatch inputs.

- [ ] **Step 3: Implement automatic triggers and shared-version resolution**

Add the tag trigger to the three workflows. Resolve the tag from `github.ref_name` for push runs and use the checked-out `read-apple-version.sh` output for the TestFlight build number. Preserve manual dispatch as a recovery route only if the workflow can safely select the same tag/build source.

- [ ] **Step 4: Run focused contracts to verify they pass**

Run: `ruby .github/scripts/validate-release-workflows.rb && node .github/scripts/test-workflows.mjs`

Expected: both validators succeed.

### Task 3: Update release operator documentation

**Files:**
- Modify: `docs/release-automation.md`

**Interfaces:**
- Consumes: tag-trigger and manual App Store submission behavior.
- Produces: accurate release procedure and recovery guidance.

- [ ] **Step 1: Update the release sequence**

Replace manual dispatch instructions for TestFlight, GHCR, and macOS release with the matching-tag trigger. Keep the App Store workflow as the deliberate manual step after processing.

- [ ] **Step 2: Run final verification**

Run: `ruby .github/scripts/validate-release-workflows.rb && node .github/scripts/test-workflows.mjs && git diff --check`

Expected: both contract suites pass and the diff contains no whitespace errors.
