# Mac Settings and Phone Pairing Design

## Summary

Click Bridge will replace its current mixed live-edit/deferred-save Settings
behavior with one explicit draft-to-apply connection transaction. The normal
Settings experience will show the Mac's connection, Accessibility, and remote
control readiness; the advanced connection fields will apply only through
**Save & Reconnect**. Phone enrollment will move into one focused sheet that
supports two equally clear situations: scan a large QR when the phone is
nearby, or use **Share Secure Setup Link…** when the phone user is elsewhere on
the internet. Both paths progress to explicit same-code approval on the Mac.

This design intentionally does not add App Intents. Pairing cannot complete
outside the app because the person must scan or share a single-use invitation
and compare a six-digit code. Apple also documents that App Shortcuts are not
supported on macOS; exposing connection fields as intent parameters would make
the setup less secure without shortening it.

## Evidence and problem statement

The current UI has two sources of truth:

- The relay URL field writes directly to
  `SettingsStore.relayURLString`, which persists every keystroke to
  UserDefaults.
- The only Save button invokes `AppState.saveToken` and is disabled unless a
  fresh 64-character token is present.
- Reconfiguring `RelayClient` happens only through token save or the separate
  menu-bar Reconnect action.

A URL-only edit therefore looks saved but never affects the live connection.
An invalid URL can also be persisted before validation, and the token draft is
cleared before Keychain save and reconnect outcomes are known.

The phone flow is secure at the protocol boundary, but its presentation is
crowded: a 208-point QR code and four equal-weight actions share a fixed
460-point Settings window, invitation expiry is invisible, and approval uses
generic Approve/Deny labels instead of asking whether the two codes match.

The existing protocol intentionally reports two enrollment states:

- `legacy`, credential version 0: the shared bootstrap phone credential is
  still active and the first secure pairing migrates away from it.
- `paired`, credential version greater than 0: a previously paired phone is
  active and will be replaced.

Both states require an explicit confirmation before creating a new invitation,
but they require different user-facing copy.

## Goals

- Make every accepted Settings change have one visible, testable runtime
  effect.
- Let a URL-only change reuse the existing Keychain token.
- Validate the whole connection draft before mutating persistence or runtime
  state.
- Keep the previous saved/live connection authoritative when validation or a
  Keychain write fails.
- Preserve the existing credential revision, socket-generation, authorization
  lease, and stale-status fences.
- Prevent connection replacement during a live pairing transaction unless the
  pairing is first cancelled successfully.
- Make QR scanning the obvious nearby-phone path and a guarded native share
  sheet the obvious remote-phone path, while retaining copy and PWA fallbacks.
- Make code comparison, expiry, recovery, and post-pairing readiness explicit.
- Preserve role-token secrecy in UI, accessibility, clipboard, logs, URLs, and
  system integration.

## Non-goals

- No relay wire-format or enrollment-state changes.
- No plaintext credential migration and no relay-side credential-format change.
- No App Intents, App Shortcuts provider, widgets, controls, or Siri surface.
- No automatic Accessibility permission grant.
- No production deployment, token rotation, signing, notarization, TestFlight,
  or physical-device claim from local automated evidence.

## Connection architecture

### Draft ownership

`SettingsView` owns a `ConnectionSettingsDraft` containing:

- the last applied relay URL;
- the editable relay URL;
- an optional replacement Mac token.

The draft never writes UserDefaults or Keychain. A blank replacement token
means “reuse the stored Keychain token.” The replacement token stays only in
the `SecureField` state, is retained on every rejected apply, and is cleared
only after persistence and runtime reconfiguration are accepted.

`SettingsStore.relayURLString` becomes read-only outside the store. A named
atomic connection-record write is the only persistence mutation so views
cannot bypass the apply boundary.

### Authoritative connection record and migration

Relay URL and Mac credential become one versioned Keychain value, for example
`StoredConnection(version: 1, relayURLString: ..., macToken: ...)`. The single
Security-framework update/insert is the authoritative configuration commit.
UserDefaults may mirror the URL for compatibility and display, but the mirror
is never paired with a separately loaded token after the new record exists.

Migration is lazy and fail-closed:

- If a valid versioned record exists, it is authoritative.
- Otherwise, when no migration marker exists, the current UserDefaults URL and
  legacy `macToken` Keychain item remain a readable legacy snapshot.
- The first accepted Save & Reconnect (including a URL-only apply) resolves
  that legacy token, validates the complete pair, writes the versioned record
  atomically, then marks migration established and best-effort removes the
  legacy item.
- A malformed versioned record never falls back to a legacy credential.
- Remove Saved Credential writes a nonsecret fail-closed revocation marker
  before deleting current and legacy records. A later accepted atomic save
  clears that marker only after the full record exists, so a crash cannot
  resurrect a partially cleared credential.

This migration is covered with legacy-read, first-apply, corrupt-record,
revocation, and interrupted-order tests. It never places the token in
UserDefaults.

### Validation

One production validator is shared by the draft presentation and
`AppState.applyConnectionSettings`:

- trim surrounding whitespace from the relay URL;
- require public `wss://<host>/ws`;
- reject user info, query, and fragment;
- treat a blank replacement token as stored-token reuse;
- normalize a provided replacement token to lowercase and require exactly 64
  hexadecimal characters;
- require either a stored token or a valid replacement.

Validation errors use fixed text and never interpolate a credential or
invitation reference.

### Apply order

`AppState.applyConnectionSettings(relayURLString:replacementMacToken:)`
performs:

1. Reject while a pairing create/invitation/claim/approve/deny/cancel
   transaction is active or cancellation ownership is uncertain.
2. Normalize and validate the complete draft without changing persistence,
   `credentialRevision`, or `RelayClient`.
3. Resolve the connection token: use the validated replacement, otherwise read
   the token from the authoritative or legacy connection snapshot.
4. Atomically write one versioned Keychain record containing the validated URL
   and resolved token. On failure, neither half becomes effective.
5. Update only nonauthoritative URL/migration mirrors after that record exists.
6. Mark credentials eligible and claim the next AppState credential revision.
7. Reuse the existing connection path with the already validated URL and
   resolved token.
8. Report `applied` only if the operation still owns the latest revision.

The Keychain write is the commit point. A crash before it leaves the old pair;
a crash after it loads the new pair on restart even if a UserDefaults mirror
was not refreshed. There is no state in which a new token becomes authoritative
for the old relay URL or vice versa.

Network unavailability after a valid apply does not roll back the saved
configuration. The client remains in Connecting/Disconnected with actionable
feedback and its existing retry policy.

### Existing safety fences

The implementation must continue to use, not duplicate:

- AppState's monotonic `credentialRevision`;
- AppState's status revision and sequence checks;
- RelayClient's credential mutation epoch;
- socket generation cancellation;
- authorization lease revocation before an old transport closes;
- configure-before-start ownership checks.

The validated `PairingController` is installed only after
`RelayClient.configure` accepts the new configuration.

## Pairing transaction fence

`PairingController.blocksConnectionChanges` is true only in states that own
or may own a relay-side pairing transaction:

- creating;
- invitation;
- approval;
- approving;
- denying;
- cancelling;
- cancel-failed, until status reconciliation proves the relay-side invitation
  is no longer live.

Manual Reconnect and Save & Reconnect reject while this flag is true and
explain that the current invitation must be cancelled first. Clear credential
remains an emergency fail-closed action and may disconnect at any time.

The pairing sheet disables implicit dismissal while a transaction is active.
The person must use Cancel Invitation, Codes Don't Match, or a terminal action.
`cancel()` remains in `.cancelling` after the frame is sent; only a correlated
`pair.failed(reason: cancelled)` acknowledgement may return it to ready.
Lost/delayed/stale acknowledgements, send failure, or disconnect before the
acknowledgement produce or retain cancellation uncertainty. That keeps both the
pairing recovery UI and the connection-change fence active until a fresh
authenticated status reconciliation proves the previous owner session ended.

## Settings experience

The single-pane window is titled **Click Bridge Settings** and uses a
scrollable form with an approximately 600-by-560 default size.

### Status

- Relay: Connected, Connecting, or Not Connected.
- Input Permission: Ready or Required, with **Grant Input Permission…**.
- Remote Control: the existing toggle, now also visible in Settings.

Every state uses symbol plus text; color is never the only signal. Reconnect is
available when no pairing transaction blocks it.

### Phone

- Explain: “No phone token is required. A single-use invitation connects the
  phone after you approve the matching code.”
- Legacy enrollment uses **Pair Phone** and explains that older shared setup
  access stops only after the new phone is approved.
- Paired enrollment uses **Replace Phone…** and warns that the current phone
  stops working after approval.
- Disconnected or missing configuration states show the next connection action
  instead of an inert Pair button.

### Advanced connection

- Relay URL draft.
- Secure optional replacement Mac token.
- “Stored securely in Keychain” or “No credential stored.”
- One primary **Save & Reconnect** button.
- **Discard Changes**.
- Separate destructive **Remove Saved Credential…** confirmation.
- Inline, accessibility-announced sanitized errors.

## Pairing sheet

The approximately 700-by-600 sheet keeps one state-driven flow rather than
opening a second approval sheet.

### Invitation

- Title: **Connect Your Phone**.
- A high-contrast, integer-scaled QR image displayed at no less than 280 points.
  The renderer adds an explicit white quiet zone of four QR modules on every
  side rather than relying on view padding or an undocumented filter border.
- Nearby instruction: “On your iPhone, open Click Bridge and scan this code.”
- Visible “Single use · Expires in M:SS” countdown.
- A visually separate **Phone somewhere else?** section with
  **Share Secure Setup Link…** as its primary action and the explanation
  “Send this single-use link through Messages, Mail, or another trusted
  channel. The devices do not need to be on the same network.”
- **Other Ways to Connect** menu with guarded **Copy Invitation Link** and
  **Copy Browser Invitation Link**.
- **Cancel Invitation**.

The native share action uses a lazy `NSItemProvider` whose registered URL/text
representation asks the controller for the current invitation when a selected
sharing service actually requests the data. Opening a picker does not freeze a
bearer URL. Both copy paths and the provider validate that the expected
invitation is still current, unclaimed, and unexpired immediately before data
crosses the process boundary. If the invitation expires, is claimed, is
cancelled, or is regenerated while the picker is open, the provider completes
with a sanitized unavailable error and supplies no URL. All export controls
also disable when known stale. Copy/share feedback never echoes the link. The
QR, native share link, and PWA link contain only the existing opaque single-use
reference, never a role token. Sharing the native `/pair` link lets a configured
Universal Link open Click Bridge on iPhone; the explicit browser action
converts the same invitation to `/pair/web` to avoid Universal Link diversion.

### Approval

- Title: **Check the Code**.
- Identify whether the claimant is the native iPhone app or browser.
- Render the grouped six-digit code prominently.
- Ask: “Do both devices show this same code?”
- Primary **Codes Match — Approve**.
- Destructive **Codes Don't Match**, routed to
  `PairingController.codesDoNotMatch()`.
- Visible expiry countdown.

Implicit sheet dismissal cannot silently approve or deny.

### Terminal and recovery states

- Completed: **Phone connected**, then explain that Accessibility and Remote
  Control must also be ready.
- Expired: explain five-minute, one-use behavior and offer
  **Create New Invitation**.
- Denied/mismatch: **Phone not connected** and **Start Again**.
- Status/create failure: precise Retry copy.
- Cancellation uncertainty: warn not to reuse the old invitation and require
  status reconciliation.

## Accessibility

Stable identifiers cover status, connection fields/actions, pairing sheet, QR,
countdown, client kind, code, match/mismatch actions, and recovery.

The QR exposes:

- label: “Pairing QR code”;
- value: a human-readable remaining lifetime;
- hint: “Scan using Click Bridge on iPhone.”

It never exposes the invitation reference. The confirmation code value is read
digit by digit. Error, copy, expiry, and completion feedback use live-region
semantics where SwiftUI supports them. Keyboard focus and Escape/Return
behavior are checked in the runtime smoke.

## Settings-window presentation

The menu uses SwiftUI's current `openSettings` environment action and then
activates the app from the explicit user action so the managed Settings window
is opened or brought forward. Repeated use must foreground the same Settings
scene rather than creating unmanaged windows.

## App Intents decision

The requested App Intents assessment yields no intent in this release:

- App Shortcuts are not supported on macOS, although manually composed
  Shortcuts actions can use App Intents.
- Pairing is not an in-place external action; it requires a live QR/code UI.
- A zero-parameter “open setup” action duplicates the menu-bar Settings entry.
- URL or token parameters would expand sensitive data into Shortcuts history
  and system surfaces.
- Approve, deny, reconnect, or remote-enable intents would make security
  decisions easier to trigger outside their visual context.

A future zero-parameter open-pairing intent is acceptable only after a
demonstrated repeated workflow and one tested app-owned destination router. It
must never accept or return credentials, invitations, or approval decisions.

## Verification

Required automated evidence:

- red-green tests for draft validation and stored-token reuse;
- AppState URL-only and replacement-token apply tests;
- validation/Keychain failure no-mutation tests;
- save/clear/reconnect supersession tests;
- legacy-to-versioned atomic connection migration, malformed-record, and
  fail-closed revocation tests;
- pairing-active reconnect block tests;
- remote toggle persistence, processor gate, and advertised-state test;
- legacy-versus-paired presentation tests;
- guarded native/PWA copy tests and lazy share-provider tests that mutate state
  after picker creation but before representation loading;
- cancellation tests for matching, stale, delayed, lost, and disconnected
  acknowledgements;
- materialized QR bitmap dimension/border tests and Vision decode of that exact
  production image;
- countdown and digit-by-digit accessibility tests;
- full macOS XCTest suite;
- deterministic XcodeGen regeneration and generated membership inspection;
- Debug build with worktree-local DerivedData;
- secret-pattern scan of changed app/UI files.

Runtime evidence where the local environment permits:

- menu-bar Settings opens and foregrounds one window;
- visible layout at standard and large text;
- keyboard navigation and stable accessibility identifiers;
- QR image has a white quiet zone and remains crisp;
- guarded native sharing launches only for the current unexpired invitation;
- sheet transitions invitation → approval → terminal without nested sheets.

Physical iPhone camera scanning, public-relay enrollment, VoiceOver spoken
output, Accessibility-authorized clicking, Octo, signing, notarization,
TestFlight, and production remain explicitly NOT RUN unless directly observed.

## Primary platform references

- [SettingsLink](https://developer.apple.com/documentation/swiftui/settingslink)
- [OpenSettingsAction](https://developer.apple.com/documentation/swiftui/opensettingsaction)
- [Settings](https://developer.apple.com/documentation/swiftui/settings)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Onboarding HIG](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [App Shortcuts HIG](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts)
