# Release automation setup

All four release workflows are manual (`workflow_dispatch`) and check out only
the event commit (`github.sha`). The required `release_tag` must match the
shared `MARKETING_VERSION` as `vX.Y` or `vX.Y.Z`, must already exist, and must
resolve to that exact commit. Never enter a branch or arbitrary ref.

## Version ownership

`Config/Version.xcconfig` owns the default marketing version and build for both
Apple apps. The iOS and macOS base configurations include it after optional
local signing overrides, so developer-team and profile settings cannot become
hidden version owners. For the current App Store records it resolves to
`1.0 (1)`.

For a new customer release, update both values in that one file, run the Apple
project generation/tests, merge the change, and tag the exact merge commit with
the matching `v`-prefixed marketing version. TestFlight accepts one explicit
Apple build string (one to three numeric components) for both apps. Use the
shared baseline for the first upload and never reuse a build that either App
Store Connect record may have accepted. A recovery upload may select a higher
build without changing the customer-facing version.

Concrete recovery example: if iOS `1.0 (1)` is accepted but the matching Mac
upload has not happened, do not try to reuse `1`. Dispatch TestFlight with
build `2`; both lanes build and upload `1.0 (2)`, restoring an aligned pair.
The shared baseline may remain `1.0 (1)` until the next normal release bump;
the explicit workflow build is an intentional per-upload override and never
rewrites the generated projects.

The TestFlight lanes pass the selected values as Xcode build settings and then
read each `.xcarchive` metadata plist before uploading; a mislabeled archive
fails locally. App Store submission takes the exact processed TestFlight build
and submits both platform records. The notarized Mac workflow uses the shared
baseline values and checks the built app's Info.plist before notarization.

## Current external blocker

Do **not** dispatch the release workflows yet. As verified on 2026-08-12, this
repository is public and has a `production` environment, but none of the four
release environments below exists. A missing environment can otherwise be
created automatically without protection, so each workflow first runs a
separate read-only job with no `environment:` declaration. That preflight uses
the documented Get Environment API and fails closed unless the environment
already has at least one required reviewer and prevents self-review. The
mutating job depends on that preflight, declares the environment only
afterward, and repeats the exact guard as its first step so a job-specific rerun
cannot reuse stale approval configuration.

Create and protect all four release environments before enabling releases. The
rendered REST reference does not currently list `can_admins_bypass`, but
GitHub's live authenticated Get Environment response includes it. The preflight
therefore requires an exact `false` and deliberately fails if the field is true,
null, or absent; still verify the setting in GitHub's environment UI during
setup. Until then, all four release workflows are intentionally non-runnable.

Configure these GitHub environments with required reviewers, require prevention of self-review, disable administrator bypass, and restrict deployment tags to `v*`:

| Environment | Purpose | Required configuration |
| --- | --- | --- |
| `testflight` | Build and upload aligned iOS and macOS builds; no tester distribution | Secrets `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `MAC_DISTRIBUTION_CERTIFICATE_BASE64`, `MAC_DISTRIBUTION_CERTIFICATE_PASSWORD`, `MAC_INSTALLER_CERTIFICATE_BASE64`, `MAC_INSTALLER_CERTIFICATE_PASSWORD`, `MAC_PROVISIONING_PROFILE_BASE64`; variable `APPLE_TEAM_ID` |
| `app-store` | Select processed iOS and macOS builds and submit both for review, with automatic release off | App Store Connect API-key secrets above |
| `macos-release` | Developer ID sign, notarize, staple, verify, and create a draft GitHub release | App Store Connect API-key secrets above; secrets `MAC_DEVELOPER_ID_CERTIFICATE_BASE64`, `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`; variable `APPLE_TEAM_ID` |
| `ghcr-private` | Build and push version plus SHA tags to GHCR | No custom secret; the job-scoped `GITHUB_TOKEN` receives `actions: read`, `contents: read`, and `packages: write`. Before first approval, create or inspect `click-bridge-relay` and verify its visibility is **Private**. |

After the protected environments are created and configured, set the
`APPLE_TEAM_ID` environment variable for `testflight` and `macos-release` to
`EC3R6XQ226`. This Team ID is not a credential. Do not store the Apple account
email, Developer ID record, certificates, profiles, or API private key as
variables or repository files.

Store each `.p8`, `.p12`, `.mobileprovision`, and `.provisionprofile` file as a single-line Base64 value in its environment secret. The workflows decode them into the ephemeral runner only and remove them in an `always()` cleanup step. Do not commit or upload credentials to the repository. The TestFlight workflow separately downloads Apple's public WWDR G3 intermediate from Apple PKI, verifies its pinned SHA-256 and Apple Root trust chain, imports it only into the disposable signing keychain, and removes it during cleanup. This keeps Apple Distribution and Mac Installer Distribution chain building deterministic without changing certificate trust settings.

## Apple prerequisites

The Apple Account Holder must accept the current Apple Developer Program License Agreement before App Store Connect will allow new app records or uploads. The Admin role cannot accept that agreement on the Account Holder's behalf.

Create and verify two App Store Connect records before the first upload:

| Platform | Name | Bundle ID | SKU | Primary language |
| --- | --- | --- | --- | --- |
| iOS | Click Bridge | `com.clickbridge.phone` | `clickbridge-phone-20260812` | English (U.S.) |
| macOS | Click Bridge | `com.clickbridge.mac` | `clickbridge-macos-2026` | English (U.S.) |

The macOS App Store provisioning profile must include the App Sandbox entitlement for `com.clickbridge.mac`. The TestFlight lane adds `ClickBridgeMac-AppStore.entitlements` only through command-line Release overrides; the existing Developer ID/notarized macOS workflow remains unsandboxed.

The iOS and macOS workflows install XcodeGen 2.46.0 directly from the official `yonaskolb/XcodeGen` release asset and verify SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` before executing it. The macOS checksum file records only the ZIP basename, so it verifies from any download directory.

## Before dispatch

1. Replace every `REPLACE BEFORE RELEASE` value under `fastlane/metadata`, including the locale files, copyright owner, and primary category. No screenshot or reviewer-login scaffold is included.
2. Update `Config/Version.xcconfig`, merge and verify CI, create the matching protected `vX.Y` or `vX.Y.Z` tag on the exact release commit, then dispatch from that tag.
3. Run TestFlight first. Enter one new build string for both records. It uploads the iOS IPA and then the macOS installer package with the same version/build, creates no GitHub app artifact, and distributes to no testers. The uploads are sequential, not transactional: if one succeeds and the other fails, fix the failure and dispatch a new higher build number instead of reusing the partially uploaded value.
4. After both App Store Connect records report that exact version/build as processed, dispatch App Store submission with the same values. Fastlane skips binary upload, submits both apps for review, and sets `automatic_release: false`.
5. The macOS workflow creates only a draft GitHub release and retains the notarized ZIP/checksum plus the notary submission result and JSON log for seven days. The notary audit artifact runs even after failure when either audit file exists. Publishing the draft is a separate human decision.
6. The GHCR workflow never emits `latest` and never modifies package visibility. Confirm the protected-environment warning before approval. Before building, it queries GHCR and fails closed unless both the version tag and commit-SHA tag are absent; immediately after pushing, it verifies that both names resolve to the action's digest. Treat the pushed artifact digest from the job summary as the canonical deployment identity: GHCR tags are mutable registry pointers, and these checks cannot prevent a different authorized writer from changing them later.

The relay Dockerfile and deployment verifier containers pin the official `node:24-alpine` multi-platform OCI index at `sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43`. The OCI Compose stack likewise pins `caddy:2-alpine` at `sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648`. Update each readable tag and digest together in a reviewed change; never float deployment images inside an immutable release commit.

Run `bundle exec ruby .github/scripts/validate-release-workflows.rb` locally to check the pinned-action and safety contracts. Do not dispatch any release workflow as part of repository verification.
