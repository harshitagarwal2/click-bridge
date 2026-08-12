# Native iOS Volume Client Design

**Archive status:** Historical approved design; not an active implementation
queue. Physical-device acceptance below remains an evidence requirement, not
an inferred pass.

**Status:** Approved for implementation

**Date:** 2026-08-12

**Scope:** Add a native SwiftUI iPhone client without changing PWA behavior, relay behavior, or protocol v1; the Mac expands the unchanged logical `click` action into three independent ordinary left clicks.

## Outcome

While the native app has an active foreground session, each distinct observed change to `AVAudioSession.sharedInstance().outputVolume` may produce exactly one `action.request` through the existing OCI relay when every readiness gate is open. Both upward and downward deltas mean one logical click action, which the Mac expands into exactly three independent ordinary left clicks. The client keeps one action in flight, never queues a volume change, never retries an action, and provides haptic feedback only after the Mac sends a matching terminal `action.result`.

The PWA remains the sequential fallback. Click Bridge supports one authenticated phone role, so the native client and PWA are not intended to stay connected simultaneously. When another phone authenticates, the relay closes the displaced phone with private WebSocket code `4004`. The displaced client shows `Another phone took over` and stops automatic reconnect until the user explicitly taps `Reconnect this phone` or saves configuration again; normal network loss still uses backoff.

## Product Contract and API Limit

The supported Apple surface is KVO on [`AVAudioSession.outputVolume`](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume). The property reports system output volume from `0.0` through `1.0`, and Apple documents that it is observable with key-value observing.

This design deliberately does not use `AVCaptureEventInteraction`, SwiftUI camera-capture events, or an active camera session. Apple restricts capture-event delivery to apps actively using the camera for capture use cases. Click Bridge is not a camera app.

The guarantee is delta-based, not physical-button-based:

- one exact duplicate-value KVO callback produces no action;
- one distinct callback value produces at most one accepted action;
- a callback that jumps across multiple volume increments is still one observed delta and therefore one possible action;
- no cooldown is applied, because a cooldown would discard legitimate rapid distinct changes;
- while an action is in flight, later deltas update the volume baseline but are discarded and never queued;
- a held volume key can produce multiple real output-volume deltas; the supported API does not expose physical press identity, press phase, or source, so the app cannot promise one action per physical press;
- Control Center, wired and Bluetooth headset controls, and AirPods can also change `outputVolume` and therefore can also trigger actions;
- program source audio level changes that do not change system `outputVolume` do not trigger.

The one-in-flight gate suppresses the common double-send/autorepeat window. It does not invent a physical-button identity that the API does not provide.

## Foreground Session Contract

The app owns a foreground session generation separate from SwiftUI's instantaneous scene phase:

1. The first `.active` transition starts a new foreground session generation.
2. The session remains alive through transient `.inactive` transitions. This is required for Control Center: opening it makes the app inactive while it remains the foreground experience, and volume changes there must remain observable.
3. `.background` ends the session synchronously. The app invalidates the generation, stops KVO, deactivates its audio session, cancels timers, closes the socket, abandons any pending action as unknown without retry or haptic, and clears clock health.
4. A later `.active` transition starts a fresh generation, reconnects, authenticates, receives current Mac state, completes a new five-sample clock check, and only then reopens the action gate.
5. An initial `.inactive` phase does not start a session. An unknown future scene phase fails closed as background.

Callbacks carry or capture both the foreground-session generation and the socket generation. Work from a stale generation is ignored before it can mutate readiness, create an action ID, send a frame, or perform a haptic.

## Readiness and Action Gate

A volume delta is accepted only when all of these conditions are true at the same instant:

```text
foreground session exists
+ authenticated current WSS generation
+ current relay state says Mac online
+ Mac remote control enabled
+ Mac permission ready
+ five-sample clock health checked and healthy
+ no action pending
= action gate open
```

Observation can run while the gate is closed so the displayed volume and deduplication baseline stay current. A closed-gate delta is consumed, not deferred. Opening the gate later never replays it.

The status precedence is:

1. `Not connected` when there is no active, authenticated current socket.
2. `Mac offline` when the relay reports `macOnline: false`.
3. `Mac not ready` when remote control is disabled or input permission is not ready.
4. `Checking clock` before five usable samples finish.
5. `Clock mismatch` when the selected sample is outside the existing tolerance.
6. `Sending` while one action is pending.
7. `At volume boundary` when all other gates are ready and volume is exactly `0%` or `100%`.
8. `Ready` otherwise.

`At volume boundary` is informational rather than a total disable. At `0%`, Volume Down cannot create another observable change but Volume Up can. At `100%`, Volume Up cannot create another observable change but Volume Down can. The UI states the blocked direction explicitly.

## Protocol v1: Unchanged

The native client implements the current phone role exactly. It does not introduce an iOS message, a source field, a volume direction field, or a protocol version change.

### Constants

| Contract | Value |
| --- | ---: |
| Protocol version | `1` |
| Maximum UTF-8 text-frame size | `4,096` bytes |
| `PHONE_TOKEN` shape | 64 lowercase hexadecimal characters |
| Action | `click` |
| Action lifetime | `2,000 ms` |
| Phone result timeout | `4,000 ms` |
| Heartbeat interval | `20 s` |
| Heartbeat acknowledgement timeout | `10 s` |
| Reconnect base/cap | `250 ms` / `8,000 ms`, full jitter |
| Clock samples | `5` |
| Clock exchange timeout | `3,500 ms` |
| Clock refresh | `300,000 ms` |
| Clock skew tolerance | `1,000 ms` plus half-RTT allowance |

### Session sequence

```text
phone -> relay  hello { v: 1, role: "phone", token }
relay -> phone  hello.ok { v: 1, role: "phone" }
relay -> phone  state { macOnline, remoteEnabled, permission }
phone <-> relay heartbeat.request / heartbeat.ack
phone <-> Mac   time.sync.request / time.sync.response, forwarded by relay
phone -> relay  action.request { actionId, action: "click", issuedAtUnixMs,
                                 expiresAtUnixMs: issuedAtUnixMs + 2000 }
relay -> phone  relay.ack
Mac -> phone    action.result, forwarded by relay
```

The client accepts text frames only, rejects binary frames, enforces the 4 KiB UTF-8 limit, rejects unknown or missing fields, rejects wrong types and semantic pairings, and validates that every inbound type is legal for the authenticated phone role.

### At-most-once action behavior

For each accepted delta, `PhoneActionCoordinator` generates one lowercase UUID string and constructs one immutable `action.request`. It calls `send` once. It never changes the ID, retries, replays, or creates a replacement after an unknown outcome.

`relay.ack(status: forwarded)` is nonterminal and does not cause haptic feedback. `relay.ack(status: mac_offline|rejected)` settles locally without haptic because it is not a Mac terminal result. A matching current-generation `action.result(status: posted|rejected)` settles and invokes the injected haptics port exactly once. A timeout, disconnect, background transition, duplicate result, mismatched ID, or stale-generation result produces no haptic.

## Architecture

The implementation uses small injected ports around platform and nondeterministic behavior. Domain types do not import AVFAudio, Security, UIKit haptic generators, URLSession WebSocket APIs, or global clocks directly.

```text
SwiftUI scenePhase ───────────────┐
                                 v
AVAudioSession KVO -> VolumeDeltaController -> PhoneAppModel
                                              | readiness gate
                                              v
                                      PhoneActionCoordinator
                                              |
                                              v
                                      PhoneRelayClient -> OCI WSS
                                              ^
PhoneClockHealthController -------------------|

action.result -> PhoneActionCoordinator -> Haptics
```

### Project and modules

The XcodeGen source of truth is `ios/project.yml`. It generates `ios/ClickBridgePhone.xcodeproj` with a shared scheme named `ClickBridgePhone`. CI must use that exact spec path and scheme.

| File | Responsibility |
| --- | --- |
| `ios/project.yml` | iOS app/test targets, shared scheme, fixture resources, build settings |
| `ios/Config/Base.xcconfig` | checked-in nonsecret defaults and signing-neutral build configuration |
| `ios/Config/Local.xcconfig.example` | documented local development-team override; contains no token |
| `ClickBridgePhoneApp.swift` | composition root, Observation-backed model ownership, and SwiftUI scene-phase forwarding |
| `PhoneAppModel.swift` | foreground-session owner, event routing, typed app issues, settings save/reconnect behavior, and presentation state |
| `PhoneState.swift` | pure readiness/status derivation, connection-specific detail, readable result descriptions, and domain value types |
| `PhonePorts.swift` | injected port protocols and shared adapter contracts |
| `VolumeDeltaController.swift` | baseline, duplicate suppression, direction/boundary derivation, observer generation |
| `AVAudioSessionVolumeSource.swift` | `outputVolume` KVO and audio-session activation/deactivation only |
| `PhoneRelayClient.swift` | single socket, authentication, generation, heartbeat, reconnect, inbound event publication |
| `PhoneActionCoordinator.swift` | readiness snapshot, one pending action, action ID/expiry/result handling, haptics |
| `PhoneClockHealthController.swift` | five-sample time sync, best-sample selection, timeouts and refresh |
| `PhoneWireProtocol.swift` | protocol v1 constants and Codable wire value types |
| `StrictPhoneWireDecoder.swift` | text-only, size, exact-field, role and semantic validation |
| `PhoneSettingsStore.swift` | relay URL persistence, split URL/token validation, and stored-token lifecycle |
| `KeychainStore.swift` | Security-framework secret adapter |
| `ContentView.swift` | scrolling dashboard, readiness-gated click control, validated settings draft, accessibility behavior, and deterministic previews |

### Port contracts

```swift
@MainActor
protocol VolumeChangeSource: AnyObject {
    var currentVolume: Float { get }
    func start(observing handler: @escaping @MainActor (Float) -> Void) throws
    func stop()
}

@MainActor
protocol PhoneActionTransport: AnyObject {
    var generation: Int { get }
    var isAuthenticated: Bool { get }
    var onEvent: (@MainActor (PhoneTransportEvent) -> Void)? { get set }
    func connect(configuration: RelayConfiguration)
    func disconnect(reason: String)
    func send(_ message: PhoneClientMessage) -> Bool
}

protocol PhoneClock {
    func nowUnixMilliseconds() -> Double
    func nowMonotonicMilliseconds() -> Double
}

@MainActor
protocol PhoneScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> ScheduledToken
    func cancel(_ token: ScheduledToken)
}

@MainActor
protocol PhoneHaptics: AnyObject {
    func terminalResult(_ result: ActionResult)
}

@MainActor
protocol PhoneWebSocket: AnyObject {
    var onOpen: (@MainActor () -> Void)? { get set }
    var onText: (@MainActor (String) -> Void)? { get set }
    var onBinary: (@MainActor (Data) -> Void)? { get set }
    var onClose: (@MainActor (Error?) -> Void)? { get set }
    func open(url: URL)
    func send(text: String) throws
    func close(code: URLSessionWebSocketTask.CloseCode, reason: String)
}
```

Production adapters and deterministic fakes implement the same contracts. Fakes expose sent messages, scheduled work, connection generations, observed values, and haptic calls without sleeping or contacting a network.

## State Ownership

| Mutable state | Sole owner |
| --- | --- |
| Foreground session generation | `PhoneAppModel` |
| KVO observation and AVAudioSession activation | `AVAudioSessionVolumeSource` |
| Last observed volume and observation generation | `VolumeDeltaController` |
| Socket, socket generation, authentication, reconnect and heartbeat timers | `PhoneRelayClient` |
| Five clock samples, current exchange and refresh timer | `PhoneClockHealthController` |
| Pending action ID, generation and result timeout | `PhoneActionCoordinator` |
| Relay URL and token presence | `PhoneSettingsStore` |
| Settings field values and save error while the sheet is open | `RelaySettingsDraft` in `SettingsView` |
| Typed app issue and last action outcome | `PhoneAppModel` |
| User-visible primary status, connection detail, and readable reason text | pure derivation in `PhoneState` from model snapshots and protocol values |
| Dashboard accessibility focus | `DashboardView` |

No event bus, service locator, dependency-injection container, offline queue, retry queue, persistent action record, camera capture path, or silent-audio playback loop is introduced.

## Settings and Security

- First setup requires a valid `wss://` relay URL ending in `/ws` and a 64-character lowercase hexadecimal `PHONE_TOKEN`. After a token is stored, the user may save a valid URL with the token field blank to reuse the Keychain token, or provide a valid replacement token.
- The relay URL is stored in `UserDefaults`; the token is stored as a generic-password Keychain item under service `com.clickbridge.phone` and account `phoneToken`.
- URL validation rejects credentials, query strings, fragments, non-WSS schemes, and paths other than `/ws`.
- The token appears only in the `hello` text frame. It never appears in a URL, error string, log, analytics event, build setting, source file, screenshot label, or checked-in xcconfig.
- The settings sheet validates its draft before enabling Save. A failed save preserves the URL and sensitive token draft in memory for correction; changing either field clears the stale error. A successful save clears the token field before dismissal.
- Invalid settings, secure-storage failure, and volume-monitoring failure are separate typed issues with distinct recovery copy.
- Changing configuration while foregrounded ends the current generation and begins a newly authenticated and clock-validated session. No pending action crosses configuration generations.

## User Interface

The main screen shows:

- the exact primary status label;
- current system volume as a percentage;
- last Mac result and measured local elapsed time when present;
- a settings button for relay URL and token;
- a readiness-gated **Trigger 3 Clicks** button that invokes the same one-in-flight action coordinator as a volume delta;
- the permanent disclosure: “Any system volume change can trigger, including Control Center, wired or Bluetooth headsets, and AirPods.”

Boundary copy is exact:

- `0%`: “At volume boundary. Volume Down cannot create another change, so it cannot be detected. Volume Up can still trigger.”
- `100%`: “At volume boundary. Volume Up cannot create another change, so it cannot be detected. Volume Down can still trigger.”

Connecting, authenticating, and automatic reconnect backoff provide distinct status detail. Rejection reasons are translated into readable action results, including Mac Accessibility permission, remote-control, expiry, relay-capacity, event-creation, conflict, and invalid-request outcomes.

The dashboard uses a `ScrollView` and scaled volume typography so controls remain reachable at accessibility Dynamic Type sizes. VoiceOver receives stable labels and identifiers for status, issues, volume, trigger, outcomes, retry, settings fields, errors, and toolbar actions. Accessibility focus moves only to newly presented or changed issues and action outcomes. Deterministic previews render disconnected, ready, clock-retry accessibility text, first-setup settings, and stored-token error states without live platform or network dependencies.

The screen exposes a readiness-gated **Trigger 3 Clicks** button and App Shortcut through the same coordinator as volume deltas; neither path bypasses the one-in-flight or lifecycle gates. The existing PWA retains tap fallback behavior with truthful three-click copy.

## Test Strategy

All domain behavior uses deterministic fakes. XCTest runs on the generated iOS test target; existing JSON contract fixtures are included as test resources. The current full Simulator suite passes 90/90 tests, including the current SwiftUI correction coverage and three accessibility-focus transition regressions.

| Area | Required deterministic cases |
| --- | --- |
| Volume deltas | upward, downward, initial baseline, exact duplicate callbacks, one callback spanning several increments, boundary entry/exit |
| Rapid changes | distinct deltas after prior terminal result create distinct IDs; distinct deltas during pending are dropped and not replayed |
| Action identity | exactly one sent `actionId` per accepted delta; one immutable request; no resend on timeout/disconnect/reactivation |
| Lifecycle | active starts; inactive preserves observation/socket; background synchronously stops and invalidates; late callback after background is ignored; next active reconnects and revalidates |
| Socket generation | old open/text/close callbacks cannot affect the current connection or action |
| Protocol | canonical phone fixtures decode; binary, oversized, malformed, unknown-field, wrong-version, wrong-role, invalid status/reason pairing fail closed |
| Heartbeat/reconnect | exact intervals/timeouts, full-jitter cap, one live socket, authentication before readiness |
| Clock | five exchanges, minimum nonnegative RTT sample, mismatch, unavailable timeout, refresh, stale batch generation |
| Expiry/result | `expiresAtUnixMs == issuedAtUnixMs + 2_000`; forwarded ack stays pending; terminal relay rejection settles without haptic; matching Mac result settles with one haptic; `4,000 ms` timeout becomes unknown without retry |
| UI state | Ready, Not connected, Mac offline, Clock mismatch, both boundary messages, Mac-not-ready states, connection-specific detail, typed app issues, readable rejection results, and accessibility-focus transitions |
| Settings | validated draft; first-setup token requirement; stored-token URL-only save; WSS/path/token validation; URL persistence; Keychain save/read/delete/failure; failed-save draft preservation and stale-error clearing; token absent from descriptions |

Deterministic previews support disconnected, ready, retry, first-setup, and stored-token-error review. Dynamic Type scrolling, stable accessibility labels and identifiers, and focus movement for new or changed issues/results are verified through the manual acceptance gate below.

## Build and Acceptance Gates

XcodeGen and the shared scheme are repository contracts:

```bash
xcodegen generate --spec ios/project.yml
xcodebuildmcp simulator list --enabled true --output json
xcodebuildmcp simulator test \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os
```

The simulator can prove compilation, deterministic behavior, UI state rendering, and protocol compatibility. It cannot prove hardware volume behavior. Completion therefore also requires a signed physical-iPhone acceptance run:

1. Launch the app and wait for `Ready`.
2. Press Volume Up once at a nonboundary volume and verify exactly one Mac terminal result, one haptic, Mac `mouseDown +3`/`mouseUp +3`, and three Octo clicks. The Mac counters are attempted `CGEvent.post` calls; because posting returns no success result, Octo is the authoritative physical observation.
3. Wait for the result, press Volume Down once, and verify the same.
4. Exercise rapid distinct presses, a held key, Control Center, wired/Bluetooth controls when available, and AirPods when available; record observed deltas and terminal action IDs without claiming physical source identity.
5. Background the app and verify volume changes send nothing; reactivate and verify no send is possible until authentication, Mac state, and all five clock samples complete.
6. Verify the `0%` and `100%` explanations and the detectable inward direction.
7. At accessibility Dynamic Type sizes, verify the dashboard and settings remain scrollable with every control reachable; with VoiceOver, verify stable labels and focus movement to a new or changed issue and action result without refocusing unchanged history.
8. Confirm the PWA still passes its existing tests and remains available after the native app disconnects.

The hardware-volume requirement is not accepted from simulator evidence. If no physical iPhone and signing identity are available, the implementation can be build/test complete but remains explicitly blocked on physical-device acceptance.

## Compatibility and Non-Goals

The relay sees the native client as the existing `phone` role. OCI compatibility verification consists of authenticating against the deployed relay, completing heartbeat and clock exchange, receiving current Mac state, sending the unchanged action frame, receiving both acknowledgement and Mac result, and confirming the PWA can reconnect afterward. No relay schema, deployment secret, `.github/**` workflow, or PWA source change is required for iOS.

This scope does not include App Store distribution, background execution, lock-screen capture, camera activation, button-source identification, simultaneous native/PWA phone sessions, multiple queued clicks, volume restoration, or programmatic system-volume changes.
