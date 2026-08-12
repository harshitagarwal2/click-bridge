# Associated Domains device gate

The iOS claimant is compiled for `clickbridge-sjc.duckdns.org`, and the checked-in entitlement intentionally contains `applinks:clickbridge-sjc.duckdns.org`.

**Resolved August 12, 2026.** The Associated Domains capability is now enabled for `com.clickbridge.phone` in Apple Developer, and Xcode regenerated the automatic signing profile to include it. Verified by a successful signed `Release` build for `generic/platform=iOS`, which previously failed because the provisioning profile did not include the Associated Domains capability.

That build now succeeds. This clears the **signing** gate only—it is a prerequisite for installing on a physical device, not evidence that Universal Link handoff or any other physical-device behavior works. See `docs/ios-acceptance.md`: the physical iPhone acceptance checklist is still entirely `NOT RUN`, and nothing in this update constitutes progress against it.

Other relay hosts require Advanced Legacy manual setup or a rebuild whose deployment host, entitlement, and relay `apple-app-site-association` file are changed together.
