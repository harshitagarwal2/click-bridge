# Xcode Cloud Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Click Bridge iOS project deterministic and safe to build in Xcode Cloud while preserving GitHub Actions as the cross-platform CI owner.

**Architecture:** XcodeGen remains the checked-in iOS project source of truth. A post-clone hook beside `ios/ClickBridgePhone.xcodeproj` installs the repository-pinned XcodeGen release, verifies its checksum, and regenerates the project before Xcode Cloud builds it. GitHub CI uses the same pinned release and rejects generated-project drift; Xcode Cloud owns iOS TestFlight delivery only after the first verified workflow, so the existing GitHub TestFlight uploader stays disabled as a fallback rather than creating duplicate builds.

**Tech Stack:** Xcode Cloud, XcodeGen 2.46.0, zsh/POSIX shell, Xcode 15+, GitHub Actions, Node.js contract tests.

## Global Constraints

- Preserve all existing uncommitted iOS, relay, documentation, and generated-project work.
- Do not create, edit, or dispatch an external Xcode Cloud or GitHub workflow from this plan.
- Do not commit, move, upload, or delete local signing material.
- Do not add dependencies.
- Keep `ios/project.yml` as the iOS project source of truth and `ClickBridgePhone` as the shared scheme.
- Use one TestFlight upload owner per release tag; never enable Xcode Cloud and GitHub TestFlight uploads for the same tag.

---

### Task 1: Lock the CI contract

**Files:**
- Modify: `.github/scripts/test-workflows.mjs`

**Interfaces:**
- Consumes: existing workflow text and repository files.
- Produces: assertions for the XcodeGen version, checksum, source URL, drift checks, executable post-clone hook, credential ignores, and Xcode Cloud runbook.

- [ ] **Step 1: Add failing assertions**

  Require XcodeGen `2.46.0`, SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`, generated-project drift checks for both Apple projects, an executable `ios/ci_scripts/ci_post_clone.sh`, Apple signing ignore rules, and `docs/xcode-cloud.md`.

- [ ] **Step 2: Run the contract test and confirm the intended failure**

  Run: `node .github/scripts/test-workflows.mjs`

  Expected: failure because the Xcode Cloud hook and runbook do not exist yet.

### Task 2: Make XcodeGen deterministic in GitHub CI

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/testflight.yml`
- Modify: `.github/workflows/macos-notarized-release.yml`
- Modify: `.github/scripts/validate-release-workflows.rb`

**Interfaces:**
- Consumes: the official XcodeGen 2.46.0 release asset.
- Produces: one verified `xcodegen` binary in `RUNNER_TEMP`, then deterministic macOS and iOS projects.

- [ ] **Step 1: Replace the floating Homebrew install**

  Download `https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip`, verify the required SHA-256 with `shasum -a 256 -c -`, create and install into the `RUNNER_TEMP` prefix, add its `bin` directory to `GITHUB_PATH`, and require the exact `Version: 2.46.0` output. Apply the same prefix fix to the existing TestFlight and notarized-macOS release workflows.

- [ ] **Step 2: Reject project drift**

  After each `xcodegen generate`, compare the corresponding `.xcodeproj` and generated `Info.plist` with Git and reject both tracked diffs and newly generated untracked files so a source-spec drift cannot pass CI.

### Task 3: Add the Xcode Cloud post-clone and versioning seams

**Files:**
- Create: `ios/ci_scripts/ci_post_clone.sh`
- Create: `ios/TestFlight/WhatToTest.en-US.txt`
- Modify: `.gitignore`
- Modify: `ios/project.yml`
- Modify: `ios/ClickBridgePhone.xcodeproj/project.pbxproj`
- Modify: `ios/ClickBridgePhone/Info.plist`
- Modify: `ios/Config/Base.xcconfig`
- Modify: `ios/Config/Local.xcconfig.example`

**Interfaces:**
- Consumes: `ios/project.yml` and the pinned XcodeGen release.
- Produces: a regenerated `ios/ClickBridgePhone.xcodeproj` before Xcode Cloud invokes Xcode.

- [ ] **Step 1: Add the executable hook**

  Use `#!/bin/sh` with `set -eu`, prefer an already-installed exact XcodeGen 2.46.0 binary, otherwise download and verify the official archive in a temporary directory, then run `xcodegen generate` from `ios/`.

- [ ] **Step 2: Prevent accidental Apple credential commits**

  Ignore `AuthKey_*.p8`, `*.p12`, `*.cer`, `*.mobileprovision`, `*.provisionprofile`, and `*.certSigningRequest`. Do not remove any existing local file.

- [ ] **Step 3: Route Cloud version values into the archive**

  Set `CFBundleShortVersionString` to `$(MARKETING_VERSION)` and `CFBundleVersion` to `$(CURRENT_PROJECT_VERSION)` in the XcodeGen spec and generated Info.plist, then add concrete internal TestFlight instructions at `ios/TestFlight/WhatToTest.en-US.txt`.

- [ ] **Step 4: Give automatic signing a deterministic team**

  Set `DEVELOPMENT_TEAM = EC3R6XQ226` in `ios/Config/Base.xcconfig`; retain the optional ignored `Local.xcconfig` include so another local team can override it without changing the repository.

### Task 4: Document the account-specific workflow design

**Files:**
- Create: `docs/xcode-cloud.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the observed App Store Connect account state and repository constraints.
- Produces: one setup and operating runbook for the first workflow, PR checks, scheduled confidence, TestFlight, secrets, build numbers, notifications, and rollback.

- [ ] **Step 1: Record current verified state**

  Record that Click Bridge app `6800644446` is Prepare for Submission, Xcode Cloud has 25 hours available and 0 minutes used, no personal source-control account is visible, and GitHub branch rules are unavailable for this private repository on its current plan.

- [ ] **Step 2: Define the three workflows**

  Specify `PR - iOS checks`, `Weekly - iOS confidence`, and `Release - TestFlight`, including triggers, actions, destinations, notifications, clean-build policy, and single-owner TestFlight rule.

- [ ] **Step 3: Link the runbook from the repository front door**

  Add one concise README pointer without changing the canonical product scope.

### Task 5: Verify without disturbing user work

**Files:**
- Verify only; do not rewrite the user's existing dirty iOS or relay files.

**Interfaces:**
- Consumes: the integrated repository state.
- Produces: fresh evidence for CI contracts, shell correctness, deterministic project generation, iOS tests, and Release build.

- [ ] **Step 1: Run focused static checks**

  Run `node .github/scripts/test-workflows.mjs`, `sh -n ios/ci_scripts/ci_post_clone.sh`, and ShellCheck when available.

- [ ] **Step 2: Generate projects outside the working tree**

  Run XcodeGen 2.46.0 with `--project` pointing at temporary directories and compare the generated projects with the checked-in projects, accounting for the user's current uncommitted generated-test entry.

- [ ] **Step 3: Run iOS verification through XcodeBuildMCP**

  Discover simulator commands with `xcodebuildmcp simulator --help`, then run the smallest supported test and Release-build commands for the shared `ClickBridgePhone` scheme.

- [ ] **Step 4: Review the final diff**

  Confirm only `.gitignore`, `.github/scripts/test-workflows.mjs`, `.github/scripts/validate-release-workflows.rb`, `.github/workflows/ci.yml`, `.github/workflows/testflight.yml`, `.github/workflows/macos-notarized-release.yml`, `ios/project.yml`, `ios/ClickBridgePhone.xcodeproj/project.pbxproj`, `ios/ClickBridgePhone/Info.plist`, `ios/Config/Base.xcconfig`, `ios/Config/Local.xcconfig.example`, `ios/ci_scripts/ci_post_clone.sh`, `ios/TestFlight/WhatToTest.en-US.txt`, `docs/xcode-cloud.md`, `README.md`, and this plan belong to the Xcode Cloud hardening change. The generated project file is shared with the SwiftUI settings-presentation test addition and must reflect both sources of truth.
