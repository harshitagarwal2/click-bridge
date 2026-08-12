# Release metadata and credentials

These files are scaffolding only. Replace every value containing `REPLACE BEFORE RELEASE` before dispatching an App Store workflow. No screenshots, reviewer login credentials, Apple private keys, signing certificates, or provisioning profiles belong in this directory.

All lanes use App Store Connect API-key authentication. The iOS and macOS
`upload_testflight` lanes build signed artifacts, verify the resolved archive
version/build, upload without tester distribution, and leave no GitHub app
artifact. Each platform's `submit_app_store` lane selects the already processed
version/build supplied by the protected workflow, skips binary upload, submits
it for review, and disables automatic release.

Required runtime values are documented in [docs/release-automation.md](../docs/release-automation.md). Keep metadata within Apple's current character limits and review it in App Store Connect before the first submission.
