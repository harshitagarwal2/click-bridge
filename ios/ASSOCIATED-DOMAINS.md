# Associated Domains device gate

The iOS claimant is compiled for `clickbridge-sjc.duckdns.org`, and the checked-in entitlement intentionally contains `applinks:clickbridge-sjc.duckdns.org`.

As of August 12, 2026, the automatic signing profile for `com.clickbridge.phone` does not include Associated Domains. Device installation and Universal Link runtime verification therefore require enabling the Associated Domains capability for that App ID in Apple Developer and regenerating the provisioning profile. Unsigned generic-device builds verify compilation only; they do not clear this external runtime gate.

Other relay hosts require Advanced Legacy manual setup or a rebuild whose deployment host, entitlement, and relay `apple-app-site-association` file are changed together.
