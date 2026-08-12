# Xcode Cloud runbook

Xcode Cloud should own iOS pull-request validation and the eventual TestFlight
archive. GitHub Actions remains the cross-platform owner for the relay, PWA,
container, macOS client, and repository contract checks.

## Verified account and repository state

Verified on 2026-08-12:

- App Store Connect contains Click Bridge app `6800644446`, version `1.0`, in
  **Prepare for Submission**.
- Xcode Cloud shows `0m` used and `25h 0m` available; no build has run in the
  last 30 days.
- The personal **Source Control Accounts** section does not show a connected
  provider. The team integration page has no on-premise providers, which is
  expected for GitHub.com.
- The private GitHub repository is on a plan that returns HTTP 403 for branch
  protection and repository rulesets. Xcode Cloud can report a check, but that
  check cannot be made a required merge gate until the plan changes or the
  repository becomes public. Keep the repository private unless there is a
  separate reason to change its visibility.
- `ios/project.yml`, `ios/ClickBridgePhone.xcodeproj`, and the shared
  `ClickBridgePhone` scheme are committed. The post-clone hook regenerates the
  project with the repository-pinned XcodeGen release before every Cloud build.
- The project has no third-party Swift package dependency, so there is no
  `Package.resolved` or dependency credential to configure.

## First connection

Apple requires the first Xcode Cloud workflow to be created from Xcode. Use
Xcode 15 or later and an Apple Account with access to the Click Bridge App Store
Connect record.

1. Open `ios/ClickBridgePhone.xcodeproj`, select the `ClickBridgePhone` shared
   scheme, and confirm the app uses automatic signing for team `EC3R6XQ226`.
2. Choose **Product > Xcode Cloud > Create Workflow** and select the existing
   Click Bridge App Store Connect record.
3. When Xcode asks for source access, authorize the Xcode Cloud GitHub app for
   `harshitagarwal2/click-bridge`. A GitHub owner must approve the installation
   if GitHub requests it.
4. Select the project at `ios/ClickBridgePhone.xcodeproj`. Xcode Cloud discovers
   `ios/ci_scripts/ci_post_clone.sh` beside that project and runs it after the
   repository clone.
5. Run the first workflow before relying on its GitHub status. Do not add a
   required status check until GitHub has received that exact check at least
   once and the repository plan supports rulesets.

The hook downloads XcodeGen only when the build image does not already contain
exactly version `2.46.0`. It verifies SHA-256
`4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`
before executing the official release asset. It does not read or print secrets.

## Recommended workflows

| Workflow | Start condition | Actions | Delivery and policy |
|---|---|---|---|
| `PR - iOS checks` | Pull-request changes targeting `main`; include `ios/**` and `contracts/fixtures/**` | Test the `ClickBridgePhone` scheme on one current iPhone simulator | No distribution. Notify the committer on failure. Keep clean builds off to conserve the 25-hour allowance. |
| `Weekly - iOS confidence` | Weekly schedule and manual start | Analyze, then test with code coverage on one current iPhone simulator | No distribution. Add another device or OS only after usage data shows enough headroom. Notify on failure. |
| `Release - TestFlight` | Git tag matching `v*` and manual start | Clean Archive of `ClickBridgePhone` | Distribute to an internal Click Bridge TestFlight group. Restrict workflow editing to the smallest release-admin set and notify on success or failure. |

Pin each workflow to a tested Xcode/macOS version alias. Review the alias before
Apple retires an image; do not silently follow the newest image during a release.

## Version and TestFlight ownership

`Config/Version.xcconfig` owns the default marketing version and baseline build
for both Apple apps. Update it once before creating the matching `vX.Y` or
`vX.Y.Z` release tag. The generated Info.plist reads
`$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

Xcode Cloud supplies its own increasing build number at higher build-setting
precedence, so Cloud archives retain the shared marketing version while using
the Cloud build identity. Record that processed build when dispatching App
Store submission. The GitHub TestFlight fallback instead takes an explicit new
build string and verifies each archive before upload.

`ios/TestFlight/WhatToTest.en-US.txt` supplies the internal tester notes. Keep
the filename and locale next to the selected Xcode project.

The existing `.github/workflows/testflight.yml` is a manual, protected fallback
that uploads with Fastlane and manually managed signing material. Xcode Cloud
uses Apple-managed signing and avoids storing the distribution certificate,
provisioning profile, and App Store Connect private key in GitHub.

**Do not enable both TestFlight upload paths for the same release tag.** After
the Xcode Cloud release workflow succeeds, treat Xcode Cloud as the iOS upload
owner and leave the GitHub TestFlight workflow undispatched. Keep GitHub Actions
for App Store metadata submission only until that responsibility is explicitly
migrated.

## Secrets, signing, and notifications

- Keep automatic signing enabled. Do not add a certificate, provisioning
  profile, `.p8`, or Apple password to this repository.
- If a later build script needs a token, add it as a redacted Xcode Cloud
  environment variable and limit who can edit it. Never echo it from a script.
- Connect personal email notifications for failed builds. Add Slack only if the
  workspace is already approved for build metadata; use separate PR and release
  destinations to avoid noise.
- Xcode Cloud build artifacts and logs are retained for a limited period. Keep
  durable release artifacts in App Store Connect and retain any required dSYM
  outside the Cloud retention window.

## Rollout and recovery

1. Create and run `PR - iOS checks` on a small test pull request.
2. Confirm the GitHub commit shows the Xcode Cloud check and inspect the Cloud
   log for the XcodeGen version and checksum success.
3. Run `Weekly - iOS confidence` manually once, then enable its schedule.
4. Create an internal TestFlight group, bump the shared marketing version, and run
   `Release - TestFlight` manually before enabling the `v*` trigger.
5. If the post-clone hook fails, reproduce with
   `ios/ci_scripts/ci_post_clone.sh` from a clean checkout. If an Xcode image
   change fails a build, restore the last tested version alias and investigate
   before moving the alias.

Official references:

- [Set up a project for Xcode Cloud](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud)
- [Develop a workflow strategy](https://developer.apple.com/documentation/xcode/developing-a-workflow-strategy-for-xcode-cloud)
- [Write custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Configure pull-request merge requirements](https://developer.apple.com/documentation/xcode/configuring-requirements-for-merging-a-pull-request)
- [Distribute Xcode Cloud builds through TestFlight](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
- [Set the next Xcode Cloud build number](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- [GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
