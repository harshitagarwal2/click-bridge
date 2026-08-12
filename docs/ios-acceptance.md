# Native iOS Client Acceptance

**Automated status:** Passed: 83/83 tests, Release Simulator run, and generic iOS Release build

**Physical iPhone status:** `NOT RUN`

The native Click Bridge phone client is implemented and covered by the automated evidence below. Simulator evidence does not validate physical iPhone volume buttons, real `AVAudioSession.outputVolume` KVO delivery, audio-route controls, or end-to-end clicks through the live relay and Mac. Do not treat this document as physical-device acceptance until every applicable physical checklist row has recorded evidence.

## Architecture and behavior

The XcodeGen source of truth is `ios/project.yml`. It generates `ios/ClickBridgePhone.xcodeproj` with the shared scheme `ClickBridgePhone`.

The SwiftUI app composes these responsibilities:

- `AVAudioSessionVolumeSource` observes `AVAudioSession.sharedInstance().outputVolume` through KVO. It does not use camera capture or `AVCaptureEventInteraction`.
- `VolumeDeltaController` establishes a baseline, ignores an exact duplicate value, and publishes one upward or downward delta for each distinct observed value.
- `PhoneAppModel` owns the foreground-session generation. `.active` starts a session, transient `.inactive` preserves it for experiences such as Control Center, and `.background` synchronously invalidates the session, stops volume observation and clock checks, abandons the pending action, and disconnects.
- `PhoneRelayClient` owns one authenticated WSS connection, socket generations, heartbeat, reconnect, and strict protocol-v1 message handling.
- `PhoneClockHealthController` reproduces the five-sample clock-health gate.
- `PhoneActionCoordinator` permits one action in flight and has no queue. It creates one action ID and one immutable protocol-v1 `click` request for each accepted delta. A distinct delta observed while an action is pending is consumed and not replayed.
- `PhoneAppIssue` distinguishes invalid settings, unavailable secure storage, and unavailable system-volume monitoring instead of collapsing those failures into one settings error. Connection progress also reports whether the app is connecting, authenticating, or retrying after a loss.
- The SwiftUI settings sheet owns a validated draft. First setup requires both a valid relay URL and token; after a token is stored, a valid URL can be saved with the token field blank to reuse the Keychain value. A failed save keeps the sensitive draft in memory for correction, and editing either field clears the stale error.
- The on-screen **Trigger 3 Clicks** button calls the same action coordinator and
  is enabled only while the current readiness state can accept an action.
- `TriggerClickIntent` publishes a **Trigger 3 Clicks** App Shortcut and opens the
  app when invoked. It permits only the launch-to-active handoff, makes one
  immediate attempt through the same foreground/readiness/action boundary, and
  discards not-ready, pending, failed, or backgrounded requests rather than
  queueing a delayed click.
- `TerminalNotificationHaptics` runs only after a matching current-generation Mac `action.result`. Relay acceptance, relay rejection, timeout, disconnect, backgrounding, stale results, and duplicate results do not produce a terminal-result haptic.
- The dashboard scrolls at large Dynamic Type sizes, gives rejection results readable descriptions, moves VoiceOver focus only to newly presented or changed issues and outcomes, and exposes stable accessibility labels and identifiers. Deterministic previews cover disconnected, ready, clock-retry accessibility text, first setup, and stored-token error states.

A delta is accepted only when the current foreground session, authenticated socket generation, Mac-online state, Mac remote-control setting, Mac permission, healthy clock, and no-pending-action gates are all ready.

## Automated evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Simulator runtime | Recorded | iPhone 17 on iOS 26.3 |
| XcodeGen project | Passed | `ios/project.yml` generated `ios/ClickBridgePhone.xcodeproj` |
| Shared scheme | Passed | `ClickBridgePhone` is present under `xcshareddata/xcschemes` |
| Release Simulator build | Passed | `ClickBridgePhone` built in Release configuration for iOS Simulator |
| Release Simulator install and launch | Passed | The Release app installed and launched on iPhone 17 / iOS 26.3 |
| Generic device build | Passed | Release build for generic platform `iOS` with code signing disabled |
| Full XCTest suite | Passed: **83/83 tests** | XcodeBuildMCP full suite, including takeover close ordering, focused three-click triggering, App Intent routing, no-delayed-shortcut guarantees, fail-closed Keychain coverage, validated settings drafts, stored-token reuse and repair, typed issues, accessibility-focus transitions and priority, connection-specific detail, and readable rejection results. |
| Release bundle inspection | Passed | The app bundle contains `Assets.car` with `AppIcon`, `PrivacyInfo.xcprivacy`, and `Metadata.appintents`; `ITSAppUsesNonExemptEncryption` is `false` |

The 83 passing automated tests cover the deterministic contracts for:

- upward and downward volume deltas;
- initial baseline and exact duplicate-value callback suppression;
- rapid distinct changes and one-in-flight/no-queue behavior;
- exactly one action ID per accepted distinct delta;
- action expiry, acknowledgement, terminal result, timeout, and haptic timing;
- foreground, transient inactive, background, and stale lifecycle callbacks;
- stale WebSocket generations, authentication, heartbeat, reconnect, and strict frames;
- five-sample clock health, timeout, refresh, and stale clock batches;
- relay URL, token validation, UserDefaults, and Keychain behavior;
- first-setup token requirements, later URL-only saves that reuse the Keychain token, and failed-save draft/error behavior;
- Ready, Not connected, Mac offline, Clock mismatch, and boundary presentation states;
- typed settings, secure-storage, and volume-monitoring issues, connection-specific status detail, readable rejection results, and accessibility-focus transitions;
- on-screen **Trigger 3 Clicks** readiness and one-action-in-flight behavior;
- App Shortcut request routing, foreground delivery, pending-request collapse, and non-reentrant readiness handling;
- fail-closed Keychain initialization behavior.

The correction set also provides deterministic SwiftUI preview states, stable accessibility labels, identifiers, and focus targets, and a scrolling dashboard for large Dynamic Type sizes. These UI behaviors remain part of the manual Dynamic Type and VoiceOver acceptance row below rather than physical-volume Simulator evidence.

This evidence proves compilation and deterministic behavior under injected fakes. It does not prove that a physical iPhone reports a particular hardware interaction as an `outputVolume` change.

## Configure and use

1. Generate the project from `ios/project.yml` and open `ios/ClickBridgePhone.xcodeproj`, or build the shared `ClickBridgePhone` scheme with XcodeBuildMCP.
2. Sign and install the app on an iPhone.
3. Open **Settings** in the app.
4. Enter the relay URL as a `wss://` URL ending exactly in `/ws`. Credentials, query strings, fragments, other schemes, and other paths are rejected.
5. On first setup, enter `PHONE_TOKEN` as exactly 64 lowercase hexadecimal characters, then tap **Save**. On later edits, leave the token blank to keep the stored Keychain token, or enter a valid replacement token.
6. Keep the app in its foreground session and wait for **Ready** before changing system volume.
7. Use either the native client or the PWA as the live phone client, not both simultaneously.

The relay URL is stored in UserDefaults. `PHONE_TOKEN` is stored in Keychain and is cleared from the settings field after a successful save. If saving fails, the settings sheet stays open and preserves the entered token so the user can correct or retry; editing either field clears the stale error. The token must not be placed in the relay URL or logs.

The app can also show:

- **Not connected** while the current socket is not authenticated;
- **Another phone took over** after relay close code `4004`; this is terminal and does not auto-reconnect until the user taps **Reconnect this phone** or explicitly saves settings again;
- **Mac offline** when the relay reports that the Mac is unavailable;
- **Mac not ready** when Mac remote control or permission is not ready;
- **Checking clock** while the five-sample check is incomplete;
- **Clock mismatch** when clock health fails;
- **Sending** while the one permitted action is pending;
- **At volume boundary** at `0%` or `100%` once the other readiness gates are open.

## Volume source and boundary semantics

The trigger is a distinct observed system output-volume value, not a physical-button event:

- both upward and downward deltas can trigger;
- an unchanged KVO callback is ignored;
- one observed jump across several system increments is still one delta;
- there is no cooldown, because a cooldown could discard legitimate rapid distinct changes;
- a held key may create multiple real deltas and therefore may create multiple accepted actions after earlier actions settle;
- the API does not identify the physical source or map a delta to one physical press;
- Control Center, wired or Bluetooth headset controls, and AirPods can also trigger when they change system output volume;
- an audio level change that does not change system output volume does not trigger.

At a boundary, only the outward direction becomes undetectable:

- At `0%`, Volume Down cannot create another change and cannot be detected. Volume Up can still trigger.
- At `100%`, Volume Up cannot create another change and cannot be detected. Volume Down can still trigger.

**At volume boundary** is therefore an explanation, not a complete disablement of both directions.

## Logical action and physical outcome

Each accepted volume delta, on-screen trigger, or App Shortcut still creates
exactly one logical action ID, one matching terminal result, and at most one
terminal-result haptic. The unchanged protocol action string is `click`. A
Posted action expands on the Mac into exactly three independent ordinary left
clicks: diagnostic deltas `mouseDown +3` and `mouseUp +3`, with Octo `+3` as
the required physical observation. Mac counters count attempted
`CGEvent.post` calls; `CGEvent.post(tap:)` returns no success result, so the
matching Octo delta is authoritative.

## PWA fallback

The existing PWA behavior remains the tap-based fallback, with truthful
three-click button copy. The native client uses the same phone role and
unchanged protocol v1; it adds no iOS-specific relay message or field.
Disconnect or background the native client before using the PWA because the
product supports one live authenticated phone client.

## Physical iPhone acceptance checklist

Record the iPhone model, iOS version, signing identity, relay environment, Mac version, observed action IDs, Mac terminal results, and Octo click counts with the run. Never record `PHONE_TOKEN`.

| Status | Physical check | Required evidence |
| --- | --- | --- |
| `NOT RUN` | Launch and readiness | Signed app launches on a physical iPhone and reaches **Ready** only after authentication, Mac readiness, and five clock samples. |
| `NOT RUN` | Volume Up | From a nonboundary volume with no pending action, one real upward `outputVolume` delta sends exactly one relay action ID, receives one matching Mac terminal result, produces one terminal-result haptic, records Mac `mouseDown +3` and `mouseUp +3`, and increments the Octo click count by three. |
| `NOT RUN` | Volume Down | From a nonboundary volume with no pending action, one real downward delta produces the same one-action/three-physical-click evidence with a new action ID. |
| `NOT RUN` | Duplicate and rapid values | An unchanged callback sends nothing; each accepted distinct delta after settlement receives exactly one new action ID; a delta while pending is not queued or replayed. |
| `NOT RUN` | Held hardware key | Record the actual deltas and actions. Evaluate by distinct accepted deltas, not by assumed physical press count. |
| `NOT RUN` | Control Center and inactive phase | Opening Control Center preserves the foreground session through transient inactive state, and a real system-volume change can trigger while all readiness gates remain open. |
| `NOT RUN` | Wired/Bluetooth headset | When hardware is available, a system-volume change can trigger exactly once per accepted distinct delta; otherwise record `NOT AVAILABLE`. |
| `NOT RUN` | AirPods | When hardware is available, a system-volume change can trigger exactly once per accepted distinct delta; otherwise record `NOT AVAILABLE`. |
| `NOT RUN` | `0%` boundary | The UI explains that Volume Down cannot be detected; Volume Down sends nothing; Volume Up can create one accepted delta and one action. |
| `NOT RUN` | `100%` boundary | The UI explains that Volume Up cannot be detected; Volume Up sends nothing; Volume Down can create one accepted delta and one action. |
| `NOT RUN` | Background stop | After the app reaches background, volume changes send no action and produce no haptic. |
| `NOT RUN` | Reactivation | Returning active creates a fresh session/socket generation and sends nothing until authentication, Mac readiness, and a fresh five-sample clock check complete. |
| `NOT RUN` | Haptic boundary | A forwarded `relay.ack` does not haptic; exactly one haptic occurs only after the matching Mac `action.result`; timeout, disconnect, stale/duplicate result, and background do not haptic. |
| `NOT RUN` | Dynamic Type and VoiceOver | At accessibility Dynamic Type sizes, dashboard and settings content remains reachable by scrolling without clipped controls. VoiceOver announces stable labels for status, issue, volume, trigger, outcome, settings fields, errors, and actions, and moves focus only to a newly presented or changed issue or action result. |
| `NOT RUN` | PWA fallback | After native disconnect/background, the PWA connects as the phone client and one normal tap completes one logical action with exactly three observed Octo clicks. |

## Acceptance conclusion

Automated implementation status is **passed** with 83/83 XcodeBuildMCP tests, including the original ten SwiftUI correction tests and two accessibility-focus transition regressions, a successful Release Simulator build/install/launch on iPhone 17 / iOS 26.3, a successful generic iOS Release device build with signing disabled, and the required release-bundle metadata and resources.

Physical hardware-volume and live end-to-end acceptance remain **`NOT RUN`**. A physical iPhone run is mandatory before claiming the user requirement is fully accepted.
