# Release automation setup

All four release workflows are manual (`workflow_dispatch`) and check out only the event commit (`github.sha`). The required `release_tag` must match `vX.Y.Z`, must already exist, and must resolve to that exact commit. Never enter a branch or arbitrary ref.

Configure these GitHub environments with required reviewers, disallow self-review where practical, and restrict deployment tags to `v*`:

| Environment | Purpose | Required configuration |
| --- | --- | --- |
| `testflight` | Build and upload one iOS build; no tester distribution | Secrets `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`; variable `APPLE_TEAM_ID` |
| `app-store` | Select a processed build and submit it for review, with automatic release off | App Store Connect API-key secrets above |
| `macos-release` | Developer ID sign, notarize, staple, verify, and create a draft GitHub release | App Store Connect API-key secrets above; secrets `MAC_DEVELOPER_ID_CERTIFICATE_BASE64`, `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`; variable `APPLE_TEAM_ID` |
| `ghcr-private` | Build and push version plus SHA tags to GHCR | No custom secret; the job-scoped `GITHUB_TOKEN` receives only `contents: read` and `packages: write`. Before first approval, create or inspect `click-bridge-relay` and verify its visibility is **Private**. |

Store each `.p8`, `.p12`, and `.mobileprovision` file as a single-line Base64 value in its environment secret. The workflows decode them into the ephemeral runner only and remove them in an `always()` cleanup step. Do not commit or upload credentials to the repository.

The iOS and macOS workflows install XcodeGen 2.46.0 directly from the official `yonaskolb/XcodeGen` release asset and verify SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` before executing it. The macOS checksum file records only the ZIP basename, so it verifies from any download directory.

## Before dispatch

1. Replace every `REPLACE BEFORE RELEASE` value under `fastlane/metadata`, including the locale files, copyright owner, and primary category. No screenshot or reviewer-login scaffold is included.
2. Merge and verify CI, create a protected `vX.Y.Z` tag on the exact release commit, then dispatch from that tag.
3. Run TestFlight first. It uploads the IPA to App Store Connect but deliberately creates no GitHub IPA artifact and distributes to no testers.
4. After App Store Connect reports that exact version/build as processed, dispatch App Store submission. Fastlane skips binary upload, submits for review, and sets `automatic_release: false`.
5. The macOS workflow creates only a draft GitHub release and retains the notarized ZIP/checksum workflow artifact for seven days. Publishing the draft is a separate human decision.
6. The GHCR workflow never emits `latest` and never modifies package visibility. Confirm the protected-environment warning before approval. Before building, it queries GHCR and fails closed unless both the version tag and commit-SHA tag are absent, so a rerun cannot overwrite either immutable release name. Record the pushed artifact digest from the job summary; that digest is the canonical deployment identity.

The relay Dockerfile pins the official `node:24-alpine` multi-platform OCI index at `sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43`. Update the readable tag and digest together in a reviewed change; never float the base image inside an immutable release commit.

Run `bundle exec ruby .github/scripts/validate-release-workflows.rb` locally to check the pinned-action and safety contracts. Do not dispatch any release workflow as part of repository verification.
