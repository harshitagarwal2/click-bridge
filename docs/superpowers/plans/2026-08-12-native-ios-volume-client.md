# Native iOS Volume Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Use xcodebuildmcp-cli for every Xcode build, test, simulator, device, and diagnostic command. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a foreground native SwiftUI iPhone client that converts each distinct accepted `AVAudioSession.outputVolume` delta into exactly one existing protocol-v1 click action while preserving the PWA unchanged.

**Architecture:** A KVO adapter feeds a deterministic delta controller; `PhoneAppModel` owns the active-to-background foreground session and applies relay, Mac, clock, and one-in-flight gates before `PhoneActionCoordinator` sends. One generation-aware WSS client reuses the exact phone protocol, heartbeat, reconnect, clock-health, expiry, acknowledgement, result, and at-most-once rules already used by the PWA.

**Tech Stack:** Swift 5.9, SwiftUI, AVFAudio KVO, URLSessionWebSocketTask, Security Keychain, UIKit haptics, XCTest, XcodeGen 2.46+, XcodeBuildMCP CLI, existing Click Bridge protocol v1 and JSON fixtures.

## Global Constraints

- Read `docs/superpowers/specs/2026-08-12-native-ios-volume-client-design.md` before implementation; it is the approved design source for this plan.
- Create the XcodeGen source at exactly `ios/project.yml`; generate `ios/ClickBridgePhone.xcodeproj`; expose one shared scheme named exactly `ClickBridgePhone`.
- Use an iOS 17.0 deployment target and Swift 5.9. Add no third-party package or runtime dependency.
- Observe only `AVAudioSession.sharedInstance().outputVolume` via KVO. Do not import AVKit, use `AVCaptureEventInteraction`, use camera-capture event modifiers, request camera permission, or activate a camera session.
- Start a foreground session on `.active`, preserve it through transient `.inactive`, and end it synchronously on `.background`. Do not start from an initial `.inactive` state.
- Stop KVO and sending on background; invalidate foreground, observer, socket, clock-batch, and pending-action generations before asynchronous cleanup can return.
- Accept both upward and downward volume changes. Suppress exact duplicate-value callbacks. Apply no cooldown. One callback that skips multiple volume increments is one delta.
- Keep one action in flight and no queue. A delta received while pending updates the volume baseline but creates no action ID and is never replayed.
- A held key may create multiple real deltas. Document that the supported API cannot identify a physical press or its source.
- Reuse protocol version `1` without adding fields or message types. `action` stays `click`; lifetime stays `2,000 ms`; phone result timeout stays `4,000 ms`.
- Keep one authenticated WSS connection, phone role authentication, current heartbeat, full-jitter reconnect, five-sample clock health, current result handling, and stale-generation rejection.
- Store relay URL in UserDefaults and `PHONE_TOKEN` in Keychain. Never put the token in a URL, log, source file, checked-in xcconfig, error description, or UI after save.
- Trigger only when the foreground session, authenticated current socket, Mac online/remote-enabled/permission-ready state, healthy five-sample clock, and no-pending gates are all open.
- Emit haptic feedback exactly once after a matching current-generation Mac `action.result`, never after `relay.ack`, timeout, disconnect, background, or stale/duplicate result.
- Clearly render `Ready`, `Not connected`, `Mac offline`, `Clock mismatch`, and `At volume boundary`, plus the exact one-direction limitation at `0%` and `100%`.
- State that Control Center, wired/Bluetooth headset, and AirPods changes can also trigger because the API observes output volume, not button source.
- Preserve `relay/public/**` and the PWA tests unchanged. The native app and PWA are sequential fallbacks because the relay supports one live phone role.
- Do not edit `.github/**`. The separate CI/CD lane owns that surface and will consume `ios/project.yml` and scheme `ClickBridgePhone`.
- Use deterministic fakes for every injected port. Write each behavioral test before its production implementation and observe the intended failure.
- Do not claim hardware-volume acceptance from Simulator. A signed physical iPhone run is a required final acceptance gate.

## File Structure and Exact Interfaces

Create these files and no alternate aggregate framework target:

```text
ios/
├── project.yml
├── Config/
│   ├── Base.xcconfig
│   └── Local.xcconfig.example
├── ClickBridgePhone/
│   ├── ClickBridgePhoneApp.swift
│   ├── PhoneAppModel.swift
│   ├── PhoneState.swift
│   ├── PhonePorts.swift
│   ├── VolumeDeltaController.swift
│   ├── AVAudioSessionVolumeSource.swift
│   ├── PhoneRelayClient.swift
│   ├── PhoneActionCoordinator.swift
│   ├── PhoneClockHealthController.swift
│   ├── PhoneWireProtocol.swift
│   ├── StrictPhoneWireDecoder.swift
│   ├── PhoneSettingsStore.swift
│   ├── KeychainStore.swift
│   └── ContentView.swift
└── ClickBridgePhoneTests/
    ├── TestDoubles.swift
    ├── PhoneWireProtocolTests.swift
    ├── VolumeDeltaControllerTests.swift
    ├── PhoneSettingsStoreTests.swift
    ├── PhoneRelayClientTests.swift
    ├── PhoneClockHealthControllerTests.swift
    ├── PhoneActionCoordinatorTests.swift
    ├── PhoneAppModelTests.swift
    └── PhoneStateTests.swift
```

The following signatures are the cross-task contract. Do not rename them in later tasks.

```swift
struct ScheduledToken: Hashable, Sendable { let rawValue: UUID }

protocol PhoneClock: Sendable {
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
protocol VolumeChangeSource: AnyObject {
    var currentVolume: Float { get }
    func start(observing handler: @escaping @MainActor (Float) -> Void) throws
    func stop()
}

@MainActor
protocol PhoneHaptics: AnyObject {
    func terminalResult(_ result: ActionResult)
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

@MainActor
protocol PhoneWebSocketFactory: AnyObject {
    func makeSocket() -> any PhoneWebSocket
}
```

Core domain signatures:

```swift
enum VolumeBoundary: Equatable, Sendable { case minimum, maximum }

struct VolumeReading: Equatable, Sendable {
    let value: Float
    var boundary: VolumeBoundary? {
        if value <= 0 { return .minimum }
        if value >= 1 { return .maximum }
        return nil
    }
}

struct ObservedVolumeDelta: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case up, down }
    let previous: Float
    let current: Float
    let direction: Direction
    let foregroundGeneration: Int
}

enum VolumeDeltaEvent: Equatable, Sendable {
    case baseline(VolumeReading)
    case delta(ObservedVolumeDelta)
}

@MainActor
final class VolumeDeltaController {
    init(source: any VolumeChangeSource)
    func start(foregroundGeneration: Int,
               onEvent: @escaping @MainActor (VolumeDeltaEvent) -> Void) throws
    func stop()
}

struct RelayConfiguration: Equatable, Sendable {
    let url: URL
    let token: String
    static func validated(urlString: String, token: String) throws -> Self
}

struct MacReadiness: Equatable, Sendable {
    var online = false
    var remoteEnabled = false
    var permission: PermissionState = .unknown
}

struct ClockHealth: Equatable, Sendable {
    enum Status: Equatable, Sendable { case unchecked, checking, healthy, mismatch, unavailable }
    let status: Status
    let offsetMilliseconds: Double?
    let uncertaintyMilliseconds: Double?
}

struct ActionGateSnapshot: Equatable, Sendable {
    let foregroundGeneration: Int?
    let socketGeneration: Int
    let transportAuthenticated: Bool
    let mac: MacReadiness
    let clock: ClockHealth
}

enum ActionDisposition: Equatable, Sendable {
    case sent(actionID: UUID)
    case ignoredNotReady
    case ignoredPending
    case sendFailed
}

enum PhoneActionPhase: Equatable, Sendable {
    case idle
    case sending(actionID: UUID)
    case forwarded(actionID: UUID)
    case posted(actionID: UUID, elapsedMilliseconds: Double)
    case rejected(actionID: UUID, reason: ResultReason, elapsedMilliseconds: Double)
    case unknown(actionID: UUID)
}
```

Coordinator and clock signatures:

```swift
@MainActor
final class PhoneActionCoordinator {
    init(transport: any PhoneActionTransport,
         clock: any PhoneClock,
         scheduler: any PhoneScheduler,
         haptics: any PhoneHaptics,
         makeActionID: @escaping @MainActor () -> UUID = UUID.init,
         onPhase: @escaping @MainActor (PhoneActionPhase) -> Void)
    var hasPendingAction: Bool { get }
    func accept(_ delta: ObservedVolumeDelta,
                readiness: ActionGateSnapshot) -> ActionDisposition
    func handle(_ message: PhoneServerMessage, socketGeneration: Int) -> Bool
    func abandonPending(reason: String)
}

@MainActor
final class PhoneClockHealthController {
    init(clock: any PhoneClock,
         scheduler: any PhoneScheduler,
         makeSyncID: @escaping @MainActor () -> UUID = UUID.init,
         isActionPending: @escaping @MainActor () -> Bool,
         onHealth: @escaping @MainActor (ClockHealth) -> Void)
    func start(foregroundGeneration: Int,
               socketGeneration: Int,
               send: @escaping @MainActor (PhoneClientMessage) -> Bool)
    func handle(_ message: TimeSyncResponse, socketGeneration: Int) -> Bool
    func actionDidSettle()
    func retry()
    func stop()
}
```

Transport events and app model signatures:

```swift
enum PhoneConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case authenticated
    case backoff
}

enum PhoneTransportEvent: Equatable, Sendable {
    case connection(generation: Int, state: PhoneConnectionState)
    case message(generation: Int, value: PhoneServerMessage)
}

@MainActor
final class PhoneRelayClient: PhoneActionTransport {
    init(socketFactory: any PhoneWebSocketFactory,
         clock: any PhoneClock,
         scheduler: any PhoneScheduler,
         randomUnit: @escaping @MainActor () -> Double = { Double.random(in: 0..<1) })
    var generation: Int { get }
    var isAuthenticated: Bool { get }
    var onEvent: (@MainActor (PhoneTransportEvent) -> Void)? { get set }
    func connect(configuration: RelayConfiguration)
    func disconnect(reason: String)
    func send(_ message: PhoneClientMessage) -> Bool
}

@MainActor
final class PhoneAppModel: ObservableObject {
    @Published private(set) var state: PhoneState
    let settings: PhoneSettingsStore
    init(settings: PhoneSettingsStore,
         volumeController: VolumeDeltaController,
         transport: any PhoneActionTransport,
         clockHealth: PhoneClockHealthController,
         actions: PhoneActionCoordinator)
    func scenePhaseChanged(_ phase: ScenePhase)
    func saveSettings(urlString: String, token: String) throws
    func retryClockCheck()
}
```

---

### Task 1: Create the XcodeGen project and deterministic port foundation

**Files:**
- Create: `ios/project.yml`
- Create: `ios/Config/Base.xcconfig`
- Create: `ios/Config/Local.xcconfig.example`
- Create: `ios/ClickBridgePhone/ClickBridgePhoneApp.swift`
- Create: `ios/ClickBridgePhone/PhonePorts.swift`
- Create: `ios/ClickBridgePhoneTests/TestDoubles.swift`

**Interfaces:**
- Consumes: Existing `contracts/fixtures/**/*.json` as test resources; no app code.
- Produces: The port signatures in “File Structure and Exact Interfaces”; app target `ClickBridgePhone`; test target `ClickBridgePhoneTests`; shared scheme `ClickBridgePhone`.

- [ ] **Step 1: Write the project specification**

Use this target and scheme structure in `ios/project.yml`:

```yaml
name: ClickBridgePhone
options:
  bundleIdPrefix: com.clickbridge
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.9"
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
targets:
  ClickBridgePhone:
    type: application
    platform: iOS
    sources:
      - path: ClickBridgePhone
    info:
      path: ClickBridgePhone/Info.plist
      properties:
        CFBundleDisplayName: Click Bridge
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.clickbridge.phone
        TARGETED_DEVICE_FAMILY: "1"
  ClickBridgePhoneTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: ClickBridgePhoneTests
      - path: ../contracts/fixtures
        buildPhase: resources
    dependencies:
      - target: ClickBridgePhone
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.clickbridge.phone.tests
        GENERATE_INFOPLIST_FILE: YES
schemes:
  ClickBridgePhone:
    build:
      targets:
        ClickBridgePhone: all
        ClickBridgePhoneTests: [test]
    test:
      targets:
        - ClickBridgePhoneTests
      gatherCoverageData: false
```

`Base.xcconfig` must contain `CODE_SIGN_STYLE = Automatic` and include optional local settings with `#include? "Local.xcconfig"`. `Local.xcconfig.example` contains only `DEVELOPMENT_TEAM = ABCDE12345` and a comment to copy it locally; it contains no relay URL or token.

- [ ] **Step 2: Add the port definitions and deterministic test doubles**

Implement every port signature from the global interface block in `PhonePorts.swift`. Add production `SystemPhoneClock`, `MainQueuePhoneScheduler`, and `TerminalNotificationHaptics` there. In `TestDoubles.swift`, provide `FakePhoneClock`, `FakePhoneScheduler`, `FakeVolumeChangeSource`, `FakePhoneHaptics`, `FakePhoneActionTransport`, `FakePhoneWebSocket`, and `FakePhoneWebSocketFactory` with synchronous inspection methods.

The scheduler fake must not sleep:

```swift
@MainActor
final class FakePhoneScheduler: PhoneScheduler {
    struct Entry {
        let token: ScheduledToken
        let delay: TimeInterval
        let action: @MainActor () -> Void
    }
    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let token = ScheduledToken(rawValue: UUID())
        entries.append(Entry(token: token, delay: delay, action: action))
        return token
    }

    func cancel(_ token: ScheduledToken) {
        entries.removeAll { $0.token == token }
    }

    func run(_ token: ScheduledToken) {
        guard let entry = entries.first(where: { $0.token == token }) else { return }
        cancel(token)
        entry.action()
    }
}
```

- [ ] **Step 3: Add a compile-only composition root**

Create `ClickBridgePhoneApp.swift` with a temporary view containing `Text("Click Bridge")`; do not construct unimplemented services yet. The final composition replaces it in Task 9.

- [ ] **Step 4: Generate the project and verify exact shared scheme discovery**

Run:

```bash
xcodegen generate --spec ios/project.yml
xcodebuildmcp project-discovery list-schemes \
  --project-path ios/ClickBridgePhone.xcodeproj
```

Expected: generation succeeds and the scheme list contains exactly `ClickBridgePhone` for the iOS project.

- [ ] **Step 5: Build the empty iOS target**

Run:

```bash
xcodebuildmcp simulator build \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os
```

Expected: `ClickBridgePhone` builds. If that simulator name is absent, run `xcodebuildmcp simulator list --enabled true --output json`, choose an enabled iPhone shown by the command, and use that exact name for all later local simulator commands.

- [ ] **Step 6: Commit the independently buildable project shell**

```bash
git add ios/project.yml ios/Config ios/ClickBridgePhone/ClickBridgePhoneApp.swift ios/ClickBridgePhone/PhonePorts.swift ios/ClickBridgePhoneTests/TestDoubles.swift ios/ClickBridgePhone.xcodeproj
git commit -m "build(ios): scaffold ClickBridgePhone project"
```

### Task 2: Implement the exact protocol-v1 phone codec

**Files:**
- Create: `ios/ClickBridgePhone/PhoneWireProtocol.swift`
- Create: `ios/ClickBridgePhone/StrictPhoneWireDecoder.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneWireProtocolTests.swift`

**Interfaces:**
- Consumes: `PhoneClock`; existing canonical fixtures under `contracts/fixtures`.
- Produces: `PhoneClientMessage`, `PhoneServerMessage`, `Hello`, `HeartbeatRequest`, `TimeSyncRequest`, `ActionRequest`, `HelloOK`, `HeartbeatAck`, `RelayState`, `RelayAck`, `TimeSyncResponse`, `ActionResult`, `PermissionState`, `ResultReason`, `StrictPhoneWireDecoder.decodeText(_:)`, `PhoneClientMessage.encodedText()`, and `PhoneClientMessage.actionID: UUID?` for deterministic sent-request inspection.

- [ ] **Step 1: Write failing fixture and semantic tests**

Add tests that load the canonical server-to-phone fixtures, reject invalid descriptors, and assert exact outbound JSON keys. Include this expiry assertion:

```swift
func testActionRequestHasExactProtocolVersionActionAndLifetime() throws {
    let id = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!
    let request = ActionRequest(actionID: id,
                                action: "click",
                                issuedAtUnixMilliseconds: 1_786_579_200_000,
                                expiresAtUnixMilliseconds: 1_786_579_202_000)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(try PhoneClientMessage.actionRequest(request).encodedText().utf8))
        as? [String: Any]
    )
    XCTAssertEqual(Set(object.keys),
                   ["type", "v", "actionId", "action", "issuedAtUnixMs", "expiresAtUnixMs"])
    XCTAssertEqual(object["v"] as? Int, 1)
    XCTAssertEqual(object["action"] as? String, "click")
    XCTAssertEqual((object["expiresAtUnixMs"] as! Double) -
                   (object["issuedAtUnixMs"] as! Double), 2_000)
}
```

Also assert binary rejection, 4,096-byte acceptance, 4,097-byte rejection, unknown fields, wrong version, wrong role, negative/fractional heartbeat sequence, invalid relay status/reason pairs, and invalid result status/reason pairs.

- [ ] **Step 2: Run the protocol tests and verify failure**

Run:

```bash
xcodebuildmcp simulator test \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os \
  --extra-args '-only-testing:ClickBridgePhoneTests/PhoneWireProtocolTests'
```

Expected: FAIL because the wire types and decoder do not exist.

- [ ] **Step 3: Implement exact wire values and strict decoding**

Define these constants without independent iOS-only variants:

```swift
enum PhoneProtocolV1 {
    static let version = 1
    static let maximumMessageBytes = 4_096
    static let actionLifetimeMilliseconds: Double = 2_000
    static let resultTimeout: TimeInterval = 4
    static let heartbeatInterval: TimeInterval = 20
    static let heartbeatTimeout: TimeInterval = 10
    static let reconnectBase: TimeInterval = 0.25
    static let reconnectCap: TimeInterval = 8
    static let clockSampleCount = 5
    static let clockExchangeTimeout: TimeInterval = 3.5
    static let clockRefreshInterval: TimeInterval = 300
    static let clockSkewToleranceMilliseconds: Double = 1_000
}
```

Use explicit CodingKeys for the wire names `actionId`, `issuedAtUnixMs`, `expiresAtUnixMs`, `phoneSendUnixMs`, `macReceiveUnixMs`, `macSendUnixMs`, `relayProcessingUs`, `macProcessingUs`, and `mouseDownPostedUnixMs`. Encode one flat JSON object per enum case; do not use Swift's synthesized associated-enum representation.

`StrictPhoneWireDecoder` must first validate UTF-8 byte count and JSON object shape, then exact fields and scalar/enum semantics, then decode the selected message struct. Permit only these authenticated-phone inbound types: `hello.ok`, `heartbeat.ack`, `state`, `relay.ack`, `action.result`, `diagnostics.counters`, and `time.sync.response`. The iOS app does not need to act on diagnostics, but the parser must reject rather than misparse a legal protocol frame.

- [ ] **Step 4: Run the protocol tests and verify pass**

Repeat the Task 2 test command.

Expected: PASS for canonical fixtures, exact encoding, role restrictions, binary/size failures, and semantic failures.

- [ ] **Step 5: Commit the protocol slice**

```bash
git add ios/ClickBridgePhone/PhoneWireProtocol.swift ios/ClickBridgePhone/StrictPhoneWireDecoder.swift ios/ClickBridgePhoneTests/PhoneWireProtocolTests.swift
git commit -m "feat(ios): add strict phone protocol v1 codec"
```

### Task 3: Convert KVO values into deterministic deltas

**Files:**
- Create: `ios/ClickBridgePhone/VolumeDeltaController.swift`
- Create: `ios/ClickBridgePhone/AVAudioSessionVolumeSource.swift`
- Create: `ios/ClickBridgePhoneTests/VolumeDeltaControllerTests.swift`

**Interfaces:**
- Consumes: `VolumeChangeSource`, `VolumeReading`, `ObservedVolumeDelta`, `VolumeDeltaEvent` from Task 1.
- Produces: `VolumeDeltaController.start(foregroundGeneration:onEvent:)`, `VolumeDeltaController.stop()`, and `AVAudioSessionVolumeSource`.

- [ ] **Step 1: Write failing delta, duplicate, rapid, boundary, and stale-observer tests**

Use `FakeVolumeChangeSource.emit(_:)` to cover this exact sequence:

```swift
func testUpDownDuplicatesAndRapidDistinctValuesProduceOnlyDistinctDeltas() throws {
    let source = FakeVolumeChangeSource(volume: 0.50)
    let subject = VolumeDeltaController(source: source)
    var events: [VolumeDeltaEvent] = []
    try subject.start(foregroundGeneration: 7) { events.append($0) }

    source.emit(0.50)
    source.emit(0.5625)
    source.emit(0.5625)
    source.emit(0.50)
    source.emit(0.625)

    XCTAssertEqual(events, [
        .baseline(VolumeReading(value: 0.50)),
        .delta(.init(previous: 0.50, current: 0.5625,
                     direction: .up, foregroundGeneration: 7)),
        .delta(.init(previous: 0.5625, current: 0.50,
                     direction: .down, foregroundGeneration: 7)),
        .delta(.init(previous: 0.50, current: 0.625,
                     direction: .up, foregroundGeneration: 7))
    ])
}
```

Add tests proving `0` maps to `.minimum`, `1` maps to `.maximum`, an initial callback establishes baseline without a delta, a jump from `0.25` to `0.75` is one delta, `stop()` invalidates a late callback, and restarting with generation 8 ignores a captured generation-7 handler.

- [ ] **Step 2: Run the volume tests and verify failure**

Run the iOS test target filtered to `VolumeDeltaControllerTests`.

Expected: FAIL because the controller and adapter do not exist.

- [ ] **Step 3: Implement delta conversion without cooldown or queue**

On `start`, call `stop`, increment a private observation generation, clear the baseline, and start the source. Treat the first value as `.baseline`; thereafter update `lastObservedVolume` before publishing a distinct delta. Exact `Float` equality suppresses callback noise. Invalid values that are nonfinite or outside `0...1` are ignored without changing the baseline.

Implement the production adapter with the supported KVO surface:

```swift
@MainActor
final class AVAudioSessionVolumeSource: VolumeChangeSource {
    private let session: AVAudioSession
    private var observation: NSKeyValueObservation?

    init(session: AVAudioSession = .sharedInstance()) { self.session = session }

    var currentVolume: Float { session.outputVolume }

    func start(observing handler: @escaping @MainActor (Float) -> Void) throws {
        stop()
        try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        observation = session.observe(\.outputVolume, options: [.initial, .new]) {
            _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in handler(value) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
```

Do not add an audio player, silent audio file, `MPVolumeView`, camera API, debounce, throttle, cooldown, or volume restoration.

- [ ] **Step 4: Run the volume tests and verify pass**

Run the filtered `VolumeDeltaControllerTests` command.

Expected: PASS for up/down, duplicate KVO callbacks, rapid distinct changes, stale callbacks, jumps, and both boundaries.

- [ ] **Step 5: Commit the volume slice**

```bash
git add ios/ClickBridgePhone/VolumeDeltaController.swift ios/ClickBridgePhone/AVAudioSessionVolumeSource.swift ios/ClickBridgePhoneTests/VolumeDeltaControllerTests.swift
git commit -m "feat(ios): observe distinct output volume deltas"
```

### Task 4: Persist and validate relay settings securely

**Files:**
- Create: `ios/ClickBridgePhone/PhoneSettingsStore.swift`
- Create: `ios/ClickBridgePhone/KeychainStore.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `RelayConfiguration.validated(urlString:token:)` from Task 1.
- Produces: `SecretStoring`, `KeychainStore`, `PhoneSettingsStore.relayURLString`, `PhoneSettingsStore.hasToken`, `phoneToken()`, `savePhoneToken(_:)`, and `clearPhoneToken()`.

- [ ] **Step 1: Write failing URL, token, persistence, Keychain, and redaction tests**

Test accepted `wss://relay.example/ws` and rejection of `ws://`, credentials, query, fragment, wrong path, uppercase token, nonhex token, and a token whose length is not 64. Use an isolated UserDefaults suite and `FakeSecretStore`.

```swift
func testConfigurationAcceptsOnlyWSSWSPathAndLowercaseHexToken() throws {
    let token = String(repeating: "a", count: 64)
    XCTAssertEqual(try RelayConfiguration.validated(
        urlString: "wss://relay.example/ws", token: token).url.absoluteString,
        "wss://relay.example/ws")
    XCTAssertThrowsError(try RelayConfiguration.validated(
        urlString: "ws://relay.example/ws", token: token))
    XCTAssertThrowsError(try RelayConfiguration.validated(
        urlString: "wss://relay.example/ws?token=secret", token: token))
    XCTAssertThrowsError(try RelayConfiguration.validated(
        urlString: "wss://relay.example/ws", token: token.uppercased()))
}
```

Assert that thrown localized descriptions never contain the supplied token and that `Local.xcconfig.example` contains neither `PHONE_TOKEN` nor a 64-hex test secret.

- [ ] **Step 2: Run the settings tests and verify failure**

Run the iOS test target filtered to `PhoneSettingsStoreTests`.

Expected: FAIL because settings and Keychain adapters do not exist.

- [ ] **Step 3: Implement UserDefaults and Keychain storage**

Define:

```swift
protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

@MainActor
final class PhoneSettingsStore: ObservableObject {
    static let relayURLKey = "relayURL"
    static let phoneTokenAccount = "phoneToken"
    @Published var relayURLString: String
    @Published private(set) var hasToken: Bool
    @Published private(set) var storageError: String?

    init(defaults: UserDefaults = .standard,
         secrets: any SecretStoring = KeychainStore()) throws
    func phoneToken() throws -> String?
    func savePhoneToken(_ token: String) throws
    func clearPhoneToken() throws
}
```

Use Keychain service `com.clickbridge.phone`, generic-password class, and account `phoneToken`. Validate before saving. Surface redacted storage errors through `storageError`.

- [ ] **Step 4: Run the settings tests and verify pass**

Repeat the filtered settings test command.

Expected: PASS for URL/token validation, persistence, delete, failures, and secret redaction.

- [ ] **Step 5: Commit the settings slice**

```bash
git add ios/ClickBridgePhone/PhoneSettingsStore.swift ios/ClickBridgePhone/KeychainStore.swift ios/ClickBridgePhoneTests/PhoneSettingsStoreTests.swift ios/Config
git commit -m "feat(ios): store relay settings securely"
```

### Task 5: Build the generation-aware authenticated WSS transport

**Files:**
- Create: `ios/ClickBridgePhone/PhoneRelayClient.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneRelayClientTests.swift`

**Interfaces:**
- Consumes: `PhoneActionTransport`, `PhoneWebSocket`, `PhoneWebSocketFactory`, `PhoneScheduler`, `PhoneClock`, protocol-v1 codec, `RelayConfiguration`.
- Produces: `PhoneRelayClient`, `URLSessionPhoneWebSocket`, `URLSessionPhoneWebSocketFactory`, `PhoneTransportEvent`, and `PhoneConnectionState`.

- [ ] **Step 1: Write failing authentication, heartbeat, reconnect, and stale-generation tests**

Tests must prove:

- `connect` creates one socket and sends exactly one `hello` with role `phone` after open;
- no non-`hello.ok` message is accepted before authentication;
- a duplicate `hello.ok`, binary frame, invalid text frame, or socket failure invalidates the generation;
- `heartbeat.request` starts after 20 seconds, uses increasing integer sequence, and a matching `heartbeat.ack` cancels the 10-second liveness timeout;
- heartbeat timeout closes the socket and schedules full-jitter reconnect;
- reconnect ceiling is `min(8, 0.25 * 2^(attempt-1))`, and injected `randomUnit` multiplies the ceiling;
- `connect` and `disconnect` cancel old timers and increment generation;
- callbacks captured from an old socket cannot authenticate, publish, close, or reconnect the current socket;
- `send` is false before authentication and calls the current socket exactly once after authentication.

Use this stale-generation assertion:

```swift
func testOldSocketCallbacksCannotAffectNewGeneration() {
    subject.connect(configuration: configuration)
    let old = factory.sockets[0]
    subject.connect(configuration: configuration)
    let currentGeneration = subject.generation
    let current = factory.sockets[1]

    old.emitOpen()
    old.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
    old.emitClose()

    XCTAssertEqual(subject.generation, currentGeneration)
    XCTAssertFalse(subject.isAuthenticated)
    XCTAssertTrue(current.sentTexts.isEmpty)
}
```

- [ ] **Step 2: Run transport tests and verify failure**

Run the iOS test target filtered to `PhoneRelayClientTests`.

Expected: FAIL because the relay client does not exist.

- [ ] **Step 3: Implement one socket-generation owner**

Keep all transport mutation on `@MainActor`. Every socket callback closes over both the socket identity and captured generation, with this first guard:

```swift
guard generation == self.generation, socket === self.socket else { return }
```

On open, send the protocol-v1 `hello`. On exact `hello.ok(role: phone)`, set authenticated, reset reconnect attempt, publish `.authenticated`, and schedule heartbeat. Publish other decoded messages with the captured generation. A failure must invalidate the generation before closing and scheduling reconnect.

Implement the URLSession adapter using `URLSessionWebSocketTask`; maintain one receive loop, distinguish `.string` from `.data`, and forward close/error once. Never coerce binary data to text.

- [ ] **Step 4: Run transport tests and verify pass**

Repeat the filtered transport test command.

Expected: PASS for authentication, single connection, heartbeat, reconnect jitter, strict frames, and stale generation.

- [ ] **Step 5: Commit the transport slice**

```bash
git add ios/ClickBridgePhone/PhoneRelayClient.swift ios/ClickBridgePhoneTests/PhoneRelayClientTests.swift
git commit -m "feat(ios): add authenticated phone relay transport"
```

### Task 6: Reproduce the five-sample phone clock-health contract

**Files:**
- Create: `ios/ClickBridgePhone/PhoneClockHealthController.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneClockHealthControllerTests.swift`

**Interfaces:**
- Consumes: `PhoneClock`, `PhoneScheduler`, `PhoneClientMessage.timeSyncRequest`, `TimeSyncResponse`.
- Produces: `PhoneClockHealthController` signatures from the global interface block and pure `ClockSample` selection helpers.

- [ ] **Step 1: Write failing five-sample, timeout, refresh, busy, and stale-batch tests**

Assert the NTP calculations exactly:

```swift
func testClockSampleAndBestSampleMatchPWAFormula() {
    let first = ClockSample(t0: 1_000, t1: 1_020, t2: 1_021, t3: 1_051)
    let second = ClockSample(t0: 2_000, t1: 2_005, t2: 2_006, t3: 2_016)
    XCTAssertEqual(first.offsetMilliseconds, -5)
    XCTAssertEqual(first.roundTripMilliseconds, 50)
    XCTAssertEqual(ClockSample.best([first, second]), second)
}
```

Add tests that require exactly five sequential exchanges, match both `syncId` and echoed `phoneSendUnixMs`, ignore stale socket generation, declare unavailable after 3.5 seconds, select the smallest nonnegative RTT, evaluate `abs(offset) <= 1_000 + rtt / 2`, schedule refresh after 300 seconds, defer refresh while an action is pending, and start the deferred batch from `actionDidSettle()`.

- [ ] **Step 2: Run clock tests and verify failure**

Run the iOS test target filtered to `PhoneClockHealthControllerTests`.

Expected: FAIL because the clock controller and sample helpers do not exist.

- [ ] **Step 3: Implement clock batches with generation checks**

Define:

```swift
struct ClockSample: Equatable, Sendable {
    let offsetMilliseconds: Double
    let roundTripMilliseconds: Double

    init(t0: Double, t1: Double, t2: Double, t3: Double) {
        offsetMilliseconds = ((t1 - t0) + (t2 - t3)) / 2
        roundTripMilliseconds = (t3 - t0) - (t2 - t1)
    }

    static func best(_ samples: [Self]) -> Self? {
        samples.filter { $0.roundTripMilliseconds.isFinite && $0.roundTripMilliseconds >= 0 }
            .min { $0.roundTripMilliseconds < $1.roundTripMilliseconds }
    }
}
```

The controller sends the next request only after consuming the current matching response. It publishes `.checking` at batch start, `.unavailable` on send failure/timeout/no usable sample, and `.healthy` or `.mismatch` after five usable exchanges. `stop()` increments the private batch token and cancels exchange/refresh timers before clearing samples.

- [ ] **Step 4: Run clock tests and verify pass**

Repeat the filtered clock test command.

Expected: PASS for formula parity, five-sample gating, timeout, refresh, pending deferral, and stale batches.

- [ ] **Step 5: Commit the clock slice**

```bash
git add ios/ClickBridgePhone/PhoneClockHealthController.swift ios/ClickBridgePhoneTests/PhoneClockHealthControllerTests.swift
git commit -m "feat(ios): add phone clock health validation"
```

### Task 7: Enforce one action in flight and at-most-once action IDs

**Files:**
- Create: `ios/ClickBridgePhone/PhoneActionCoordinator.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneActionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ObservedVolumeDelta`, `ActionGateSnapshot`, `PhoneActionTransport`, `PhoneClock`, `PhoneScheduler`, `PhoneHaptics`, protocol request/ack/result values.
- Produces: `PhoneActionCoordinator`, `ActionDisposition`, and `PhoneActionPhase`.

- [ ] **Step 1: Write failing readiness, identity, rapid-change, expiry, result, and haptic tests**

Build a ready snapshot with foreground generation 4, socket generation 9, authenticated transport, online/remote-enabled/permission-ready Mac, and healthy clock. Cover all closed gates independently.

The core identity test is:

```swift
func testExactlyOneActionIDPerAcceptedDeltaAndNoQueueWhilePending() {
    let ids = [
        UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!,
        UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030df")!
    ]
    var index = 0
    let subject = makeSubject(makeActionID: { defer { index += 1 }; return ids[index] })

    XCTAssertEqual(subject.accept(delta(0.50, 0.56), readiness: ready),
                   .sent(actionID: ids[0]))
    XCTAssertEqual(subject.accept(delta(0.56, 0.62), readiness: ready),
                   .ignoredPending)
    XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), [ids[0]])

    XCTAssertTrue(subject.handle(.actionResult(posted(ids[0])), socketGeneration: 9))
    XCTAssertEqual(subject.accept(delta(0.62, 0.56), readiness: ready),
                   .sent(actionID: ids[1]))
    XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), ids)
}
```

Add tests proving:

- `issuedAtUnixMs` comes from the injected wall clock and expiry is exactly `+2_000`;
- the same immutable request is sent once;
- send failure settles immediately without a replacement ID;
- `relay.ack(forwarded)` changes phase but remains pending and does not haptic;
- terminal relay ack settles without haptic;
- matching current-generation `action.result(posted|rejected)` settles and haptics once;
- duplicate, mismatched-ID, and stale-generation results are ignored without haptic;
- 4-second timeout becomes unknown with no retry;
- disconnect/background abandonment becomes unknown with no retry or haptic;
- a rapid distinct delta after the first terminal result produces its own new ID.

- [ ] **Step 2: Run coordinator tests and verify failure**

Run the iOS test target filtered to `PhoneActionCoordinatorTests`.

Expected: FAIL because the action coordinator does not exist.

- [ ] **Step 3: Implement one pending record with no queue**

Use one private record:

```swift
private struct PendingAction {
    let request: ActionRequest
    let foregroundGeneration: Int
    let socketGeneration: Int
    let startedMonotonicMilliseconds: Double
    let timeout: ScheduledToken
}
```

`accept` first checks no pending, then all readiness fields, then the delta's foreground generation. Generate one UUID, construct one immutable request, call `transport.send` once, and retain the pending record only when send returns true. `handle` must match current pending ID and captured socket generation before state change. Invoke `haptics.terminalResult` only inside the matching `action.result` branch before clearing pending; guard clearing so duplicate delivery cannot haptic again.

- [ ] **Step 4: Run coordinator tests and verify pass**

Repeat the filtered coordinator test command.

Expected: PASS for both directions, gates, exact action identity, expiry, pending suppression, rapid separate changes, terminal handling, and haptic timing.

- [ ] **Step 5: Commit the action slice**

```bash
git add ios/ClickBridgePhone/PhoneActionCoordinator.swift ios/ClickBridgePhoneTests/PhoneActionCoordinatorTests.swift
git commit -m "feat(ios): coordinate at-most-once volume actions"
```

### Task 8: Own lifecycle races, readiness, and presentation state

**Files:**
- Create: `ios/ClickBridgePhone/PhoneState.swift`
- Create: `ios/ClickBridgePhone/PhoneAppModel.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneAppModelTests.swift`
- Create: `ios/ClickBridgePhoneTests/PhoneStateTests.swift`

**Interfaces:**
- Consumes: settings, volume controller, transport, clock controller, action coordinator, all event and snapshot values.
- Produces: `PhoneState`, `PhonePrimaryStatus`, pure `PhoneState.deriveStatus()`, and `PhoneAppModel` lifecycle/event routing.

- [ ] **Step 1: Write failing lifecycle and foreground/background race tests**

Cover the exact transition table:

| Previous | Incoming | Required effect |
| --- | --- | --- |
| no session | `.inactive` | no start, no connect, no KVO |
| no session | `.active` | new generation, connect, start KVO, clock remains unchecked |
| active session | `.inactive` | preserve same session/socket/KVO/pending |
| inactive foreground session | `.active` | preserve same generation; do not duplicate connect/KVO |
| foreground session | `.background` | synchronously invalidate, stop KVO/clock, abandon pending, disconnect |
| background | `.active` | new generation, reconnect, fresh five-sample validation |

Capture the old source callback, call `.background`, invoke the callback, and assert no ID and no send. Deliver an old-generation socket result after reactivation and assert no phase/haptic change.

Also test that every delta updates displayed volume before the action decision, so a pending/closed-gate delta is not queued and cannot fire when readiness later becomes healthy.

- [ ] **Step 2: Write failing status and boundary copy tests**

Define:

```swift
enum PhonePrimaryStatus: Equatable, Sendable {
    case notConnected
    case macOffline
    case macNotReady
    case checkingClock
    case clockMismatch
    case sending
    case atVolumeBoundary(VolumeBoundary)
    case ready
}
```

Assert exact display titles and boundary details:

```swift
XCTAssertEqual(PhonePrimaryStatus.ready.title, "Ready")
XCTAssertEqual(PhonePrimaryStatus.notConnected.title, "Not connected")
XCTAssertEqual(PhonePrimaryStatus.macOffline.title, "Mac offline")
XCTAssertEqual(PhonePrimaryStatus.clockMismatch.title, "Clock mismatch")
XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).title, "At volume boundary")
XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).detail,
               "Volume Down cannot create another change, so it cannot be detected. Volume Up can still trigger.")
XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.maximum).detail,
               "Volume Up cannot create another change, so it cannot be detected. Volume Down can still trigger.")
```

Test precedence exactly as specified in the design: connection, Mac, clock, sending, boundary, ready.

- [ ] **Step 3: Run model/state tests and verify failure**

Run the iOS target filtered to `PhoneAppModelTests` and `PhoneStateTests`.

Expected: FAIL because model and presentation state do not exist.

- [ ] **Step 4: Implement synchronous lifecycle invalidation and event routing**

`scenePhaseChanged(.background)` must perform state invalidation before calling adapters:

```swift
foregroundGeneration = nil
state.foregroundSessionActive = false
volumeController.stop()
clockHealth.stop()
actions.abandonPending(reason: "background")
transport.disconnect(reason: "background")
state.connection = .disconnected
state.clock = .init(status: .unchecked,
                    offsetMilliseconds: nil,
                    uncertaintyMilliseconds: nil)
```

Do nothing on `.inactive` once a foreground generation exists. On `.active` with no session, increment the stored counter, validate settings, connect, and start the volume controller with the new generation. Route authenticated current-generation transport events to clock start; route `state` to Mac readiness; route `time.sync.response` to clock health; route ack/result to action coordinator. Never route stale generation.

Changing valid settings while foregrounded must execute the same end sequence and start a fresh session generation. A validation error leaves the gate closed and exposes a redacted settings error.

- [ ] **Step 5: Run model/state tests and verify pass**

Repeat the filtered model/state command.

Expected: PASS for active/inactive/background, stale observer/socket races, reconnect/revalidation, closed-gate consumption, status precedence, and boundary copy.

- [ ] **Step 6: Commit the lifecycle/state slice**

```bash
git add ios/ClickBridgePhone/PhoneState.swift ios/ClickBridgePhone/PhoneAppModel.swift ios/ClickBridgePhoneTests/PhoneAppModelTests.swift ios/ClickBridgePhoneTests/PhoneStateTests.swift
git commit -m "feat(ios): gate volume actions by foreground readiness"
```

### Task 9: Compose the production app and render required SwiftUI states

**Files:**
- Modify: `ios/ClickBridgePhone/ClickBridgePhoneApp.swift`
- Create: `ios/ClickBridgePhone/ContentView.swift`
- Modify: `ios/ClickBridgePhone/PhonePorts.swift`

**Interfaces:**
- Consumes: Every production adapter and domain controller from Tasks 1–8.
- Produces: One `@main` composition root, scene-phase forwarding, settings form, main status UI, terminal-result haptics.

- [ ] **Step 1: Add a failing composition smoke test**

Add `testProductionCompositionCreatesWithoutStartingSession()` to `PhoneAppModelTests`. Construct the same dependencies as the app with deterministic adapters and assert initial status `Not connected`, no socket, and no volume observation before `.active`.

- [ ] **Step 2: Run the composition smoke test and verify failure**

Run `PhoneAppModelTests`.

Expected: FAIL until the composition helper and final model initialization are available.

- [ ] **Step 3: Replace the shell app with the production composition root**

Construct exactly one instance of each mutable owner in dependency order. Break the action-pending closure cycle with a weak box or a post-construction closure holder; do not add a service locator or global singleton. Forward aggregate scene phase:

```swift
@main
struct ClickBridgePhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhoneComposition.makeModel()

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
```

`TerminalNotificationHaptics.terminalResult(_:)` uses `UINotificationFeedbackGenerator`: `.success` for posted and `.error` for rejected. It is called only by `PhoneActionCoordinator` after a matching Mac result.

- [ ] **Step 4: Implement the required main and settings UI**

Render the status title, status detail, integer-rounded volume percentage, last action outcome, and settings sheet. Include this disclosure verbatim:

```swift
Text("Any system volume change can trigger, including Control Center, wired or Bluetooth headsets, and AirPods.")
```

The saved token field uses `SecureField`; after save, clear its local binding. Do not display the saved token. The main screen contains no native click button. Accessibility labels must expose status, volume percentage, and boundary direction limit.

- [ ] **Step 5: Run focused tests and the full generated scheme**

Run:

```bash
xcodegen generate --spec ios/project.yml
xcodebuildmcp simulator test \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os
```

Expected: all iOS tests pass and the app target builds.

- [ ] **Step 6: Build and run the simulator UI for state inspection**

Run:

```bash
xcodebuildmcp simulator build-and-run \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os
```

Expected: the app launches and initially shows `Not connected` with settings available. Record that Simulator does not validate hardware-volume KVO behavior.

- [ ] **Step 7: Commit the composed app**

```bash
git add ios/ClickBridgePhone ios/ClickBridgePhoneTests ios/ClickBridgePhone.xcodeproj
git commit -m "feat(ios): add SwiftUI volume client experience"
```

### Task 10: Prove regression safety and protocol compatibility locally

**Files:**
- Modify only if a verified discrepancy requires it: `ios/**`
- Do not modify: `relay/public/**`, `.github/**`

**Interfaces:**
- Consumes: Generated iOS scheme and the unchanged relay/PWA test suites.
- Produces: Fresh full-test evidence and a zero-diff proof for the PWA source surface.

- [ ] **Step 1: Regenerate and inspect generated project consistency**

Run twice and confirm the second run produces no tracked change:

```bash
xcodegen generate --spec ios/project.yml
git diff --exit-code -- ios/ClickBridgePhone.xcodeproj
xcodegen generate --spec ios/project.yml
git diff --exit-code -- ios/ClickBridgePhone.xcodeproj
```

Expected: generated project is deterministic and scheme `ClickBridgePhone` remains shared.

- [ ] **Step 2: Run all native iOS tests**

Run the full Task 9 simulator test command.

Expected: all tests pass, including up/down, duplicate KVO, rapid separate changes, foreground/background race, stale socket generation, expiry, boundary, and exact action-ID cases.

- [ ] **Step 3: Run the existing relay/PWA suite unchanged**

Run:

```bash
cd relay
npm ci
npm test
```

Expected: the existing Node, relay, browser-parity, and PWA tests pass.

- [ ] **Step 4: Prove the fallback source was not edited**

Run:

```bash
git diff --exit-code origin/main -- relay/public
git diff --exit-code origin/main -- relay/test
git diff --exit-code origin/main -- .github
```

Expected: no diff in the PWA source/tests or the CI/CD owner's `.github/**` surface.

- [ ] **Step 5: Run static secret and forbidden-API scans**

Run:

```bash
rg -n "AVCaptureEventInteraction|onCameraCaptureEvent|AVCaptureSession|NSCameraUsageDescription" ios
rg -n "PHONE_TOKEN|token=.*wss|wss://[^ ]*[?&]token" ios --glob '!*.md'
```

Expected: the forbidden-camera scan returns no matches; the secret scan returns only user-facing labels or validation identifiers and no token value, URL query, or xcconfig secret.

- [ ] **Step 6: Commit any verification-driven correction**

If verification required an iOS correction, run the affected focused test first, then all Task 10 checks, then commit only that correction:

```bash
git add ios
git commit -m "fix(ios): satisfy native client verification"
```

If no correction was required, do not create an empty commit.

### Task 11: Update canonical documentation and record the hardware gate

**Files:**
- Modify: `FINAL-PLAN.md`
- Modify: `README.md`
- Create: `docs/ios-acceptance.md`
- Do not modify: `.github/**`, `relay/public/**`

**Interfaces:**
- Consumes: Verified implementation behavior and commands from Tasks 1–10.
- Produces: Accurate setup, limitations, CI path/scheme, simulator evidence, physical-device checklist, and OCI compatibility record.

- [ ] **Step 1: Write documentation assertions before editing prose**

Create a checklist at the top of the work notes and require every item to map to verified code/test evidence:

```text
[ ] ios/project.yml and ClickBridgePhone shared scheme
[ ] relay URL in UserDefaults and PHONE_TOKEN in Keychain
[ ] outputVolume KVO only; no camera API
[ ] active + transient inactive until background
[ ] one in flight; no queue; no retry; no cooldown
[ ] exact duplicate-value suppression and delta-based limitation
[ ] required states and boundary direction copy
[ ] external volume-source disclosure
[ ] haptic only after matching Mac action.result
[ ] Simulator limitation and physical iPhone gate
[ ] PWA unchanged sequential fallback
```

- [ ] **Step 2: Update `FINAL-PLAN.md` without creating a second canonical plan**

Repair any stale scope checklist that says no native mobile application exists. Link the approved design and this implementation plan, name `ios/project.yml` and scheme `ClickBridgePhone`, and state implementation/acceptance status from fresh evidence. Do not duplicate the full design.

- [ ] **Step 3: Update README setup and repository layout**

Add native iOS setup after the PWA fallback setup:

```bash
xcodegen generate --spec ios/project.yml
xcodebuildmcp simulator test \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone \
  --simulator-name "iPhone 16 Pro" \
  --use-latest-os
```

State that the user enters relay WSS URL and `PHONE_TOKEN` in app settings and uses either native or PWA, not simultaneous live phone connections.

- [ ] **Step 4: Create the physical acceptance and OCI compatibility record**

`docs/ios-acceptance.md` must contain dated result fields for device model, iOS version, signing method, relay hostname with token omitted, Mac version, OCI environment, test action IDs, observed status, and pass/fail. It must include the exact physical checklist from the approved design and explicitly say unexecuted rows remain `NOT RUN`, not passed.

- [ ] **Step 5: Verify every documented command surface**

Run:

```bash
xcodegen help generate
xcodebuildmcp simulator test --help
xcodebuildmcp device build-and-run --help
npm --prefix relay test
```

Expected: help commands recognize the documented flags and the existing relay suite passes.

- [ ] **Step 6: Commit documentation**

```bash
git add FINAL-PLAN.md README.md docs/ios-acceptance.md
git commit -m "docs: add native iPhone setup and acceptance gate"
```

### Task 12: Execute physical iPhone and live OCI acceptance

**Files:**
- Modify: `docs/ios-acceptance.md` with observed evidence only.

**Interfaces:**
- Consumes: Signed app, deployed existing OCI relay, running Mac client, Octo click target.
- Produces: Physical-volume acceptance evidence and protocol compatibility evidence; no protocol or deployment mutation.

- [ ] **Step 1: Discover the connected iPhone and configure XcodeBuildMCP defaults**

Run:

```bash
xcodebuildmcp device list --output json
xcodebuildmcp setup
```

In setup, select `ios/ClickBridgePhone.xcodeproj`, scheme `ClickBridgePhone`, and the connected signed iPhone shown by the device list. The selected device identifier is environment evidence and must be recorded in `docs/ios-acceptance.md`, not hard-coded in the repository.

- [ ] **Step 2: Build, install, and launch on the selected physical iPhone**

Run:

```bash
xcodebuildmcp device build-and-run \
  --project-path ios/ClickBridgePhone.xcodeproj \
  --scheme ClickBridgePhone
```

Expected: signed app installs and launches. If signing or device availability fails, record the exact failure and keep physical hardware acceptance `NOT RUN` or `BLOCKED`; do not promote Simulator evidence.

- [ ] **Step 3: Verify one up delta and one down delta end to end**

At a nonboundary volume, wait for `Ready`. Press Volume Up once, wait for the matching Mac terminal result and haptic, and verify the Octo counter increments exactly once. Repeat with Volume Down after the first action settles. Record each action ID and terminal status; never record the token.

- [ ] **Step 4: Verify deduplication, rapid changes, lifecycle, sources, and boundaries**

Run these physical scenarios and record observations:

```text
1. Duplicate callback noise: no second action for an unchanged observed value.
2. Rapid distinct changes after settlement: one distinct action ID per accepted delta.
3. Distinct change while pending: no second ID, no queued send after settlement.
4. Held key: record the real deltas observed; describe results as delta-based, not press-based.
5. Control Center: keep foreground session through inactive and verify a real change can trigger.
6. Background: verify changes send nothing; return active and wait for auth, Mac state, and five clock samples before Ready.
7. 0%: verify boundary copy, Volume Down undetectable, Volume Up detectable.
8. 100%: verify boundary copy, Volume Up undetectable, Volume Down detectable.
9. Wired/Bluetooth headset and AirPods when available: record that a system volume delta can trigger; mark unavailable hardware NOT RUN.
```

- [ ] **Step 5: Verify unchanged protocol against live OCI and PWA fallback**

Confirm native authentication, heartbeat, five time-sync responses, relay state, unchanged `action.request`, `relay.ack`, and `action.result` on the existing deployment. Background or disconnect native, launch the existing PWA, authenticate as the phone role, and complete one normal PWA click. Do not run both as simultaneous phone clients.

- [ ] **Step 6: Commit evidence**

```bash
git add docs/ios-acceptance.md
git commit -m "test(ios): record physical iPhone and OCI acceptance"
```

### Task 13: Review, open the PR, merge, and verify main/OCI compatibility

**Files:**
- Modify only for verified review findings: `ios/**`, `FINAL-PLAN.md`, `README.md`, `docs/ios-acceptance.md`
- Do not modify: `.github/**`, `relay/public/**`

**Interfaces:**
- Consumes: All passing local checks, physical acceptance evidence, separate CI lane using fixed path/scheme.
- Produces: Reviewed pull request, passing required checks, merged main, post-merge OCI/PWA/native smoke evidence.

- [ ] **Step 1: Run an independent requirements and code review**

Review against every Global Constraint and the design test matrix. Any finding must name file, line, violated contract, and reproducing test. Fix findings one at a time using failing-test-first, then rerun Tasks 10–12 as applicable.

- [ ] **Step 2: Confirm branch scope and clean worktree**

Run:

```bash
git status --short
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
```

Expected: only the iOS project, approved docs, generated Xcode project, and acceptance evidence are present; `.github/**` and PWA sources are absent.

- [ ] **Step 3: Push and open the PR with the fixed Apple CI contract**

Run:

```bash
git push --set-upstream origin codex/click-bridge-ios
gh pr create \
  --base main \
  --head codex/click-bridge-ios \
  --title "feat: add native iOS volume client" \
  --body "Adds the foreground SwiftUI iPhone client at ios/project.yml with shared scheme ClickBridgePhone. Reuses protocol v1, keeps one action in flight with no queue, preserves the PWA unchanged, and records Simulator plus physical-iPhone acceptance evidence."
```

- [ ] **Step 4: Wait for and inspect every required check**

Run:

```bash
gh pr checks --watch
gh pr view --comments
```

Expected: Apple CI discovers `ios/project.yml` and scheme `ClickBridgePhone`; all required checks pass; review comments are resolved with evidence.

- [ ] **Step 5: Merge only after review and acceptance are complete**

Run:

```bash
gh pr merge --squash --delete-branch
```

Expected: PR merges to `main`. Do not merge while the physical iPhone gate is unexecuted unless the PR and `FINAL-PLAN.md` explicitly label physical acceptance blocked and the user authorizes that exception.

- [ ] **Step 6: Verify merged main and live compatibility without deployment changes**

From a clean main checkout, regenerate and rerun the full iOS and relay/PWA test commands. Build the merged native app, authenticate it to the existing OCI relay, complete one up or down delta with a matching Mac result and Octo increment, disconnect it, and complete one PWA fallback click. Record the post-merge commit SHA and results in `docs/ios-acceptance.md`.

- [ ] **Step 7: Commit any post-merge evidence through a follow-up PR**

Do not push directly to protected `main`. If the evidence record needs a post-merge update, create a documentation-only branch and PR; do not edit `.github/**` or deployment secrets.

## Completion Criteria

Implementation is complete only when all of the following are true:

- `ios/project.yml` generates a buildable project with shared scheme `ClickBridgePhone`.
- All deterministic iOS tests pass on Simulator.
- Existing relay and PWA tests pass with no PWA source change.
- Exact duplicate callbacks, up/down, rapid separate deltas, pending-drop/no-queue, lifecycle race, stale socket generation, expiry, boundary behavior, and one action ID per accepted delta have explicit passing tests.
- Physical iPhone Volume Up and Volume Down each produce exactly one matching Mac terminal result, haptic, and Octo click from a ready nonboundary state.
- Background sends nothing; reactivation stays gated until fresh authentication, Mac state, and five-sample clock health complete.
- The live existing OCI relay accepts the unchanged protocol and the PWA reconnects as fallback after native disconnect.
- Documentation records the delta-based API limit, possible Control Center/headset/AirPods sources, boundary limit, Simulator limitation, and physical acceptance evidence.
- Review is resolved, required CI passes, the PR is merged, and post-merge compatibility is verified.
