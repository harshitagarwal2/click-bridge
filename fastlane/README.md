# Release metadata and credentials

These files are scaffolding only. Replace every value containing `REPLACE BEFORE RELEASE` before dispatching an App Store workflow. No screenshots, reviewer login credentials, Apple private keys, signing certificates, or provisioning profiles belong in this directory.

The two iOS lanes use App Store Connect API-key authentication. `ios upload_testflight` builds a signed IPA, uploads it to TestFlight, does not distribute it to testers, and leaves no GitHub artifact. `ios submit_app_store` selects the already processed version/build supplied by the protected workflow, skips binary upload, submits it for review, and disables automatic release.

Required runtime values are documented in [docs/release-automation.md](../docs/release-automation.md). Keep metadata within Apple's current character limits and review it in App Store Connect before the first submission.
