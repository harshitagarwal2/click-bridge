# Release automation setup

All four release workflows are manual (`workflow_dispatch`) and check out only
the event commit (`github.sha`). The required `release_tag` must match the
shared `MARKETING_VERSION` as `vX.Y` or `vX.Y.Z`, must already exist, and must
resolve to that exact commit. Never enter a branch or arbitrary ref.

## Distribution ownership

Each product has one distribution surface. Do not duplicate Apple or web
artifacts merely to populate GitHub's repository sidebar.

| Product | Distribution surface | Published artifact |
| --- | --- | --- |
| macOS menu-bar receiver | GitHub Releases | Developer ID-signed, notarized, stapled, attested ZIP plus SHA-256 checksum and generated release notes |
| Relay and bundled PWA | Private GitHub Container Registry package | Repository-linked `linux/amd64` and `linux/arm64` OCI image, version and commit tags, BuildKit provenance/SBOM, and GitHub provenance attestation |
| Native iOS app | TestFlight and App Store Connect | Signed IPA uploaded by Fastlane; never a GitHub release asset |
| Mac App Store build | TestFlight and App Store Connect | Sandboxed installer package uploaded by Fastlane; distinct from the unsandboxed notarized ZIP |
| OCI production deployment | Protected `production` environment | Exact verified Git commit transferred to the VM and built locally; it does not pull the GHCR package |

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

## Current external gates

As verified on 2026-08-12, `ghcr-private`, `macos-release`, `testflight`,
`app-store`, and `production` exist. Each requires independent approval from
`pulkitcs18`, prevents self-review, disables administrator bypass, and uses a
custom deployment policy: release environments accept only `v*` tags and
production accepts only `main`. Immutable Releases are enabled, and the active
`Protect immutable release tags` ruleset rejects updates and deletions under
`refs/tags/v*`.

The release workflows still perform their own preflight before entering an
environment. A missing environment can otherwise be created automatically
without protection, so the preflight uses the authenticated Get Environment API
and fails closed unless the named environment has required reviewers, prevented
self-review, and `can_admins_bypass == false`. The mutating job repeats the same
guard as its first step so a job-specific rerun cannot reuse stale approval
configuration. After checkout, every publication lane also fails closed unless
the tag resolves to the dispatched SHA, that SHA is reachable from `origin/main`,
and an exact-SHA `push` run of `CI` on `main` completed successfully.

Do **not** dispatch the Apple workflows until their secrets, App Store Connect
records, metadata, agreements, and physical acceptance evidence below are
complete. `ghcr-private` needs no custom secret, but its multi-architecture
workflow must first be merged and pass CI on the exact commit that will be
tagged.

Configure these GitHub environments with required reviewers, require prevention of self-review, disable administrator bypass, and restrict deployment tags to `v*`:

| Environment | Purpose | Required configuration |
| --- | --- | --- |
| `testflight` | Build and upload aligned iOS and macOS builds; no tester distribution | Secrets `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `MAC_DISTRIBUTION_CERTIFICATE_BASE64`, `MAC_DISTRIBUTION_CERTIFICATE_PASSWORD`, `MAC_INSTALLER_CERTIFICATE_BASE64`, `MAC_INSTALLER_CERTIFICATE_PASSWORD`, `MAC_PROVISIONING_PROFILE_BASE64`; variable `APPLE_TEAM_ID` |
| `app-store` | Select processed iOS and macOS builds and submit both for review, with automatic release off | App Store Connect API-key secrets above |
| `macos-release` | Developer ID sign, notarize, staple, verify, and create a draft GitHub release | App Store Connect API-key secrets above; secrets `MAC_DEVELOPER_ID_CERTIFICATE_BASE64`, `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`; variable `APPLE_TEAM_ID` |
| `ghcr-private` | Build and push version plus SHA tags to GHCR | No custom secret; the job-scoped `GITHUB_TOKEN` receives narrowly scoped package and attestation permissions. Before first approval, create or inspect `click-bridge-relay` and verify its visibility is **Private**. |

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
5. Run and record the applicable physical matrix before publishing a user-facing release. Automated CI, Simulator, unsigned device builds, TestFlight processing, and notarization do not replace the real iPhone, Accessibility, haptic, headset, and Octo observations in `physical-smoke-test.md`.
6. The GHCR workflow never emits `latest` and never modifies package visibility. It installs a digest-pinned Arm64 QEMU emulator, publishes exactly `linux/amd64` and `linux/arm64`, and adds source/title/description metadata to both platform manifests and the image index so GitHub links the package to this repository. Before building, it queries GHCR and fails closed unless both the version tag and commit-SHA tag are absent. After pushing, it creates a GitHub provenance attestation for the exact image digest and verifies both tag names resolve to that digest.
7. The macOS workflow creates only a draft GitHub release. It attests the final notarized ZIP, uploads the ZIP/checksum, prepends the notarization notice to generated release notes, and retains the notary result/log and verified assets for seven days. Review the draft, checksum, generated notes, attestation, and physical evidence before the separate publish decision. Immutability begins only when the draft is published.

Treat the pushed GHCR digest from the job summary as the canonical package
identity: tags are registry pointers even though this workflow refuses to
overwrite them. A failure after the image push is not safely rerunnable under
the same version because the tags now exist; diagnose it and release a new
version instead of deleting or overwriting evidence. The current OCI production
workflow deliberately remains source-transfer plus local build, so GHCR
publication does not by itself prove or change the live VM.

Verify the published provenance with the digest recorded by the workflow:

```bash
printf '%s' "$CR_PAT" | docker login ghcr.io -u harshitagarwal2 --password-stdin
gh attestation verify \
  "oci://ghcr.io/harshitagarwal2/click-bridge-relay@sha256:ACTUAL_DIGEST" \
  --repo harshitagarwal2/click-bridge
```

`CR_PAT` must be a classic personal access token with `read:packages`; do not
store it in the repository or paste it into shell history.

The relay Dockerfile and deployment verifier containers pin the official `node:24-alpine` multi-platform OCI index at `sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43`. The OCI Compose stack likewise pins `caddy:2-alpine` at `sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648`. Update each readable tag and digest together in a reviewed change; never float deployment images inside an immutable release commit.

Run `bundle exec ruby .github/scripts/validate-release-workflows.rb` locally to check the pinned-action and safety contracts. Do not dispatch any release workflow as part of repository verification.
