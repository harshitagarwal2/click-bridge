# Dual-Platform TestFlight Design

**Archive status:** Historical approved design; not an active implementation
queue. Release acceptance below remains an evidence requirement, not an
inferred pass.

**Status:** Approved on 2026-08-12

## Goal

Upload aligned iOS and macOS Click Bridge builds to App Store Connect TestFlight from one protected, manually dispatched GitHub workflow without changing the existing direct-download macOS release.

## Current state

- `ClickBridgePhone` already has a manual-signing Fastlane lane and protected `testflight` workflow.
- `ClickBridgeMac` is released outside the Mac App Store with Developer ID signing and notarization.
- The App Store Connect team is `EC3R6XQ226`.
- App Store Connect currently blocks new app records and uploads until the Account Holder accepts Apple's updated Developer Program License Agreement.
- The iOS and macOS products use different bundle IDs, so they require separate App Store Connect app records:
  - `com.clickbridge.phone`
  - `com.clickbridge.mac`

## Approaches considered

### One dual-platform TestFlight workflow — selected

Extend the existing protected `testflight` workflow to install both platforms' signing assets, build the iOS `.ipa` and macOS `.pkg`, and upload both without tester distribution. This gives one immutable tag/build-number gate, one release approval, aligned versions, and one cleanup contract.

The trade-off is that App Store Connect uploads are not atomic. If the second upload fails, the first build can already exist. The workflow must make that partial state explicit and remain safely rerunnable only with a new build number.

### Separate iOS and macOS TestFlight workflows

This isolates failures and credentials but creates two approvals, two dispatches, and a greater chance that platforms drift to different commits or build numbers.

### Keep macOS outside TestFlight

This preserves the current direct-download path but does not satisfy the requested Mac TestFlight deployment.

## Release architecture

The existing iOS lane remains the source of the iOS archive and upload behavior. A new Fastlane `mac` lane will:

1. set the requested marketing version and build number;
2. build an App Store `.pkg` from `ClickBridgeMac`;
3. sign the app with a Mac App Distribution or unified Apple Distribution identity;
4. sign the package with a Mac Installer Distribution identity;
5. embed the Mac App Store provisioning profile required by TestFlight;
6. upload the `.pkg` using the same App Store Connect API key, `app_platform: "osx"`, and no tester distribution.

The workflow will continue to require a protected `testflight` environment, an immutable `vX.Y.Z` tag, a positive integer build number, pinned actions, and ephemeral signing material. It will fail before any build when a required secret or variable is absent.

## macOS sandbox boundary

The direct Developer ID workflow remains unsandboxed and unchanged. The Mac TestFlight lane supplies a dedicated `ClickBridgeMac-AppStore.entitlements` file only through its command-line signing settings. That file enables:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`

`CGEvent.post` uses the separate PostEvent privacy service and remains technically compatible with App Sandbox, although App Review may separately evaluate whether the product use is acceptable. Internal TestFlight upload and testing do not claim App Store review approval.

## Signing inputs

The protected `testflight` environment must contain:

- existing App Store Connect API key secrets;
- iOS distribution certificate and App Store profile secrets;
- Mac App Distribution certificate and password;
- Mac Installer Distribution certificate and password;
- Mac App Store provisioning profile;
- `APPLE_TEAM_ID=EC3R6XQ226`.

Certificates, profiles, API keys, archives, `.ipa` files, and `.pkg` files remain ephemeral and are removed in an `always()` cleanup step. None are committed or retained as GitHub artifacts.

## App Store Connect records

After the Account Holder accepts the updated agreement, create two separate app records named `Click Bridge` with platform-specific SKUs:

- iOS SKU: `clickbridge-phone-20260812`
- macOS SKU: `clickbridge-macos-2026`

The records use English (U.S.) as the primary language and their existing explicit bundle IDs. No testers are added by the upload workflow; internal or external distribution is a later explicit action.

## Failure handling

- Missing agreement or app records: stop before upload and report the exact external gate.
- Missing or mismatched signing material: fail before archive creation.
- Invalid release tag or reused build number: fail before signing.
- iOS success followed by Mac failure: report partial upload and require a new build number for the next complete pair.
- Any exit path: remove installed profiles, temporary keychains, API key files, certificates, `.ipa`, and `.pkg` output.

## Verification

Repository verification must prove:

- release validators require both platform lanes and all cleanup paths;
- iOS tests pass (current baseline: 71 tests);
- macOS tests pass (current baseline: 40 tests);
- the macOS App Store archive contains the sandbox and network-client entitlements;
- both uploaded builds appear in App Store Connect with the requested version/build and a processing or valid state.
