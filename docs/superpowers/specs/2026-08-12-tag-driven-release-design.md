# Tag-driven release design

## Goal

Start the non-review release lanes automatically from the immutable tag that
matches the shared version, while keeping App Store review submission manual.

## Trigger and version source

`testflight.yml`, `ghcr-relay.yml`, and `macos-notarized-release.yml` will run
on pushes of `v*` tags. Each checks out the tagged commit, derives the release
tag from `github.ref_name`, and reads `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` through `.github/scripts/read-apple-version.sh`.
The existing exact-tag/SHA, main-reachability, and successful-CI checks remain
in place.

Manual dispatch remains available as a recovery path. Its inputs stay
compatible, but the workflow resolves the tag and build number from the same
shared version source when invoked from a tag-triggered run.

## Distribution boundary

App Store submission remains `workflow_dispatch` only. It requires processed
TestFlight builds and sends both apps to App Review; starting it at tag push
would race App Store Connect processing and remove the deliberate review
decision. Its manual inputs will be retained.

## Verification

The release workflow validator will require automatic tag triggers and
tag-derived version/build variables for the three automatic lanes, while
requiring App Store submission to remain manual. Workflow contract tests will
exercise the updated requirements.
