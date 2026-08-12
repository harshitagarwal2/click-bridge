import XCTest
import AppKit
import Combine
@testable import ClickBridgeMac

private enum AppStateTestError: Error { case deleteFailed }

private final class AppStateSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var readError: Error?
    private let deleteError: Error?
    private let writeError: Error?

    init(token: String? = nil, readError: Error? = nil,
         deleteError: Error? = nil, writeError: Error? = nil) {
        self.token = token
        self.readError = readError
        self.deleteError = deleteError
        self.writeError = writeError
    }

    func read(account: String) throws -> String? {
        try lock.withLock {
            if let readError { throw readError }
            return token
        }
    }
    func setReadError(_ error: Error?) { lock.withLock { readError = error } }
    func write(_ value: String, account: String) throws {
        if let writeError { throw writeError }
        lock.withLock { token = value }
    }
    func delete(account: String) throws {
        if let deleteError { throw deleteError }
        lock.withLock { token = nil }
    }
}

private final class AppStateTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [AppStateTransport]
    private var makeCount = 0

    init(_ transports: [AppStateTransport]) { self.transports = transports }

    func make() -> any WebSocketTransport {
        lock.withLock {
            makeCount += 1
            return transports.removeFirst()
        }
    }

    func count() -> Int { lock.withLock { makeCount } }
}

private actor AppStateTransport: WebSocketTransport {
    private var inbound: [String] = []
    private var inboundContinuation: CheckedContinuation<String, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var pairingSendContinuations: [CheckedContinuation<Void, Error>] = []
    private var helloWaiters: [(String, CheckedContinuation<Void, Never>)] = []
    private let gateClose: Bool
    private let gatePairingStatus: Bool
    private(set) var closeCount = 0
    private(set) var closeStarted = false
    private(set) var sent: [String] = []

    init(gateClose: Bool, gatePairingStatus: Bool = false) {
        self.gateClose = gateClose
        self.gatePairingStatus = gatePairingStatus
    }

    func connect(to url: URL) async throws {}
    func sendText(_ text: String) async throws {
        sent.append(text)
        if gatePairingStatus,
           case .pairStatusRequest = try? StrictWireDecoder().decodeText(text) {
            try await withCheckedThrowingContinuation { pairingSendContinuations.append($0) }
            return
        }
        guard let token = (try? JSONDecoder().decode(Hello.self, from: Data(text.utf8)))?.token else { return }
        let ready = helloWaiters.filter { $0.0 == token }
        helloWaiters.removeAll { $0.0 == token }
        ready.forEach { $0.1.resume() }
    }
    func receiveText() async throws -> String {
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { inboundContinuation = $0 }
    }
    func push(_ text: String) {
        if let inboundContinuation {
            self.inboundContinuation = nil
            inboundContinuation.resume(returning: text)
        } else {
            inbound.append(text)
        }
    }
    func close() async {
        closeCount += 1
        closeStarted = true
        if gateClose {
            await withCheckedContinuation { closeContinuation = $0 }
        }
        inboundContinuation?.resume(throwing: AppStateTestError.deleteFailed)
        inboundContinuation = nil
    }
    func releaseClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }
    func closes() -> Int { closeCount }
    func didStartClose() -> Bool { closeStarted }
    func pairingSendCount() -> Int { pairingSendContinuations.count }
    func completePairingSend(at index: Int) { pairingSendContinuations[index].resume() }
    func sentMessages() -> [String] { sent }
    func containsHello(token: String) -> Bool {
        sent.contains { (try? JSONDecoder().decode(Hello.self, from: Data($0.utf8)))?.token == token }
    }
    func waitForHello(token: String) async {
        if containsHello(token: token) { return }
        await withCheckedContinuation { helloWaiters.append((token, $0)) }
    }
}

private actor AppStateCompletionFlag {
    private var completed = false
    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

private final class AppStateCountingPoster: InputPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        lock.withLock { count += 1 }
        return .posted(mouseDownUnixMs: 1_786_497_600_010)
    }

    func diagnosticPostCounts() -> InputPostCounts {
        lock.withLock { InputPostCounts(mouseDownPostCount: count, mouseUpPostCount: count) }
    }

    func postCount() -> Int { lock.withLock { count } }
}

private actor AppStateForwardingGatedSink: ActionRequestSink {
    private let processor: ActionProcessor
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var receiveStarted = false
    private(set) var results: [ActionResult] = []

    init(processor: ActionProcessor) { self.processor = processor }

    func activateAuthorizationLease(
        for generation: ActionAuthorizationGeneration
    ) async -> ActionAuthorizationLease {
        await processor.activateAuthorizationLease(for: generation)
    }

    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) async {
        await processor.revokeAuthorizationLease(lease)
    }

    func receive(
        _ request: ActionRequest,
        via ingress: ActionIngress,
        authorization: ActionAuthorizationLease
    ) async -> ActionResult {
        receiveStarted = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        let result = await processor.receive(request, via: ingress, authorization: authorization)
        results.append(result)
        return result
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class MutablePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.withLock { value } }
    func set(_ next: Bool) { lock.withLock { value = next } }
}

@MainActor
final class AppStateTests: XCTestCase {
    private func eventually(
        timeout: TimeInterval = 1,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testApplicationActivationRefreshesPermissionWithoutPrompting() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore())
        let permissionValue = MutablePermission(false)
        let permission = PostEventPermissionService(preflight: { permissionValue.read() }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let client = RelayClient(actionSink: processor, diagnostics: processor)
        let notifications = NotificationCenter()
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: notifications)
        XCTAssertEqual(state.permission, .required)

        permissionValue.set(true)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 where state.permission != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.permission, .ready)
    }

    func testAuthenticatedConnectionExplicitlyRequestsPairingStatusAndPublishesReplacementAction() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://relay.example/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "stored-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await transport.waitForHello(token: "stored-token")
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let requestedStatus = await eventually {
            await transport.sentMessages().contains {
                if case .pairStatusRequest = try? StrictWireDecoder().decodeText($0) { return true }
                return false
            }
        }
        XCTAssertTrue(requestedStatus)
        let sentMessages = await transport.sentMessages()
        let statusRequestIDs: [String] = sentMessages.compactMap {
            guard case .pairStatusRequest(let request) = try? StrictWireDecoder().decodeText($0) else { return nil }
            return request.requestId
        }
        let requestID = try XCTUnwrap(statusRequestIDs.first)

        await transport.push(try Wire.encode(PairStatus(requestId: requestID,
                                                        enrollmentState: .legacy,
                                                        activePhoneCredentialVersion: 0)))
        let pairingReady = await eventually { state.pairing?.state == .ready }
        XCTAssertTrue(pairingReady)
        XCTAssertEqual(state.pairingAction.title, "Replace Phone")
        XCTAssertTrue(state.pairingAction.requiresReplacementConfirmation)
        await client.stop()
    }

    func testRapidReconnectKeepsLatestPairingStatusRefreshAndIgnoresStaleCompletion() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "stored-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false, gatePairingStatus: true)
        let client = RelayClient(
            actionSink: processor,
            diagnostics: processor,
            makeTransport: { transport },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }
        )
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await transport.waitForHello(token: "stored-token")
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let firstRefreshStarted = await eventually { await transport.pairingSendCount() == 1 }
        XCTAssertTrue(firstRefreshStarted)
        await transport.completePairingSend(at: 0)

        let staleCompletion = AppStateCompletionFlag()
        let staleRefresh = Task {
            await state.handleStatusEvent(.init(status: .connected, credentialRevision: 1, sequence: 100))
            await staleCompletion.markCompleted()
        }
        let staleRefreshStarted = await eventually { await transport.pairingSendCount() == 2 }
        let staleRefreshCompletedEarly = await staleCompletion.value()
        XCTAssertTrue(staleRefreshStarted)
        XCTAssertFalse(staleRefreshCompletedEarly)

        await state.handleStatusEvent(.init(status: .disconnected, credentialRevision: 1, sequence: 101))
        let latestRefresh = Task {
            await state.handleStatusEvent(.init(status: .connected, credentialRevision: 1, sequence: 102))
        }
        let latestRefreshStarted = await eventually { await transport.pairingSendCount() == 3 }
        XCTAssertTrue(latestRefreshStarted)

        await transport.completePairingSend(at: 1)
        await staleRefresh.value
        await transport.completePairingSend(at: 2)
        await latestRefresh.value
        let latestStatusWon = await eventually {
            state.connection == .connected && state.pairing?.state == .checkingStatus
        }
        let refreshCount = await transport.pairingSendCount()
        XCTAssertTrue(latestStatusWon)
        XCTAssertEqual(refreshCount, 3)
        await client.stop()
    }

    func testInvalidRelayURLDoesNotRequireResavingPersistedTokenBeforeReconnect() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "stored-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await state.reconnect().value

        let invalidStatus = await client.currentStatus()
        XCTAssertEqual(factory.count(), 0)
        XCTAssertEqual(invalidStatus, .disconnected)
        XCTAssertEqual(try settings.macToken(), "stored-token")
        XCTAssertNotNil(state.notice)

        settings.relayURLString = "wss://example.com/ws"
        await state.reconnect().value

        XCTAssertEqual(factory.count(), 1)
        guard factory.count() == 1 else { return }
        await transport.waitForHello(token: "stored-token")
        let sentStoredToken = await transport.containsHello(token: "stored-token")
        XCTAssertTrue(sentStoredToken)
    }

    func testTokenReadFailureRemainsIneligibleAfterStorageRecovers() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "stored-token")
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.setReadError(AppStateTestError.deleteFailed)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let factory = AppStateTransportFactory([AppStateTransport(gateClose: false)])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await state.reconnect().value
        secrets.setReadError(nil)
        await state.reconnect().value

        XCTAssertEqual(factory.count(), 0)
        XCTAssertNotNil(settings.storageError)
    }

    func testClearRetagsDisconnectedStatusForCurrentCredentialRevision() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "stored-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let firstTransport = AppStateTransport(gateClose: false)
        let secondTransport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([firstTransport, secondTransport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await firstTransport.waitForHello(token: "stored-token")
        await state.reconnect().value
        await secondTransport.waitForHello(token: "stored-token")
        let appConnecting = await eventually { state.connection == .connecting }
        XCTAssertTrue(appConnecting)

        await Task.detached {
            _ = await client.clearConfigurationAndStop(credentialRevision: 2)
        }.value

        let disconnected = expectation(description: "current credential revision reports disconnected")
        let observation = state.$connection.dropFirst().sink {
            if $0 == .disconnected { disconnected.fulfill() }
        }
        await state.clearToken().value
        await fulfillment(of: [disconnected], timeout: 1)
        _ = observation

        let relayStatus = await client.currentStatus()
        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertEqual(relayStatus, .disconnected)
    }

    func testClearTokenReportsSuccessOnlyAfterPersistedAndLiveRevocation() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "token")
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: true)
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let connecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(connecting)

        state.clearToken()

        let closeStarted = await eventually { await transport.didStartClose() }
        XCTAssertTrue(closeStarted)
        XCTAssertNotEqual(state.notice, "Token cleared.")
        await transport.releaseClose()
        let successReported = await eventually { state.notice == "Token cleared." }
        let clearedStatus = await client.currentStatus()
        let closeCount = await transport.closes()
        XCTAssertTrue(successReported)
        XCTAssertFalse(settings.hasToken)
        XCTAssertEqual(clearedStatus, .disconnected)
        XCTAssertEqual(closeCount, 1)
    }

    func testClearTokenDeletionFailureRevokesLiveCredentialAndReportsError() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "token", deleteError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let connecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(connecting)

        state.clearToken()

        let closed = await eventually { await transport.closes() == 1 }
        let errorReported = await eventually { state.notice == settings.storageError }
        let clearedStatus = await client.currentStatus()
        XCTAssertTrue(closed)
        XCTAssertTrue(errorReported)
        XCTAssertNotEqual(state.notice, "Token cleared.")
        XCTAssertTrue(settings.hasToken)
        XCTAssertEqual(clearedStatus, .disconnected)

        await state.reconnect().value
        let closeCountAfterReconnect = await transport.closes()
        XCTAssertEqual(closeCountAfterReconnect, 1)

        let save = state.saveToken("replacement-token")
        await save.value
        let restarted = await eventually { await transport.containsHello(token: "replacement-token") }
        XCTAssertTrue(restarted)
    }

    func testClearTokenDeletionFailureRevokesAuthenticatedForwardedAction() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        defaults.set(true, forKey: SettingsStore.remoteEnabledKey)
        let secrets = AppStateSecretStore(token: "token", deleteError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { true }, request: { true })
        let poster = AppStateCountingPoster()
        let processor = ActionProcessor(poster: poster, permission: permission)
        let sink = AppStateForwardingGatedSink(processor: processor)
        let transport = AppStateTransport(gateClose: false)
        let client = RelayClient(actionSink: sink, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let helloSent = await eventually { await transport.containsHello(token: "token") }
        XCTAssertTrue(helloSent)
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let connected = await eventually { await client.currentStatus() == .connected }
        XCTAssertTrue(connected)
        let now = Date().timeIntervalSince1970 * 1_000
        await transport.push(try Wire.encode(ActionRequest(actionId: "018f63f5-6f3d-7d21-88bc-111111111111",
                                                           action: "click",
                                                           issuedAtUnixMs: now,
                                                           expiresAtUnixMs: now + Constants.actionLifetimeMs)))
        let forwarded = await eventually { await sink.receiveStarted }
        XCTAssertTrue(forwarded)

        await state.clearToken().value
        await sink.release()
        let completed = await eventually { await sink.results.count == 1 }
        guard completed else { return XCTFail("forwarded action did not complete after release") }
        let result = await sink.results[0]
        let status = await client.currentStatus()
        let closeCount = await transport.closes()

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(poster.postCount(), 0)
        XCTAssertEqual(status, .disconnected)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(state.notice, settings.storageError)
        XCTAssertTrue(settings.hasToken)

        await state.saveToken("replacement-token").value
        let replacementHelloSent = await eventually {
            await transport.containsHello(token: "replacement-token")
        }
        XCTAssertTrue(replacementHelloSent)
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let replacementConnected = await eventually { await client.currentStatus() == .connected }
        XCTAssertTrue(replacementConnected)
        let replacementNow = Date().timeIntervalSince1970 * 1_000
        await transport.push(try Wire.encode(ActionRequest(actionId: "018f63f5-6f3d-7d21-88bc-222222222222",
                                                           action: "click",
                                                           issuedAtUnixMs: replacementNow,
                                                           expiresAtUnixMs: replacementNow
                                                               + Constants.actionLifetimeMs)))
        let replacementPosted = await eventually { poster.postCount() == 1 }
        XCTAssertTrue(replacementPosted)
        XCTAssertEqual(state.notice, "Token saved.")
    }

    func testNewerSaveSupersedesClearSuspendedWhileClosingOldTransport() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "old-token")
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let oldTransport = AppStateTransport(gateClose: true)
        let newTransport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([oldTransport, newTransport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let initiallyConnecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(initiallyConnecting)

        let clear = state.clearToken()
        let clearSuspended = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(clearSuspended)
        let save = state.saveToken("new-token")
        let replacementStarted = await eventually { factory.count() == 2 }
        XCTAssertTrue(replacementStarted)

        await oldTransport.releaseClose()
        await clear.value
        await save.value

        let newHelloSent = await eventually {
            await newTransport.containsHello(token: "new-token")
        }
        XCTAssertEqual(state.notice, "Token saved.")
        XCTAssertEqual(try settings.macToken(), "new-token")
        let status = await client.currentStatus()
        XCTAssertEqual(status, .connecting)
        XCTAssertEqual(state.connection, .connecting)
        XCTAssertEqual(factory.count(), 2)
        XCTAssertTrue(newHelloSent)
    }

    func testSameTurnClearThenSavePreservesNewTokenAndStartsOnlyNewCredential() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "old-token")
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        let clear = state.clearToken()
        let save = state.saveToken("new-token")
        await clear.value
        await save.value

        let newHelloSent = await eventually {
            await transport.containsHello(token: "new-token")
        }
        XCTAssertEqual(try settings.macToken(), "new-token")
        XCTAssertEqual(factory.count(), 1)
        XCTAssertTrue(newHelloSent)
        XCTAssertEqual(state.notice, "Token saved.")
    }

    func testClearDuringDelayedBootstrapBlocksOldTokenEvenWhenDeletionFailsUntilSave() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "old-token", deleteError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await state.clearToken().value
        await state.reconnect().value

        XCTAssertEqual(factory.count(), 0)
        XCTAssertEqual(try settings.macToken(), "old-token")
        XCTAssertEqual(state.notice, settings.storageError)

        await state.saveToken("new-token").value
        let newHelloSent = await eventually {
            await transport.containsHello(token: "new-token")
        }
        XCTAssertEqual(factory.count(), 1)
        XCTAssertTrue(newHelloSent)
        XCTAssertEqual(state.notice, "Token saved.")
    }

    func testIneligibleReconnectCannotCancelClearSuspendedWhileClosing() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "old-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: true)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let initiallyConnecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(initiallyConnecting)

        let clear = state.clearToken()
        let closeStarted = await eventually { await transport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let reconnect = state.reconnect()
        await reconnect.value
        await transport.releaseClose()
        await clear.value

        let appDisconnected = await eventually { state.connection == .disconnected }
        let relayStatus = await client.currentStatus()
        XCTAssertTrue(appDisconnected)
        XCTAssertEqual(relayStatus, .disconnected)
        XCTAssertEqual(factory.count(), 1)
        let closeCount = await transport.closes()
        XCTAssertEqual(closeCount, 1)
        XCTAssertNil(try settings.macToken())
    }

    func testFailedSaveCannotCancelClearSuspendedWhileClosing() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: "old-token", writeError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: true)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let initiallyConnecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(initiallyConnecting)

        let clear = state.clearToken()
        let closeStarted = await eventually { await transport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let failedSave = state.saveToken("new-token")
        await failedSave.value
        await transport.releaseClose()
        await clear.value

        let appDisconnected = await eventually { state.connection == .disconnected }
        let relayStatus = await client.currentStatus()
        XCTAssertTrue(appDisconnected)
        XCTAssertEqual(relayStatus, .disconnected)
        XCTAssertEqual(factory.count(), 1)
        let closeCount = await transport.closes()
        XCTAssertEqual(closeCount, 1)
        XCTAssertNil(try settings.macToken())
        XCTAssertEqual(state.notice, settings.storageError)
    }

    func testClearSupersedesReconnectSuspendedWhileClosingWithoutOrphanTransport() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: "old-token"))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: true)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let initiallyConnecting = await eventually { await client.currentStatus() == .connecting }
        XCTAssertTrue(initiallyConnecting)

        let reconnect = state.reconnect()
        let closeStarted = await eventually { await transport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let clear = state.clearToken()
        await clear.value
        await transport.releaseClose()
        await reconnect.value

        let appDisconnected = await eventually { state.connection == .disconnected }
        let relayStatus = await client.currentStatus()
        XCTAssertTrue(appDisconnected)
        XCTAssertEqual(relayStatus, .disconnected)
        XCTAssertEqual(factory.count(), 1)
        XCTAssertNil(try settings.macToken())
        XCTAssertEqual(state.notice, "Token cleared.")
    }

    func testSameTurnSaveUsesOnlyNewestToken() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore())
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        let saveA = state.saveToken("token-a")
        let saveB = state.saveToken("token-b")
        await saveA.value
        await saveB.value

        let helloB = await eventually {
            await transport.containsHello(token: "token-b")
        }
        let helloA = await transport.containsHello(token: "token-a")
        XCTAssertTrue(helloB)
        XCTAssertFalse(helloA)
        XCTAssertEqual(try settings.macToken(), "token-b")
        XCTAssertEqual(factory.count(), 1)
        XCTAssertEqual(state.notice, "Token saved.")
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
