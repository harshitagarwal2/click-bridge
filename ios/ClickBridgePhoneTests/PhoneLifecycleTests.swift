import SwiftUI
import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhoneLifecycleTests: XCTestCase {
    func testActiveInactiveBackgroundOwnsOneForegroundSession() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.inactive)
        XCTAssertEqual(harness.source.startCount, 0)
        XCTAssertEqual(harness.transport.configurations.count, 0)

        harness.model.scenePhaseChanged(.active)
        XCTAssertEqual(harness.source.startCount, 1)
        XCTAssertEqual(harness.transport.configurations.count, 1)
        harness.model.scenePhaseChanged(.inactive)
        harness.model.scenePhaseChanged(.active)
        XCTAssertEqual(harness.source.startCount, 1)
        XCTAssertEqual(harness.transport.configurations.count, 1)

        harness.model.scenePhaseChanged(.background)
        XCTAssertEqual(harness.source.stopCount, 2) // start resets once, background stops once
        XCTAssertEqual(harness.transport.disconnectReasons, ["background"])
        XCTAssertEqual(harness.model.state.primaryStatus, .notConnected)
    }

    func testLateVolumeCallbackAfterBackgroundCannotSend() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        let oldHandler = try XCTUnwrap(harness.source.handlers.last)
        harness.model.scenePhaseChanged(.background)
        oldHandler(0.75)
        XCTAssertTrue(harness.transport.sentMessages.isEmpty)
    }

    func testInvalidReplacementSettingsPreserveWorkingSession() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        harness.makeReady()
        let oldToken = try XCTUnwrap(harness.secret.value)
        let oldConfiguration = try XCTUnwrap(harness.transport.configurations.last)
        let replacementToken = String(repeating: "b", count: 64)

        XCTAssertThrowsError(try harness.model.saveSettings(
            urlString: "https://replacement.example/ws",
            token: replacementToken
        )) { error in
            XCTAssertEqual(error as? PhoneAppIssue, .invalidSettings)
        }

        XCTAssertEqual(harness.model.settings.relayURLString, "wss://relay.example/ws")
        XCTAssertEqual(harness.defaults.string(forKey: PhoneSettingsStore.relayURLKey),
                       "wss://relay.example/ws")
        XCTAssertEqual(harness.secret.value, oldToken)
        XCTAssertEqual(harness.transport.configurations, [oldConfiguration])
        XCTAssertEqual(harness.transport.disconnectReasons, [])
        XCTAssertEqual(harness.source.startCount, 1)
        XCTAssertEqual(harness.source.stopCount, 1)
        XCTAssertTrue(harness.model.state.foregroundSessionActive)
        XCTAssertEqual(harness.model.state.primaryStatus, .ready)
        XCTAssertNil(harness.model.state.issue)
    }

    func testSavingFirstValidTokenWhileActiveStartsForegroundSession() throws {
        let harness = try Harness(token: nil)
        harness.model.scenePhaseChanged(.active)
        XCTAssertTrue(harness.transport.configurations.isEmpty)
        XCTAssertEqual(harness.source.startCount, 0)

        try harness.model.saveSettings(urlString: "wss://new.example/ws",
                                       token: String(repeating: "b", count: 64))

        XCTAssertEqual(harness.transport.configurations.last?.url.absoluteString, "wss://new.example/ws")
        XCTAssertEqual(harness.source.startCount, 1)
        XCTAssertTrue(harness.model.state.foregroundSessionActive)
    }

    func testSavingValidReplacementRepairsAnInvalidPersistedURL() throws {
        let harness = try Harness(relayURL: "https://stale.example/ws")
        let replacementToken = String(repeating: "b", count: 64)

        try harness.model.saveSettings(urlString: "wss://new.example/ws",
                                       token: replacementToken)

        XCTAssertEqual(harness.model.settings.relayURLString, "wss://new.example/ws")
        XCTAssertEqual(harness.secret.value, replacementToken)
        XCTAssertNil(harness.model.state.issue)
    }

    func testSavingURLOnlyReusesExistingStoredToken() throws {
        let harness = try Harness()
        let existingToken = try XCTUnwrap(harness.secret.value)
        harness.model.scenePhaseChanged(.active)

        try harness.model.saveSettings(urlString: "wss://new.example/ws", token: "")

        XCTAssertEqual(harness.secret.value, existingToken)
        XCTAssertEqual(harness.model.settings.relayURLString, "wss://new.example/ws")
        XCTAssertEqual(harness.transport.configurations.last,
                       RelayConfiguration(url: try XCTUnwrap(URL(string: "wss://new.example/ws")),
                                          token: existingToken))
        XCTAssertEqual(harness.transport.disconnectReasons, ["settings_changed"])
        XCTAssertTrue(harness.model.state.foregroundSessionActive)
    }

    func testVolumeMonitoringFailureIsNotReportedAsInvalidSettings() throws {
        let harness = try Harness(startError: NSError(domain: "AVAudioSession", code: 1))

        harness.model.scenePhaseChanged(.active)

        XCTAssertEqual(harness.model.state.issue, .volumeMonitoringUnavailable)
        XCTAssertFalse(harness.model.state.foregroundSessionActive)
        XCTAssertEqual(harness.transport.disconnectReasons, ["volume_monitoring_unavailable"])
    }

    func testTransportDropAbandonsPendingSoRecoveryCanSendAgain() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        harness.makeReady()
        harness.source.emit(0.6)
        XCTAssertTrue(harness.actions.hasPendingAction)

        harness.transport.isAuthenticated = false
        harness.transport.emit(.connection(generation: harness.transport.generation, state: .backoff))
        XCTAssertFalse(harness.actions.hasPendingAction)

        harness.transport.isAuthenticated = true
        harness.transport.emit(.connection(generation: harness.transport.generation, state: .authenticated))
        harness.transport.emit(.message(generation: harness.transport.generation,
                                        value: .state(.init(macOnline: true, remoteEnabled: true, permission: .ready))))
        harness.model.applyClockHealth(.init(status: .healthy, offsetMilliseconds: 0, uncertaintyMilliseconds: 1))
        harness.source.emit(0.7)
        XCTAssertTrue(harness.actions.hasPendingAction)
    }

    func testPhoneTakeoverRemainsTerminalAcrossLifecycleUntilExplicitReconnect() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        let firstConnectionCount = harness.transport.configurations.count

        harness.transport.emit(.connection(generation: harness.transport.generation, state: .takenOver))

        XCTAssertEqual(harness.model.state.connection, .takenOver)
        XCTAssertEqual(harness.model.state.primaryStatus, .anotherPhoneTookOver)
        XCTAssertFalse(harness.model.canTriggerClick)

        harness.transport.emit(.connection(generation: harness.transport.generation,
                                           state: .authenticated))
        XCTAssertEqual(harness.model.state.connection, .takenOver)

        XCTAssertThrowsError(try harness.model.saveSettings(
            urlString: "https://replacement.example/ws",
            token: String(repeating: "b", count: 64)
        ))
        XCTAssertEqual(harness.model.state.connection, .takenOver)
        XCTAssertEqual(harness.transport.configurations.count, firstConnectionCount)

        harness.model.scenePhaseChanged(.background)
        harness.model.scenePhaseChanged(.active)
        XCTAssertEqual(harness.transport.configurations.count, firstConnectionCount)
        XCTAssertEqual(harness.model.state.connection, .takenOver)
        XCTAssertEqual(harness.model.state.primaryStatus, .anotherPhoneTookOver)

        harness.model.reconnectAfterTakeover()

        XCTAssertEqual(harness.transport.configurations.count, firstConnectionCount + 1)
        XCTAssertEqual(harness.model.state.connection, .disconnected)
        XCTAssertEqual(harness.model.state.primaryStatus, .notConnected)
    }

    func testValidSettingsClearTakeoverAndReconnectActivePhone() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        let firstConnectionCount = harness.transport.configurations.count
        harness.transport.emit(.connection(generation: harness.transport.generation,
                                           state: .takenOver))

        try harness.model.saveSettings(urlString: "wss://new.example/ws",
                                       token: String(repeating: "b", count: 64))

        XCTAssertFalse(harness.model.state.phoneTakenOver)
        XCTAssertEqual(harness.model.state.connection, .disconnected)
        XCTAssertEqual(harness.transport.configurations.count, firstConnectionCount + 1)
        XCTAssertEqual(harness.transport.configurations.last?.url.absoluteString,
                       "wss://new.example/ws")
    }

    func testFailedTokenWritePreservesTakeover() throws {
        let writeError = NSError(domain: String(repeating: "c", count: 64), code: 1)
        let harness = try Harness(writeError: writeError)
        harness.model.scenePhaseChanged(.active)
        let firstConnectionCount = harness.transport.configurations.count
        harness.transport.emit(.connection(generation: harness.transport.generation,
                                           state: .takenOver))

        XCTAssertThrowsError(try harness.model.saveSettings(
            urlString: "wss://new.example/ws",
            token: String(repeating: "b", count: 64)
        ))

        XCTAssertTrue(harness.model.state.phoneTakenOver)
        XCTAssertEqual(harness.model.state.connection, .takenOver)
        XCTAssertEqual(harness.transport.configurations.count, firstConnectionCount)
        XCTAssertEqual(harness.transport.disconnectReasons, [])
    }

    func testOnScreenClickUsesCurrentReadinessWithoutChangingVolumeObservation() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        XCTAssertFalse(harness.model.canTriggerClick)

        harness.makeReady()
        XCTAssertTrue(harness.model.canTriggerClick)
        XCTAssertEqual(harness.model.triggerClick(), .sent(actionID: harness.actionID))

        XCTAssertEqual(harness.transport.sentMessages.compactMap(\.actionID), [harness.actionID])
        XCTAssertEqual(harness.source.startCount, 1)
        XCTAssertEqual(harness.source.stopCount, 1) // foreground start resets the observer once
        XCTAssertFalse(harness.model.canTriggerClick)
    }

    func testIntentRequestIsDiscardedAfterEveryUnacceptedAttempt() {
        for disposition in [ActionDisposition.ignoredNotReady, .ignoredPending, .sendFailed] {
            let subject = PhoneClickIntentRouter()
            var deliveries = 0
            subject.installHandler {
                deliveries += 1
                return disposition
            }

            subject.requestClick()
            XCTAssertTrue(subject.hasPendingRequest)
            XCTAssertEqual(deliveries, 0)

            subject.setAppActive(true)
            XCTAssertFalse(subject.hasPendingRequest)
            XCTAssertEqual(deliveries, 1)

            subject.setAppActive(false)
            subject.setAppActive(true)
            XCTAssertEqual(deliveries, 1)
            XCTAssertFalse(subject.hasPendingRequest)
        }
    }

    func testMultipleInactiveIntentRequestsCollapseIntoOneAttempt() {
        let subject = PhoneClickIntentRouter()
        var deliveries = 0
        subject.installHandler {
            deliveries += 1
            return .ignoredPending
        }

        subject.requestClick()
        subject.requestClick()
        subject.requestClick()
        subject.setAppActive(true)

        XCTAssertEqual(deliveries, 1)
        XCTAssertFalse(subject.hasPendingRequest)
    }

    func testActiveIntentRequestDeliversWhenHandlerIsInstalled() {
        let subject = PhoneClickIntentRouter()
        subject.setAppActive(true)
        subject.requestClick()
        var deliveries = 0

        subject.installHandler {
            deliveries += 1
            return .sent(actionID: UUID())
        }

        XCTAssertEqual(deliveries, 1)
        XCTAssertFalse(subject.hasPendingRequest)
    }

    func testIntentDeliveryDoesNotRetainAReentrantRequest() {
        let subject = PhoneClickIntentRouter()
        var deliveries = 0
        subject.installHandler {
            deliveries += 1
            subject.requestClick()
            return .ignoredNotReady
        }
        subject.setAppActive(true)

        subject.requestClick()

        XCTAssertEqual(deliveries, 1)
        XCTAssertFalse(subject.hasPendingRequest)
    }

    func testIntentRequestWaitsWhileSceneIsInactive() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        harness.makeReady()
        harness.model.scenePhaseChanged(.inactive)

        harness.intentRouter.requestClick()
        XCTAssertTrue(harness.intentRouter.hasPendingRequest)
        XCTAssertTrue(harness.transport.sentMessages.filter {
            if case .actionRequest = $0 { return true }
            return false
        }.isEmpty)

        harness.model.scenePhaseChanged(.active)
        XCTAssertFalse(harness.intentRouter.hasPendingRequest)
        XCTAssertEqual(harness.transport.sentMessages.compactMap(\.actionID), [harness.actionID])
    }

    func testColdLaunchIntentIsNotRetriedAfterActiveAttemptWasNotReady() throws {
        let harness = try Harness()
        harness.intentRouter.requestClick()

        harness.model.scenePhaseChanged(.active)
        XCTAssertFalse(harness.intentRouter.hasPendingRequest)
        XCTAssertTrue(harness.transport.sentMessages.compactMap(\.actionID).isEmpty)

        harness.makeReady()

        XCTAssertFalse(harness.intentRouter.hasPendingRequest)
        XCTAssertTrue(harness.transport.sentMessages.compactMap(\.actionID).isEmpty)

        harness.model.applyClockHealth(.init(status: .healthy, offsetMilliseconds: 0,
                                             uncertaintyMilliseconds: 1))
        XCTAssertTrue(harness.transport.sentMessages.compactMap(\.actionID).isEmpty)
    }

    func testBackgroundDiscardsAnInactiveIntentRequest() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.inactive)
        harness.intentRouter.requestClick()
        XCTAssertTrue(harness.intentRouter.hasPendingRequest)

        harness.model.scenePhaseChanged(.background)
        harness.model.scenePhaseChanged(.active)
        harness.makeReady()

        XCTAssertFalse(harness.intentRouter.hasPendingRequest)
        XCTAssertTrue(harness.transport.sentMessages.compactMap(\.actionID).isEmpty)
    }

    func testClockCheckWaitsForMacReadyAndRestartsAfterOfflineTransition() throws {
        let harness = try Harness()
        harness.model.scenePhaseChanged(.active)
        harness.transport.isAuthenticated = true
        harness.transport.emit(.connection(generation: harness.transport.generation, state: .authenticated))
        XCTAssertTrue(harness.transport.sentMessages.isEmpty)

        harness.transport.emit(.message(generation: harness.transport.generation,
                                        value: .state(.init(macOnline: true, remoteEnabled: true, permission: .ready))))
        XCTAssertEqual(harness.timeSyncRequestCount, 1)

        harness.transport.emit(.message(generation: harness.transport.generation,
                                        value: .state(.init(macOnline: false, remoteEnabled: false, permission: .unknown))))
        XCTAssertEqual(harness.model.state.clock.status, .unchecked)

        harness.transport.emit(.message(generation: harness.transport.generation,
                                        value: .state(.init(macOnline: true, remoteEnabled: true, permission: .ready))))
        XCTAssertEqual(harness.timeSyncRequestCount, 2)
    }

    func testFailedTokenWritePreservesExistingURLTokenAndSession() throws {
        let writeError = NSError(domain: String(repeating: "c", count: 64), code: 1)
        let harness = try Harness(writeError: writeError)
        harness.model.scenePhaseChanged(.active)
        let oldToken = try XCTUnwrap(harness.secret.value)

        XCTAssertThrowsError(try harness.model.saveSettings(urlString: "wss://new.example/ws",
                                                            token: String(repeating: "b", count: 64)))

        XCTAssertEqual(harness.model.settings.relayURLString, "wss://relay.example/ws")
        XCTAssertEqual(harness.defaults.string(forKey: PhoneSettingsStore.relayURLKey), "wss://relay.example/ws")
        XCTAssertEqual(harness.secret.value, oldToken)
        XCTAssertEqual(harness.transport.disconnectReasons, [])
        XCTAssertTrue(harness.model.state.foregroundSessionActive)
    }

    @MainActor
    private struct Harness {
        let source: FakeVolumeChangeSource
        let transport: FakePhoneActionTransport
        let actions: PhoneActionCoordinator
        let actionID: UUID
        let intentRouter: PhoneClickIntentRouter
        let defaults: UserDefaults
        let secret: LifecycleSecretStore
        let model: PhoneAppModel

        init(token: String? = String(repeating: "a", count: 64),
             relayURL: String = "wss://relay.example/ws",
             writeError: Error? = nil,
             startError: Error? = nil) throws {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            defaults.set(relayURL, forKey: PhoneSettingsStore.relayURLKey)
            let secret = LifecycleSecretStore(value: token, writeError: writeError)
            let settings = try PhoneSettingsStore(defaults: defaults, secrets: secret)
            let source = FakeVolumeChangeSource(volume: 0.5)
            source.startError = startError
            let transport = FakePhoneActionTransport()
            let scheduler = FakePhoneScheduler()
            let clock = FakePhoneClock()
            let actionID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!
            let intentRouter = PhoneClickIntentRouter()
            let actions = PhoneActionCoordinator(transport: transport, clock: clock,
                                                 scheduler: scheduler,
                                                 haptics: FakePhoneHaptics(),
                                                 makeActionID: { actionID }) { _ in }
            let clockHealth = PhoneClockHealthController(clock: clock, scheduler: scheduler,
                                                        isActionPending: { actions.hasPendingAction }) { _ in }
            self.source = source
            self.transport = transport
            self.actions = actions
            self.actionID = actionID
            self.intentRouter = intentRouter
            self.defaults = defaults
            self.secret = secret
            model = PhoneAppModel(settings: settings,
                                  volumeController: VolumeDeltaController(source: source),
                                  transport: transport,
                                  clockHealth: clockHealth,
                                  actions: actions,
                                  intentRouter: intentRouter)
        }

        var timeSyncRequestCount: Int {
            transport.sentMessages.filter {
                if case .timeSyncRequest = $0 { return true }
                return false
            }.count
        }

        func makeReady() {
            transport.isAuthenticated = true
            transport.emit(.connection(generation: transport.generation, state: .authenticated))
            transport.emit(.message(generation: transport.generation,
                                    value: .state(.init(macOnline: true, remoteEnabled: true, permission: .ready))))
            model.applyClockHealth(.init(status: .healthy, offsetMilliseconds: 0, uncertaintyMilliseconds: 1))
        }
    }
}

private final class LifecycleSecretStore: SecretStoring, @unchecked Sendable {
    var value: String?
    let writeError: Error?
    init(value: String?, writeError: Error? = nil) {
        self.value = value
        self.writeError = writeError
    }
    func read(account: String) throws -> String? { value }
    func write(_ value: String, account: String) throws {
        if let writeError { throw writeError }
        self.value = value
    }
    func delete(account: String) throws { value = nil }
}
