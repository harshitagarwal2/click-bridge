# Mac Settings and Remote Phone Pairing Implementation Plan

> For agentic executors: follow this plan in order with red-green TDD, one
> integration owner for shared Swift files, and fresh verification after every
> head movement.

**Goal:** Make macOS Settings apply connection changes reliably and make phone
setup easy both nearby (QR) and remotely (guarded native share link), without
exposing role tokens.

**Architecture:** A view-owned connection draft feeds one AppState apply
transaction. Pairing remains on the existing relay protocol and controller,
but all invitation exports pass through a current-state/expiry fence. A single
state-driven sheet owns invitation, same-code approval, cancellation, and
recovery. The existing revision, epoch, socket-generation, authorization-lease,
and stale-message fences remain the concurrency authority.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Core Image, Vision, XCTest, XcodeGen,
XcodeBuildMCP, macOS 14 minimum.

**Immutable planning base:** `d317a161eccbb4f15bc9bd9d36b2dba85ab8ed2d`

**Approved design:**
[`../specs/2026-08-12-mac-settings-pairing-design.md`](../specs/2026-08-12-mac-settings-pairing-design.md)

## User journey to preserve

1. The Mac owner opens **Settings…** from the menu-bar app.
2. Normal setup shows readiness and **Pair Phone** / **Replace Phone…**. It does
   not ask the phone user for a relay URL or token.
3. Click Bridge creates one opaque, single-use, five-minute HTTPS invitation.
4. If the phone is nearby, scan the large QR. If it is elsewhere, choose
   **Share Secure Setup Link…** and send the same invitation through Messages,
   Mail, or another trusted channel. The devices need not share a LAN.
5. The native `/pair` link may open the iOS app through Universal Links. The
   explicit browser fallback derives `/pair/web` from that same invitation.
6. The Mac owner approves only if both devices show the same six-digit code.
7. Advanced relay URL and `MAC_TOKEN` recovery stays in Settings behind one
   explicit **Save & Reconnect** transaction. The normal phone path never shows
   `PHONE_TOKEN` or `MAC_TOKEN`.

## Scope and ownership

The root/integration executor owns all source, generated-project, Git, PR, and
merge writes. Specialist agents remain read-only reviewers so
`AppState.swift`, `PairingController.swift`, and SwiftUI files never have
parallel writers.

In scope:

- `mac/ClickBridgeMac/ConnectionSettings.swift` (new)
- `mac/ClickBridgeMac/SettingsStore.swift`
- `mac/ClickBridgeMac/AppState.swift`
- `mac/ClickBridgeMac/PairingController.swift`
- `mac/ClickBridgeMac/QRCodeRenderer.swift`
- `mac/ClickBridgeMac/ClickBridgeApp.swift`
- `mac/ClickBridgeMac/SettingsView.swift` (new, if the view split stays useful)
- `mac/ClickBridgeMac/PairingViews.swift` (new, if the view split stays useful)
- `mac/ClickBridgeMac/SharingServiceButton.swift` (new)
- corresponding `mac/ClickBridgeMacTests/*Tests.swift`
- `mac/project.yml` and generated `mac/ClickBridgeMac.xcodeproj/project.pbxproj`
- `README.md`, `docs/install-macos.md`, and
  `mac/TestFlight/WhatToTest.en-US.txt`
- this active plan/design and `docs/superpowers/README.md`

Out of scope unless a compatibility test proves a defect:

- relay wire format or enrollment semantics;
- iOS, PWA, or relay implementation changes;
- a new invitation URL format;
- plaintext credential migration or a relay-side credential schema change;
- App Intents, Siri, widgets, controls, or token parameters;
- production deployment, live token rotation, signing, notarization, or
  TestFlight upload.

## Alternatives decided

| Decision | Selected | Rejected alternative and reason |
| --- | --- | --- |
| Settings apply | Draft → validate → atomic versioned Keychain connection record → fenced reconnect | Adding `reconnect()` to the old Save button leaves URL live-binding, cross-store crash gaps, partial persistence, and failure data loss. |
| Pairing layout | One focused, state-driven sheet | Keeping QR and approval inline/nested preserves crowding and silent sheet-dismiss denial. |
| Remote handoff | Action-time guarded native share of `/pair` | A static `ShareLink` can retain an expired/stale capability; sharing a QR image adds friction and does not improve the remote open flow. |
| Nearby handoff | Integer-rendered QR with explicit four-module quiet zone | A larger resizable SwiftUI frame alone can blur modules or omit the required border. |
| Browser fallback | Explicit guarded `/pair/web` copy | Reusing `/pair` can divert into the native app through Universal Links. |
| System integration | Existing Settings entry only | App Intents can participate in macOS Shortcuts, but this visual security workflow still requires QR/link state and same-code approval; an intent adds routing and credential-surface risk without completing setup. |

## Pre-mortem and stop gates

| Likely failure | Earliest evidence | Prevention / stop gate |
| --- | --- | --- |
| Invalid input disconnects a working Mac | close/configure count changes in a rejection test | Validate and resolve Keychain before revision or client mutation; stop if any rejection changes persistence, controller identity, socket, or revision-owned status. |
| Older Save/Clear/Reconnect wins a race | gated-transport hostile sequence opens an old token | Retain the existing credential revision and client mutation epoch; stop until every latest-operation test is deterministic. |
| A stale invitation leaves the process | copy changes pasteboard or a provider returns after claim/expiry/cancel | Resolve copy immediately and resolve sharing lazily when `NSItemProvider` is asked for data; no frozen raw URL at process boundaries. |
| Remote recipient receives instructions but no usable link | UI/share tests expose QR as the only primary path | Keep **Share Secure Setup Link…** visible beside the nearby scan path and document internet use explicitly. |
| QR looks larger but is harder to scan | output dimension not module-aligned or Vision cannot decode | Render `(symbol modules + 8) * integer scale`, test the white border, decode the final bitmap, and do not resample into a fractional frame. |
| Sheet dismissal loses cancellation ownership | an active sheet disappears before correlated `pair.failed(cancelled)` | Disable interactive dismissal during owned/mid-send states; sending cancel alone does not unblock; uncertainty remains visible and fenced. |
| Legacy migration skips destructive warning | presentation test shows label without confirmation | Let legacy say **Pair Phone**, but retain explicit warning that approval invalidates old shared phone access. |
| Settings still appears to do nothing | runtime action does not open/front one Settings window | Use `openSettings`, activate the app, and perform a launched-app window-count/focus smoke before delivery. |
| Secret appears in UI or transfer surface | changed-file scan finds role-token values/labels in URLs, copy, share, logs, or accessibility | Transfer only canonical opaque invitation URLs; fixed sanitized errors; stop on any credential-bearing payload. |
| Base or PR head moves after review | local/remote SHA mismatch | Fetch, rebase, rerun focused/full checks, and obtain fresh review before merge. |

## Task 1: Lock connection draft and persistence semantics with tests

**Files:**

- Create `mac/ClickBridgeMac/ConnectionSettings.swift`
- Create `mac/ClickBridgeMacTests/ConnectionSettingsTests.swift`
- Modify `mac/ClickBridgeMac/SettingsStore.swift`
- Modify `mac/ClickBridgeMacTests/SettingsStoreTests.swift`

### Red

Add tests for:

- trimming and accepting exact `wss://<host>/ws`;
- rejecting HTTP, missing host, wrong path, user info, query, and fragment;
- blank replacement token meaning stored-token reuse;
- lowercasing and accepting an exact 64-hex replacement token;
- rejecting nonhex or non-64-character replacement values;
- draft `hasChanges`, reset/discard, and retention after a rejected apply;
- a versioned URL+token record round trip through one Keychain item;
- a legacy UserDefaults URL plus legacy `macToken` remains readable until the
  first accepted apply migrates it;
- first accepted URL-only and replacement-token applies atomically write the
  versioned record before marking migration established;
- a corrupt versioned record fails closed without falling back to legacy;
- a revocation marker prevents restart-time resurrection after interrupted or
  failed record deletion;
- the token never enters UserDefaults and `relayURLString` cannot be assigned by
  a view.

Expected production seams:

```swift
struct ConnectionSettingsDraft: Equatable {
    let appliedRelayURLString: String
    var relayURLString: String
    var replacementMacToken: String
    var hasChanges: Bool { get }
    mutating func discardChanges()
}

enum ConnectionTokenInput: Equatable {
    case reuseStored
    case replacement(String)
}

struct ValidatedConnectionSettings: Equatable {
    let relayURL: URL
    let relayURLString: String
    let tokenInput: ConnectionTokenInput
}

enum ConnectionSettingsValidator {
    static func validate(
        relayURLString: String,
        replacementMacToken: String
    ) throws -> ValidatedConnectionSettings
}

struct StoredConnection: Codable, Equatable {
    let version: Int
    let relayURLString: String
    let macToken: String
}
```

Use fixed, sanitized `LocalizedError` copy; never interpolate token input.

### Green

- Reuse `RelayEndpoint.validated` for the authoritative URL policy.
- Make `SettingsStore.relayURLString` `@Published private(set)`.
- Add one `saveConnection(_:)` Keychain operation whose payload contains the
  validated URL and resolved token. That Security-framework write is the only
  authoritative commit point.
- Load the versioned record first; use the legacy UserDefaults URL plus legacy
  `macToken` only when no record/migration marker exists.
- After the atomic record exists, update nonauthoritative URL/migration mirrors
  and best-effort remove the legacy token. Never fall back from a malformed
  current record.
- Before credential removal, write a nonsecret fail-closed revocation marker;
  clear it only after a later full record write succeeds.
- Keep `remoteEnabled` persistence unchanged.

### Verify

Run the new validator/store test classes only. Confirm they fail before source
implementation and pass afterward.

## Task 2: Implement one transactional AppState apply/reconnect boundary

**Files:**

- Modify `mac/ClickBridgeMac/AppState.swift`
- Modify `mac/ClickBridgeMacTests/AppStateTests.swift`
- Reuse test transports and secret stores already defined in that test file.

### Red

Add deterministic tests for:

1. URL-only apply reads and reuses the stored token, persists the normalized
   URL, and opens only the new endpoint.
2. Blank token with no stored credential returns `.rejected(.missingToken)` and
   changes no persistence or runtime state.
3. URL plus valid replacement token commits one URL+token record and configures
   with only that pair.
4. Invalid URL or replacement token returns a typed rejection with zero token
   write, URL write, revision-owned status, close, new transport, or controller
   replacement.
5. Keychain read/write failures retain the prior authoritative pair, live
   transport, `PairingController` identity, and UI draft.
6. A valid persisted configuration followed by network failure stays saved and
   reports **Settings saved. Reconnecting…**, not false connection success.
7. Save → Save, Save → Clear, Clear → Save, Reconnect → Clear, delayed
   close, and stale completion allow only the latest revision to configure or
   open.
8. Manual Reconnect and Save & Reconnect reject with a visible typed result and
   zero mutation in `creating`, `invitation`, `approval`, `approving`, `denying`,
   `cancelling`, and `cancelFailed`.
9. Apply/reconnect is available after confirmed cancellation returns the
   controller to a safe state.
10. Clear remains an emergency fail-closed revoke even during pairing.
11. Simulated interruption before/after the atomic record write never makes a
    new token authoritative for the old endpoint or an old token authoritative
    for the new endpoint.

Expected result seam:

```swift
enum ConnectionActionIssue: Equatable {
    case pairingInProgress
    case invalidRelayURL
    case invalidReplacementToken
    case missingToken
    case keychainUnavailable
}

enum ConnectionActionOutcome: Equatable {
    case accepted
    case rejected(ConnectionActionIssue)
}
```

Keep the existing `Task`-returning public shape if it minimizes call-site and
race-test churn, but return `ConnectionActionOutcome` from both apply and manual
reconnect. A blocked call must reject before `beginCredentialOperation()`.

### Green

Implement this synchronous-before-Task order:

1. Check `pairing?.blocksConnectionChanges`.
2. Normalize/validate the URL and optional replacement token.
3. Resolve a blank token from the authoritative/legacy connection snapshot.
4. Atomically write one versioned Keychain record containing the validated URL
   and resolved token.
5. Update only nonauthoritative URL/migration mirrors after the record exists.
6. Claim the next credential revision.
7. Configure with the already validated URL and resolved token.
8. Only after `RelayClient.configure` accepts current ownership, install the
   new `PairingController` and call `start`.

On validation/Keychain failure, preserve the live configuration and draft. On
accepted persistence plus network unavailability, keep the new saved settings.
Refactor or remove `saveToken` so no unsafe legacy call path remains.

### Verify

Run the focused AppState class after each hostile sequence group. Record close,
transport-factory, hello-token, persistence, controller-identity, and outcome
assertions rather than relying on status text alone.

## Task 3: Fence pairing ownership and every invitation export

**Files:**

- Modify `mac/ClickBridgeMac/PairingController.swift`
- Modify `mac/ClickBridgeMacTests/PairingControllerTests.swift`

### Red

Add/extend tests for:

- `blocksConnectionChanges` across every owned state, including
  `cancelFailed`, and false in safe/terminal states;
- current native `/pair` export success;
- current browser `/pair/web` export success with the exact same reference;
- native copy, browser copy, and share resolution fail closed after expiry,
  claim, cancellation, regeneration, state replacement, and cancellation
  failure;
- a lazy share item provider created while valid returns no representation if
  expiry, claim, cancellation, or regeneration happens before a sharing service
  requests its data;
- rejected export does not clear or modify an existing pasteboard value;
- countdown zero invokes the existing `refreshExpiry` cancel/recovery path;
- sheet cancel sends `pair.cancel` but remains `.cancelling` after send success;
- only the matching `pair.failed(reason: cancelled)` acknowledgement unblocks;
- lost, delayed, disconnected, and stale cancellation acknowledgements retain
  cancellation uncertainty, visible recovery, and the connection-change fence;
- **Codes Don't Match** sends `pair.deny` for the current request/claim only.

Expected seam:

```swift
enum PairingInvitationDestination { case nativeApp, browser }

var blocksConnectionChanges: Bool { get }
var preventsInteractiveDismissal: Bool { get }

func invitationURL(
    for expected: Invitation,
    destination: PairingInvitationDestination
) -> URL?

func copyInvitation(
    _ expected: Invitation,
    destination: PairingInvitationDestination,
    to pasteboard: NSPasteboard
) -> Bool
```

### Green

- Centralize state/current-invitation/clock validation in
  `invitationURL(for:destination:)`.
- Make both pasteboard paths use it.
- Make the native share presenter register a lazy `NSItemProvider` whose URL
  and text data-representation loaders request it again when the selected
  sharing service consumes data; never pass a captured raw URL to `ShareLink`
  or `NSSharingServicePicker`.
- Keep `.cancelling` until the exact correlated cancellation acknowledgement;
  send completion alone is not terminal. Disconnect/lost acknowledgement moves
  to or preserves `cancelFailed` until fresh authenticated status reconciliation.
- Preserve all request ID, claim ID, operation epoch, and stale-message logic.

### Verify

Run all `PairingControllerTests`, including existing hostile send/cancel races.

## Task 4: Render a measurable, decodable QR

**Files:**

- Modify `mac/ClickBridgeMac/QRCodeRenderer.swift`
- Modify `mac/ClickBridgeMacTests/QRCodeRendererTests.swift`

### Red

Add tests that:

- payload remains the exact canonical native invitation and contains no role
  token;
- layout reports a four-module quiet zone on every edge;
- final bitmap side is `(symbolModules + 8) * integerScale`;
- border sample pixels are white and inner symbol contains black modules;
- invalid/fractional/nonpositive scale is rejected;
- Vision decodes the final rendered image back to the exact invitation URL;
- the production display layout is at least 280 points without fractional
  resampling.

### Green

- Generate the Core Image QR at module resolution with correction level `M`.
- Composite it over an explicit white extent enlarged by four modules per side.
- Apply one integer transform after composition.
- Materialize the final image through `CIContext.createCGImage` into a concrete
  bitmap representation, then return an `NSImage` whose logical and pixel
  dimensions preserve that exact integer layout. Use `.interpolation(.none)`
  in SwiftUI and do not force a fractional resizable frame.

### Verify

Run `QRCodeRendererTests`. A unit decode is automated evidence; physical camera
scan remains `NOT RUN` until a real iPhone observes it.

## Task 5: Build the focused Settings and pairing experience

**Files:**

- Modify `mac/ClickBridgeMac/ClickBridgeApp.swift`
- Create `mac/ClickBridgeMac/SettingsView.swift`
- Create `mac/ClickBridgeMac/PairingViews.swift`
- Create `mac/ClickBridgeMac/SharingServiceButton.swift`
- Create `mac/ClickBridgeMacTests/ConnectionPresentationTests.swift`
- Create `mac/ClickBridgeMacTests/PairingPresentationTests.swift`

Keep pure presentation types in production code so copy, actions, countdown,
and accessibility values are unit-testable without launching a real relay.

### Red

Add tests for:

- legacy status: **Pair Phone** plus explicit old-access invalidation warning
  and replacement confirmation;
- paired status: **Replace Phone…** plus current-phone replacement warning;
- connection/permission/remote-control readiness text and symbols;
- countdown at 5:00, 4:59, 0:01, and 0:00;
- native/browser client-kind labels;
- grouped visible code and digit-by-digit accessibility value;
- one primary action for every pairing state;
- sanitized error/copy/share feedback;
- every stable accessibility identifier listed in the design;
- draft clears its token only on `.accepted`, and stays intact on every
  rejection;
- native sharing asks the controller at button activation and again when its
  lazy item provider is loaded; it does not present when initially nil and does
  not return data when it becomes stale with the picker already open.

### Green: Settings

- Replace `SettingsLink` conditional code with a macOS 14 `Button` using
  `@Environment(\.openSettings)`, followed by app activation from that explicit
  user action.
- Use a scrollable approximately 600-by-560 Settings window.
- Show relay, Accessibility, and Remote Control readiness first.
- Keep remote control as the existing independent security gate.
- Explain that phone setup requires no phone token.
- Put connection recovery behind **Advanced Connection** with view-owned URL
  and secure token drafts, **Save & Reconnect**, **Discard Changes**, and a
  separately confirmed **Remove Saved Credential…**.
- Show fixed inline errors; preserve drafts on rejection.

### Green: pairing sheet

- Present one approximately 700-by-600 state-driven sheet.
- Nearby section: large integer-rendered QR and scan instruction.
- Remote section: **Share Secure Setup Link…** as the primary remote action,
  with explicit internet/trusted-channel copy.
- Other ways menu: guarded native-link copy and browser/PWA-link copy.
- Visible single-use countdown and explicit cancel.
- Replace QR content in the same sheet with client kind, grouped code,
  **Codes Match — Approve**, and **Codes Don't Match**.
- Prevent interactive dismissal during mid-send/owned/cancel-uncertain states.
- On explicit close while an invitation is active, execute cancellation; keep
  the recovery sheet visible if cancellation fails.
- Terminal states explain next readiness gates and offer deterministic recovery.

### Green: native share presenter

Use a SwiftUI/AppKit bridge around `NSSharingServicePicker` and a lazy
`NSItemProvider`. On click:

1. Request the current URL from the controller closure.
2. If nil, show sanitized expired/stale feedback and do not present.
3. If present, create an item provider that advertises URL/plain-text types but
   calls the controller resolver when each representation is actually loaded.
4. Create/show the native picker with that provider, anchored to the button.
5. Keep the picker, provider, and delegate alive for the presentation lifetime.
6. If state changes before data loading, complete with a sanitized unavailable
   error and no URL.

Share only the URL and a generic label such as “Click Bridge pairing
invitation”; do not request or echo preview content containing the reference.

### Verify

Run presentation tests, then a Debug build. Inspect standard and large text,
keyboard focus, Return/Escape behavior, labels/identifiers, invitation →
approval transition, cancellation recovery, and the native share picker.

## Task 6: Regenerate the project and update the setup contract

**Files:**

- Modify `mac/project.yml` only if a target setting is actually required.
- Regenerate `mac/ClickBridgeMac.xcodeproj/project.pbxproj`.
- Modify `README.md`.
- Modify `docs/install-macos.md`.
- Modify `mac/TestFlight/WhatToTest.en-US.txt`.
- Modify `docs/superpowers/README.md` while the plan is active.

### Steps

1. Run `cd mac && xcodegen generate` immediately after every patch that adds a
   new source or test file, before attempting its red test.
2. Inspect generated membership for every new source/test file and verify that
   generation is deterministic on a second run.
3. Change **Settings → Save** to **Save & Reconnect**.
4. Document the nearby QR and remote **Share Secure Setup Link…** paths.
5. State that shared links work over the internet, are single-use, expire in
   five minutes, and still require the Mac owner to compare/approve the code.
6. Keep `/pair/web` as the explicit browser fallback and preserve the warning
   that role tokens never belong in a URL, log, screenshot, or Git.
7. Add this plan/design to the active planning index.

### Verify

- Search for obsolete action labels (`Settings → Save`, `Copy Invitation`,
  generic `Approve`/`Deny`) and update only user-facing stale references.
- Search changed UI/docs for `MAC_TOKEN`/`PHONE_TOKEN`; appearances may only be
  explicit warnings or advanced operator recovery text, never values or normal
  pairing instructions.

## Task 7: Full verification, review, cleanup, and delivery

### Exact local commands

Use the isolated paths verbatim:

```bash
(cd /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/mac && xcodegen generate)
rtk xcodebuild \
  -project /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/mac/ClickBridgeMac.xcodeproj \
  -scheme ClickBridgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/.derived-data-mac-settings-pairing \
  -only-testing:ClickBridgeMacTests/ConnectionSettingsTests test
rtk xcodebuildmcp --style minimal macos test \
  --project-path /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --derived-data-path /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/.derived-data-mac-settings-pairing \
  --progress false --output text
rtk xcodebuildmcp --style minimal macos build \
  --project-path /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/mac/ClickBridgeMac.xcodeproj \
  --scheme ClickBridgeMac \
  --derived-data-path /Users/harshitagarwal/projects/clicker-bridge-settings-pairing-20260812/.derived-data-mac-settings-pairing \
  --progress false --output text
```

Change only the `-only-testing:` class for the other focused red/green runs.
The focused command above was exercised directly; XcodeBuildMCP remains the
verified full-suite/build surface because its extra-argument array currently
hits an internal tool error for filtered tests in this workspace.

### Automated verification

From the isolated worktree, using worktree-local DerivedData:

1. Regenerate XcodeGen twice and require a clean second diff.
2. Run focused macOS test classes for connection, AppState, pairing,
   presentation, QR, and SettingsStore.
3. Run the full `ClickBridgeMac` macOS XCTest suite.
4. Build Debug with XcodeBuildMCP.
5. Run `git diff --check` and inspect the complete diff/stat.
6. Scan changed app/UI/docs for raw-token exposure and debug logging.
7. Launch the unsigned Debug app and verify the Settings action opens/fronts a
   single Settings window; exercise the layout and share picker without
   exporting an expired invitation.

The mandatory app-smoke assertions are: target the launched Debug executable
by exact path/PID; invoke **Settings…**; within five seconds observe exactly one
Settings window and frontmost application state; invoke **Settings…** again;
observe the same window identity and a count of one. Capture an AX/UI snapshot
showing the expected connection-field/action identifiers. For sharing, use a
synthetic current invitation/provider harness: open the picker, invalidate the
controller state, request the provider representation, and assert no URL/data
is returned. If local Accessibility automation cannot observe these assertions,
record them as an explicit verification gap rather than a pass.

### Independent gates

1. Run the mandatory changed-files-only anti-slop cleanup. Only behavior-neutral
   simplifications are allowed; report `no changes` if none are safe.
2. Rerun every affected focused test plus the full macOS suite after cleanup.
3. Commit the coherent tracked result to create an immutable review SHA.
4. Request code and architect review against that exact commit and this plan.
5. Any review fix, cleanup, generated-project change, amendment, or rebase
   creates a new SHA and requires fresh focused/full verification plus review.
6. Read back Ralph state, current goal, Git status, and the immutable head.

### Git delivery

1. Fetch `origin`; if `origin/main` moved, rebase and repeat focused/full tests
   plus fresh review.
2. Ensure the committed review SHA is still the current head of
   `codex/fix-mac-settings-pairing`; otherwise repeat verification/review.
3. Push the branch and create a ready PR with test evidence and explicit
   `NOT RUN` gates.
4. Wait for required checks and review the exact PR head.
5. Merge only if the PR head still equals the verified local head and required
   checks pass.
6. Pull/verify `origin/main`, confirm it contains the feature commit, and record
   the exact merged SHA.
7. Mark the goal complete, record final token usage if returned, mark Ralph
   complete, run completion audit readback, and cancel Ralph runtime state.

## Verification matrix

| Claim | Required evidence | Owner |
| --- | --- | --- |
| Settings changes apply once | validator/store tests plus AppState URL-only/replacement integration tests | integration executor |
| Rejections preserve the old connection | close/configure/factory/revision/controller-identity assertions | integration executor |
| Credential races remain fail-closed | existing and new gated hostile sequence tests | integration executor |
| Remote setup link is usable and safe | controller export tests, native picker seam test, runtime picker smoke | integration executor |
| QR is standards-shaped | module/border/dimension tests plus Vision decode | integration executor |
| Pairing sheet is state-safe | presentation/controller tests plus runtime dismissal/cancel smoke | integration executor |
| Legacy and paired flows are honest | pure presentation tests | integration executor |
| Settings opens/fronts one window | launched-app UI/window-count smoke | integration executor |
| Project contains all new files | deterministic XcodeGen and pbxproj membership inspection | integration executor |
| No token exposure | payload assertions plus changed-file secret scan | integration executor + reviewer |
| No regression | full macOS XCTest and Debug build | integration executor |
| Merge is exact | local/remote SHA, PR head, checks, merged main ancestry | integration executor |

## Explicit evidence limits

Unit tests, Vision decoding, and a local Mac runtime smoke do not prove a real
person completed pairing over the public relay. Physical iPhone camera scan,
public-relay enrollment, spoken VoiceOver output, Accessibility-authorized
click delivery, Octo observation, signing, notarization, TestFlight, and
production remain **NOT RUN** unless directly observed and recorded.
