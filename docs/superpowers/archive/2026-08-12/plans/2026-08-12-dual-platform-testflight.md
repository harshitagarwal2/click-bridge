# Dual-Platform TestFlight Implementation Plan

**Archive status:** Historical implementation plan; not an active task queue.
Checklist state is preserved as written. External release gates below remain
evidence requirements, not inferred passes.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the protected TestFlight release so one immutable tag and build number produce and upload both Click Bridge iOS and macOS builds.

**Architecture:** Keep the existing iOS Fastlane lane and Developer ID macOS workflow intact. Add a dedicated sandbox entitlement file and macOS Fastlane lane, then extend the existing protected TestFlight job to install both platforms' ephemeral signing assets and invoke both lanes sequentially.

**Tech Stack:** GitHub Actions, Ruby 3.3, Fastlane 2.237.0, XcodeGen 2.46.0, Xcode 26+, App Store Connect API keys, Apple code signing.

## Global Constraints

- App Store Connect Team ID is `EC3R6XQ226`.
- iOS bundle ID remains `com.clickbridge.phone`.
- macOS bundle ID remains `com.clickbridge.mac`.
- The direct Developer ID/notarized macOS workflow must remain unsandboxed and behaviorally unchanged.
- TestFlight uploads do not distribute to testers or submit for review.
- No certificate, provisioning profile, API key, archive, `.ipa`, or `.pkg` may be committed or retained as a GitHub artifact.
- Every signing input and output must be removed from the runner in an `always()` cleanup step.

---

### Task 1: Lock the dual-platform workflow contract

**Files:**
- Modify: `.github/scripts/validate-release-workflows.rb`
- Test: `.github/scripts/validate-release-workflows.rb`

**Interfaces:**
- Consumes: `.github/workflows/testflight.yml`, `fastlane/Fastfile`, and `mac/ClickBridgeMac/ClickBridgeMac-AppStore.entitlements` as text contracts.
- Produces: fail-closed validation for the macOS TestFlight lane, signing inputs, sandbox entitlements, upload parameters, and cleanup.

- [ ] **Step 1: Write the failing contract assertions**

Add assertions that require these exact concepts in the TestFlight release surface:

```ruby
%w[
  MAC_DISTRIBUTION_CERTIFICATE_BASE64
  MAC_DISTRIBUTION_CERTIFICATE_PASSWORD
  MAC_INSTALLER_CERTIFICATE_BASE64
  MAC_INSTALLER_CERTIFICATE_PASSWORD
  MAC_PROVISIONING_PROFILE_BASE64
  MAC_PROVISIONING_PROFILE_NAME
  ClickBridgeMac.pkg
  "fastlane mac upload_testflight"
].each do |contract|
  fail_contract("TestFlight workflow is missing #{contract}") unless testflight.include?(contract.delete_prefix('"').delete_suffix('"'))
end

mac_entitlements = File.read(File.join(ROOT, "mac", "ClickBridgeMac", "ClickBridgeMac-AppStore.entitlements"))
%w[com.apple.security.app-sandbox com.apple.security.network.client].each do |entitlement|
  fail_contract("Mac TestFlight entitlements are missing #{entitlement}") unless mac_entitlements.include?(entitlement)
end

fail_contract("Fastfile is missing the macOS TestFlight platform") unless fastfile.include?("platform :mac do")
fail_contract("Mac TestFlight upload must select macOS") unless fastfile.include?('app_platform: "osx"')
fail_contract("Mac TestFlight upload must use a pkg") unless fastfile.include?("pkg: output_path")
```

- [ ] **Step 2: Run the validator and confirm the intended failure**

Run: `bundle exec ruby .github/scripts/validate-release-workflows.rb`

Expected: FAIL because the Mac entitlement file and Mac TestFlight lane do not exist.

- [ ] **Step 3: Commit the red test**

```bash
git add .github/scripts/validate-release-workflows.rb
git commit -m "test: require Mac TestFlight release contract"
```

### Task 2: Add the sandboxed Mac App Store build lane

**Files:**
- Create: `mac/ClickBridgeMac/ClickBridgeMac-AppStore.entitlements`
- Modify: `fastlane/Fastfile`
- Test: `.github/scripts/validate-release-workflows.rb`

**Interfaces:**
- Consumes: `release_version`, `build_number`, `APPLE_TEAM_ID`, `MAC_PROVISIONING_PROFILE_NAME`, and the existing App Store Connect API key environment.
- Produces: `$RUNNER_TEMP/ClickBridgeMac.pkg` and a TestFlight upload for `com.clickbridge.mac`.

- [ ] **Step 1: Add the minimum App Store entitlements**

Create a plist containing only:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

- [ ] **Step 2: Add `platform :mac` and `upload_testflight`**

The lane must call `build_mac_app` with project `mac/ClickBridgeMac.xcodeproj`, scheme `ClickBridgeMac`, Release configuration, output `ClickBridgeMac.pkg`, export method `app-store`, manual profile mapping for `com.clickbridge.mac`, the Mac Installer Distribution selector, and command-line `CODE_SIGN_ENTITLEMENTS=ClickBridgeMac/ClickBridgeMac-AppStore.entitlements`.

Then call `upload_to_testflight` with `pkg: output_path`, `app_platform: "osx"`, `skip_submission: true`, `skip_waiting_for_build_processing: true`, `distribute_external: false`, and `uses_non_exempt_encryption: false`.

- [ ] **Step 3: Run the contract validator**

Run: `bundle exec ruby .github/scripts/validate-release-workflows.rb`

Expected: still FAIL only on missing workflow signing/upload contracts.

- [ ] **Step 4: Verify direct macOS defaults remain unchanged**

Run: `xcodebuildmcp project-discovery show-build-settings --project-path mac/ClickBridgeMac.xcodeproj --scheme ClickBridgeMac`

Expected: default macOS signing remains manual/ad-hoc with App Sandbox disabled.

- [ ] **Step 5: Commit the Mac lane**

```bash
git add mac/ClickBridgeMac/ClickBridgeMac-AppStore.entitlements fastlane/Fastfile
git commit -m "feat: add Mac TestFlight build lane"
```

### Task 3: Extend protected TestFlight signing and upload

**Files:**
- Modify: `.github/workflows/testflight.yml`
- Modify: `docs/release-automation.md`
- Test: `.github/scripts/validate-release-workflows.rb`

**Interfaces:**
- Consumes: the existing protected `testflight` environment, release tag/build inputs, App Store Connect API key, iOS signing inputs, new Mac signing inputs, and `APPLE_TEAM_ID`.
- Produces: sequential iOS and macOS uploads for the same commit, version, and build number.

- [ ] **Step 1: Require and install Mac signing material**

Add the Mac distribution certificate, installer certificate, Mac provisioning profile, and passwords to the ephemeral-signing step. Import both certificates into the temporary keychain, decode the `.provisionprofile`, install it under `~/Library/MobileDevice/Provisioning Profiles`, and export `MAC_PROVISIONING_PROFILE_NAME`.

- [ ] **Step 2: Generate both Xcode projects**

Keep the existing iOS generation step and add a macOS XcodeGen step before upload.

- [ ] **Step 3: Upload iOS then macOS**

Keep the existing iOS command and add:

```bash
bundle exec fastlane mac upload_testflight release_version:"$RELEASE_VERSION" build_number:"$BUILD_NUMBER"
```

- [ ] **Step 4: Expand cleanup**

Remove the installed Mac profile, Mac certificate inputs, `ClickBridgeMac.pkg`, and all existing temporary signing material under `if: ${{ always() }}`.

- [ ] **Step 5: Update the operator contract**

Document the new Mac secrets, two-app-record requirement, aligned build-number behavior, and non-atomic partial-upload recovery.

- [ ] **Step 6: Run release validators**

Run: `bundle exec ruby .github/scripts/validate-release-workflows.rb`

Expected: PASS.

Run: `node .github/scripts/test-workflows.mjs`

Expected: PASS.

- [ ] **Step 7: Commit workflow and documentation**

```bash
git add .github/workflows/testflight.yml docs/release-automation.md
git commit -m "ci: upload iOS and macOS builds to TestFlight"
```

### Task 4: Verify product and release artifacts

**Files:**
- Verify only: `ios/**`, `mac/**`, `.github/**`, `fastlane/**`

**Interfaces:**
- Consumes: the integrated branch.
- Produces: fresh test, build, contract, and signing evidence for the PR.

- [ ] **Step 1: Run iOS tests**

Run `xcodebuildmcp simulator test` against the available iPhone simulator.

Expected: 66 passed, 0 failed, 0 skipped.

- [ ] **Step 2: Run macOS tests**

Run `xcodebuildmcp macos test` for `ClickBridgeMac`.

Expected: 39 passed, 0 failed, 0 skipped.

- [ ] **Step 3: Build both Release products without distribution secrets**

Run the iOS Release simulator build and the default macOS Release build.

Expected: both succeed; the direct macOS build remains unsandboxed.

- [ ] **Step 4: Validate the App Store entitlement file**

Run `plutil -lint mac/ClickBridgeMac/ClickBridgeMac-AppStore.entitlements` and inspect its two boolean keys.

Expected: valid plist with App Sandbox and outbound network access enabled.

- [ ] **Step 5: Inspect the complete diff**

Run `git diff --check origin/main...HEAD` and review `git diff origin/main...HEAD` for secrets, generated build output, unpinned actions, or changes to the direct macOS release.

### Task 5: Publish the PR and complete Apple-side release

**Files:**
- No additional repository files unless review findings require a follow-up commit.

**Interfaces:**
- Consumes: a verified branch and the App Store Connect Account Holder's accepted agreement.
- Produces: a GitHub PR and two visible App Store Connect/TestFlight builds.

- [ ] **Step 1: Push and open the PR**

Push `codex/dual-platform-testflight` and create a ready-for-review PR describing the dual upload, preserved direct Mac lane, test counts, and Apple agreement gate.

- [ ] **Step 2: Wait for CI and address failures**

Use `gh pr checks --watch` and add focused commits for any real failures.

- [ ] **Step 3: Create the App Store Connect records after agreement acceptance**

Create separate iOS and macOS `Click Bridge` records using bundle IDs `com.clickbridge.phone` and `com.clickbridge.mac`, English (U.S.), and SKUs `clickbridge-phone-20260812` and `clickbridge-macos-2026`.

- [ ] **Step 4: Configure protected release signing inputs**

Store the App Store Connect API key, certificate `.p12` files, and provisioning profiles only in the protected `testflight` environment; set `APPLE_TEAM_ID=EC3R6XQ226`.

- [ ] **Step 5: Dispatch and verify**

Create an immutable `vX.Y.Z` tag on the merged release commit, dispatch TestFlight with a new positive build number, and verify both platform builds appear in App Store Connect as Processing or Valid.
