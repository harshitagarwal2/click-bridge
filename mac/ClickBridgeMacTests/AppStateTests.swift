import XCTest
import AppKit
import Combine
@testable import ClickBridgeMac

private enum AppStateTestError: Error { case deleteFailed }

private enum AppStateTestToken {
    static let stored = String(repeating: "a", count: 64)
    static let replacement = String(repeating: "b", count: 64)
    static let alternate = String(repeating: "c", count: 64)
}

private enum AppStateSecretAccount {
    static let connection = "connection.v1"
    static let legacyToken = "macToken"
}

private final class AppStateSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readError: Error?
    private var deleteError: Error?
    private var writeError: Error?
    private var readCounts: [String: Int] = [:]
    private var writeCounts: [String: Int] = [:]
    private var deleteCounts: [String: Int] = [:]

    init(token: String? = nil, readError: Error? = nil,
         deleteError: Error? = nil, writeError: Error? = nil) {
        if let token {
            values = [AppStateSecretAccount.legacyToken: token]
        } else {
            values = [:]
        }
        self.readError = readError
        self.deleteError = deleteError
        self.writeError = writeError
    }

    func read(account: String) throws -> String? {
        try lock.withLock {
            readCounts[account, default: 0] += 1
            if let readError { throw readError }
            return values[account]
        }
    }
    func setReadError(_ error: Error?) { lock.withLock { readError = error } }
    func setWriteError(_ error: Error?) { lock.withLock { writeError = error } }
    func write(_ value: String, account: String) throws {
        try lock.withLock {
            writeCounts[account, default: 0] += 1
            if let writeError { throw writeError }
            values[account] = value
        }
    }
    func delete(account: String) throws {
        try lock.withLock {
            deleteCounts[account, default: 0] += 1
            if let deleteError { throw deleteError }
            values[account] = nil
        }
    }

    func value(account: String) -> String? { lock.withLock { values[account] } }
    func reads(account: String) -> Int { lock.withLock { readCounts[account, default: 0] } }
    func writes(account: String) -> Int { lock.withLock { writeCounts[account, default: 0] } }
    func deletes(account: String) -> Int { lock.withLock { deleteCounts[account, default: 0] } }

    func storedConnection() -> StoredConnection? {
        lock.withLock {
            guard let encoded = values[AppStateSecretAccount.connection] else { return nil }
            return try? JSONDecoder().decode(StoredConnection.self, from: Data(encoded.utf8))
        }
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
    private var cancelSendContinuation: CheckedContinuation<Void, Error>?
    private let gateClose: Bool
    private let gatePairingStatus: Bool
    private let gatePairingCancel: Bool
    private let failPairingCancel: Bool
    private let connectError: Error?
    private(set) var closeCount = 0
    private(set) var closeStarted = false
    private(set) var sent: [String] = []
    private(set) var connectedURLs: [URL] = []

    init(
        gateClose: Bool,
        gatePairingStatus: Bool = false,
        gatePairingCancel: Bool = false,
        failPairingCancel: Bool = false,
        connectError: Error? = nil
    ) {
        self.gateClose = gateClose
        self.gatePairingStatus = gatePairingStatus
        self.gatePairingCancel = gatePairingCancel
        self.failPairingCancel = failPairingCancel
        self.connectError = connectError
    }

    func connect(to url: URL) async throws {
        connectedURLs.append(url)
        if let connectError { throw connectError }
    }
    func sendText(_ text: String) async throws {
        sent.append(text)
        if let message = try? StrictWireDecoder().decodeText(text) {
            if gatePairingStatus, case .pairStatusRequest = message {
                try await withCheckedThrowingContinuation { pairingSendContinuations.append($0) }
                return
            }
            if case .pairCancel = message {
                if failPairingCancel { throw AppStateTestError.deleteFailed }
                if gatePairingCancel {
                    try await withCheckedThrowingContinuation { cancelSendContinuation = $0 }
                    return
                }
            }
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
    func releasePairingCancel() {
        cancelSendContinuation?.resume()
        cancelSendContinuation = nil
    }
    func sentMessages() -> [String] { sent }
    func urls() -> [URL] { connectedURLs }
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
private struct AppStateHarness {
    let suite: String
    let defaults: UserDefaults
    let secrets: AppStateSecretStore
    let settings: SettingsStore
    let client: RelayClient
    let state: AppState
    let factory: AppStateTransportFactory

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
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

    private func makeHarness(
        connection: StoredConnection? = nil,
        secrets: AppStateSecretStore = AppStateSecretStore(),
        transports: [AppStateTransport]
    ) throws -> AppStateHarness {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        if let connection { try settings.saveConnection(connection) }
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let factory = AppStateTransportFactory(transports)
        let client = RelayClient(
            actionSink: processor,
            diagnostics: processor,
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }
        )
        let state = AppState(
            settings: settings,
            client: client,
            processor: processor,
            permissionService: permission,
            activationNotifications: NotificationCenter()
        )
        return AppStateHarness(
            suite: suite,
            defaults: defaults,
            secrets: secrets,
            settings: settings,
            client: client,
            state: state,
            factory: factory
        )
    }

    private func connection(
        url: String = "wss://old.example.com/ws",
        token: String = AppStateTestToken.stored
    ) -> StoredConnection {
        StoredConnection(version: StoredConnection.currentVersion, relayURLString: url, macToken: token)
    }

    private func makePairingReady(
        in harness: AppStateHarness,
        transport: AppStateTransport,
        token: String = AppStateTestToken.stored
    ) async throws -> PairingController {
        await transport.waitForHello(token: token)
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let requestedStatus = await eventually {
            await transport.sentMessages().contains {
                if case .pairStatusRequest = try? StrictWireDecoder().decodeText($0) { return true }
                return false
            }
        }
        XCTAssertTrue(requestedStatus)
        let sent = await transport.sentMessages()
        let requestID = try XCTUnwrap(sent.compactMap { text -> String? in
            guard case .pairStatusRequest(let request) = try? StrictWireDecoder().decodeText(text) else { return nil }
            return request.requestId
        }.last)
        await transport.push(try Wire.encode(PairStatus(
            requestId: requestID,
            enrollmentState: .paired,
            activePhoneCredentialVersion: 1
        )))
        let ready = await eventually { harness.state.pairing?.state == .ready }
        XCTAssertTrue(ready)
        return try XCTUnwrap(harness.state.pairing)
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
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await transport.waitForHello(token: AppStateTestToken.stored)
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
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
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

        await transport.waitForHello(token: AppStateTestToken.stored)
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

    func testInvalidPersistedRelayURLCanBeRepairedWithoutReplacingStoredToken() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        let invalidOutcome = await state.reconnect().value

        let invalidStatus = await client.currentStatus()
        XCTAssertEqual(invalidOutcome, .rejected(.invalidRelayURL))
        XCTAssertEqual(factory.count(), 0)
        XCTAssertEqual(invalidStatus, .disconnected)
        XCTAssertEqual(try settings.macToken(), AppStateTestToken.stored)
        XCTAssertNotNil(state.notice)

        let repairedOutcome = await state.applyConnectionSettings(
            relayURLString: "wss://example.com/ws",
            replacementMacToken: ""
        ).value

        XCTAssertEqual(repairedOutcome, .accepted)
        XCTAssertEqual(factory.count(), 1)
        guard factory.count() == 1 else { return }
        await transport.waitForHello(token: AppStateTestToken.stored)
        let sentStoredToken = await transport.containsHello(token: AppStateTestToken.stored)
        XCTAssertTrue(sentStoredToken)
    }

    func testTokenReadFailurePreservesRuntimeAndReconnectWorksAfterStorageRecovers() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.setReadError(AppStateTestError.deleteFailed)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let factory = AppStateTransportFactory([AppStateTransport(gateClose: false)])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        let failed = await state.reconnect().value
        secrets.setReadError(nil)
        let recovered = await state.reconnect().value

        XCTAssertEqual(failed, .rejected(.keychainUnavailable))
        XCTAssertEqual(recovered, .accepted)
        XCTAssertEqual(factory.count(), 1)
        XCTAssertNil(settings.storageError)
    }

    func testClearRetagsDisconnectedStatusForCurrentCredentialRevision() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let firstTransport = AppStateTransport(gateClose: false)
        let secondTransport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([firstTransport, secondTransport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await firstTransport.waitForHello(token: AppStateTestToken.stored)
        _ = await state.reconnect().value
        await secondTransport.waitForHello(token: AppStateTestToken.stored)
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
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored)
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
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored, deleteError: AppStateTestError.deleteFailed)
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
        XCTAssertFalse(settings.hasToken)
        XCTAssertEqual(clearedStatus, .disconnected)

        _ = await state.reconnect().value
        let closeCountAfterReconnect = await transport.closes()
        XCTAssertEqual(closeCountAfterReconnect, 1)

        let save = state.saveToken(AppStateTestToken.replacement)
        _ = await save.value
        let restarted = await eventually { await transport.containsHello(token: AppStateTestToken.replacement) }
        XCTAssertTrue(restarted)
    }

    func testClearTokenDeletionFailureRevokesAuthenticatedForwardedAction() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        defaults.set(true, forKey: SettingsStore.remoteEnabledKey)
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored, deleteError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { true }, request: { true })
        let poster = AppStateCountingPoster()
        let processor = ActionProcessor(poster: poster, permission: permission)
        let sink = AppStateForwardingGatedSink(processor: processor)
        let transport = AppStateTransport(gateClose: false)
        let client = RelayClient(actionSink: sink, diagnostics: processor, makeTransport: { transport })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())
        let helloSent = await eventually { await transport.containsHello(token: AppStateTestToken.stored) }
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
        XCTAssertFalse(settings.hasToken)

        _ = await state.saveToken(AppStateTestToken.replacement).value
        let replacementHelloSent = await eventually {
            await transport.containsHello(token: AppStateTestToken.replacement)
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
        XCTAssertEqual(state.notice, "Settings saved. Reconnecting…")
    }

    func testNewerSaveSupersedesClearSuspendedWhileClosingOldTransport() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored)
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
        let save = state.saveToken(AppStateTestToken.replacement)
        let replacementStarted = await eventually { factory.count() == 2 }
        XCTAssertTrue(replacementStarted)

        await oldTransport.releaseClose()
        await clear.value
        _ = await save.value

        let newHelloSent = await eventually {
            await newTransport.containsHello(token: AppStateTestToken.replacement)
        }
        XCTAssertEqual(state.notice, "Settings saved. Reconnecting…")
        XCTAssertEqual(try settings.macToken(), AppStateTestToken.replacement)
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
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        let clear = state.clearToken()
        let save = state.saveToken(AppStateTestToken.replacement)
        await clear.value
        _ = await save.value

        let newHelloSent = await eventually {
            await transport.containsHello(token: AppStateTestToken.replacement)
        }
        XCTAssertEqual(try settings.macToken(), AppStateTestToken.replacement)
        XCTAssertEqual(factory.count(), 1)
        XCTAssertTrue(newHelloSent)
        XCTAssertEqual(state.notice, "Settings saved. Reconnecting…")
    }

    func testClearDuringDelayedBootstrapBlocksOldTokenEvenWhenDeletionFailsUntilSave() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored, deleteError: AppStateTestError.deleteFailed)
        let settings = try SettingsStore(defaults: defaults, secrets: secrets)
        let permission = PostEventPermissionService(preflight: { false }, request: { false })
        let processor = ActionProcessor(poster: MacInputExecutor(constructEvents: { nil }), permission: permission)
        let transport = AppStateTransport(gateClose: false)
        let factory = AppStateTransportFactory([transport])
        let client = RelayClient(actionSink: processor, diagnostics: processor, makeTransport: { factory.make() })
        let state = AppState(settings: settings, client: client, processor: processor,
                             permissionService: permission, activationNotifications: NotificationCenter())

        await state.clearToken().value
        let reconnectOutcome = await state.reconnect().value

        XCTAssertEqual(factory.count(), 0)
        XCTAssertNil(try settings.macToken())
        XCTAssertEqual(reconnectOutcome, .rejected(.missingToken))
        XCTAssertEqual(state.notice, ConnectionActionIssue.missingToken.errorDescription)

        _ = await state.saveToken(AppStateTestToken.replacement).value
        let newHelloSent = await eventually {
            await transport.containsHello(token: AppStateTestToken.replacement)
        }
        XCTAssertEqual(factory.count(), 1)
        XCTAssertTrue(newHelloSent)
        XCTAssertEqual(state.notice, "Settings saved. Reconnecting…")
    }

    func testIneligibleReconnectCannotCancelClearSuspendedWhileClosing() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
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
        _ = await reconnect.value
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
        let secrets = AppStateSecretStore(token: AppStateTestToken.stored, writeError: AppStateTestError.deleteFailed)
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
        let failedSave = state.saveToken(AppStateTestToken.replacement)
        let failedOutcome = await failedSave.value
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
        XCTAssertEqual(failedOutcome, .rejected(.keychainUnavailable))
        XCTAssertEqual(state.notice, "Token cleared.")
    }

    func testClearSupersedesReconnectSuspendedWhileClosingWithoutOrphanTransport() async throws {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://example.com/ws", forKey: SettingsStore.relayURLKey)
        let settings = try SettingsStore(defaults: defaults, secrets: AppStateSecretStore(token: AppStateTestToken.stored))
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
        _ = await reconnect.value

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

        let saveA = state.saveToken(AppStateTestToken.replacement)
        let saveB = state.saveToken(AppStateTestToken.alternate)
        _ = await saveA.value
        _ = await saveB.value

        let helloB = await eventually {
            await transport.containsHello(token: AppStateTestToken.alternate)
        }
        let helloA = await transport.containsHello(token: AppStateTestToken.replacement)
        XCTAssertTrue(helloB)
        XCTAssertFalse(helloA)
        XCTAssertEqual(try settings.macToken(), AppStateTestToken.alternate)
        XCTAssertEqual(factory.count(), 1)
        XCTAssertEqual(state.notice, "Settings saved. Reconnecting…")
    }

    func testURLOnlyApplyReusesStoredTokenAndOpensOnlyNormalizedNewEndpoint() async throws {
        let transport = AppStateTransport(gateClose: false)
        let harness = try makeHarness(connection: connection(), transports: [transport])
        defer { harness.cleanUp() }

        let outcome = await harness.state.applyConnectionSettings(
            relayURLString: "  wss://new.example.com/ws  ",
            replacementMacToken: ""
        ).value

        XCTAssertEqual(outcome, .accepted)
        await transport.waitForHello(token: AppStateTestToken.stored)
        let connectedURLs = await transport.urls()
        XCTAssertEqual(connectedURLs, [URL(string: "wss://new.example.com/ws")!])
        XCTAssertEqual(harness.factory.count(), 1)
        XCTAssertEqual(
            try harness.settings.connection(),
            connection(url: "wss://new.example.com/ws")
        )
        XCTAssertEqual(
            harness.secrets.writes(account: SettingsStore.connectionRecordAccount),
            2,
            "the seed and one complete URL+token commit are the only writes"
        )
        await harness.client.stop()
    }

    func testApplyWithoutStoredOrReplacementTokenRejectsBeforeRuntimeMutation() async throws {
        let harness = try makeHarness(transports: [AppStateTransport(gateClose: false)])
        defer { harness.cleanUp() }

        let outcome = await harness.state.applyConnectionSettings(
            relayURLString: "wss://example.com/ws",
            replacementMacToken: ""
        ).value

        XCTAssertEqual(outcome, .rejected(.missingToken))
        XCTAssertEqual(harness.factory.count(), 0)
        XCTAssertNil(try harness.settings.connection())
        XCTAssertEqual(harness.secrets.writes(account: SettingsStore.connectionRecordAccount), 0)
    }

    func testReplacementApplyCommitsAndConfiguresOnlyTheValidatedPair() async throws {
        let transport = AppStateTransport(gateClose: false)
        let harness = try makeHarness(transports: [transport])
        defer { harness.cleanUp() }

        let outcome = await harness.state.applyConnectionSettings(
            relayURLString: "wss://replacement.example.com/ws",
            replacementMacToken: "  \(AppStateTestToken.replacement.uppercased())  "
        ).value

        XCTAssertEqual(outcome, .accepted)
        await transport.waitForHello(token: AppStateTestToken.replacement)
        let connectedURLs = await transport.urls()
        XCTAssertEqual(connectedURLs, [URL(string: "wss://replacement.example.com/ws")!])
        XCTAssertEqual(
            harness.secrets.storedConnection(),
            connection(url: "wss://replacement.example.com/ws", token: AppStateTestToken.replacement)
        )
        XCTAssertEqual(harness.secrets.writes(account: SettingsStore.connectionRecordAccount), 1)
        XCTAssertEqual(harness.factory.count(), 1)
        await harness.client.stop()
    }

    func testInvalidApplyRejectsWithoutPersistenceRuntimeOrControllerMutation() async throws {
        let transport = AppStateTransport(gateClose: false)
        let harness = try makeHarness(connection: connection(), transports: [transport])
        defer { harness.cleanUp() }
        await transport.waitForHello(token: AppStateTestToken.stored)
        let pairing = try XCTUnwrap(harness.state.pairing)
        let pairingIdentity = ObjectIdentifier(pairing)
        let writesBefore = harness.secrets.writes(account: SettingsStore.connectionRecordAccount)

        let invalidURL = await harness.state.applyConnectionSettings(
            relayURLString: "https://new.example.com/ws",
            replacementMacToken: AppStateTestToken.replacement
        ).value
        let invalidToken = await harness.state.applyConnectionSettings(
            relayURLString: "wss://new.example.com/ws",
            replacementMacToken: "not-a-token"
        ).value

        XCTAssertEqual(invalidURL, .rejected(.invalidRelayURL))
        XCTAssertEqual(invalidToken, .rejected(.invalidReplacementToken))
        XCTAssertEqual(harness.secrets.writes(account: SettingsStore.connectionRecordAccount), writesBefore)
        XCTAssertEqual(try harness.settings.connection(), connection())
        XCTAssertEqual(harness.factory.count(), 1)
        let closeCount = await transport.closes()
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(harness.state.pairing)), pairingIdentity)
        let status = await harness.client.currentStatus()
        XCTAssertEqual(status, .connecting)
        await harness.client.stop()
    }

    func testKeychainReadAndWriteFailuresPreserveAuthoritativePairAndLiveController() async throws {
        let transport = AppStateTransport(gateClose: false)
        let secrets = AppStateSecretStore()
        let harness = try makeHarness(connection: connection(), secrets: secrets, transports: [transport])
        defer { harness.cleanUp() }
        await transport.waitForHello(token: AppStateTestToken.stored)
        let pairingIdentity = ObjectIdentifier(try XCTUnwrap(harness.state.pairing))
        let writesBefore = secrets.writes(account: SettingsStore.connectionRecordAccount)
        let draft = ConnectionSettingsDraft(
            appliedRelayURLString: harness.settings.relayURLString,
            relayURLString: "wss://new.example.com/ws",
            replacementMacToken: ""
        )

        secrets.setReadError(AppStateTestError.deleteFailed)
        let readFailure = await harness.state.applyConnectionSettings(
            relayURLString: draft.relayURLString,
            replacementMacToken: draft.replacementMacToken
        ).value
        let reconnectFailure = await harness.state.reconnect().value
        secrets.setReadError(nil)
        secrets.setWriteError(AppStateTestError.deleteFailed)
        let writeFailure = await harness.state.applyConnectionSettings(
            relayURLString: draft.relayURLString,
            replacementMacToken: AppStateTestToken.replacement
        ).value
        secrets.setWriteError(nil)

        XCTAssertEqual(readFailure, .rejected(.keychainUnavailable))
        XCTAssertEqual(reconnectFailure, .rejected(.keychainUnavailable))
        XCTAssertEqual(writeFailure, .rejected(.keychainUnavailable))
        XCTAssertEqual(draft.relayURLString, "wss://new.example.com/ws")
        XCTAssertEqual(draft.replacementMacToken, "")
        XCTAssertEqual(try harness.settings.connection(), connection())
        XCTAssertEqual(secrets.writes(account: SettingsStore.connectionRecordAccount), writesBefore + 1)
        XCTAssertEqual(harness.factory.count(), 1)
        let closeCount = await transport.closes()
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(harness.state.pairing)), pairingIdentity)
        let status = await harness.client.currentStatus()
        XCTAssertEqual(status, .connecting)
        await harness.client.stop()
    }

    func testAcceptedConfigurationStaysSavedWhenTheNetworkIsUnavailable() async throws {
        let transport = AppStateTransport(gateClose: false, connectError: AppStateTestError.deleteFailed)
        let harness = try makeHarness(transports: [transport])
        defer { harness.cleanUp() }

        let outcome = await harness.state.applyConnectionSettings(
            relayURLString: "wss://offline.example.com/ws",
            replacementMacToken: AppStateTestToken.replacement
        ).value
        let attempted = await eventually { await transport.urls().count == 1 }

        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(attempted)
        XCTAssertEqual(
            try harness.settings.connection(),
            connection(url: "wss://offline.example.com/ws", token: AppStateTestToken.replacement)
        )
        XCTAssertEqual(harness.state.notice, "Settings saved. Reconnecting…")
        XCTAssertNotEqual(harness.state.notice, "Connected")
        await harness.client.stop()
    }

    func testBothPublicConnectionBoundariesAreMutationFreeInEveryBlockedPairingState() async throws {
        let transport = AppStateTransport(gateClose: false)
        let harness = try makeHarness(connection: connection(), transports: [transport])
        defer { harness.cleanUp() }
        await transport.waitForHello(token: AppStateTestToken.stored)
        let statusPublished = await eventually { harness.state.connection == .connecting }
        XCTAssertTrue(statusPublished)
        let invitation = PairingController.Invitation(
            url: URL(string: "https://example.com/pair#ref")!,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let approval = PairingController.Approval(
            confirmationCode: "123456",
            clientKind: .ios,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let blockedStates: [(name: String, state: PairingController.State)] = [
            ("creating", .creating),
            ("invitation", .invitation(invitation)),
            ("approval", .approval(approval)),
            ("approving", .approving),
            ("denying", .denying),
            ("cancelling", .cancelling),
            ("cancelFailed", .cancelFailed)
        ]
        let controllerIdentity = ObjectIdentifier(try XCTUnwrap(harness.state.pairing))
        let storedConnection = try XCTUnwrap(harness.settings.connection())
        let recordWrites = harness.secrets.writes(account: SettingsStore.connectionRecordAccount)
        let revision = harness.state.credentialRevisionForTesting
        let statusSequence = harness.state.lastStatusSequenceForTesting
        let appStatus = harness.state.connection
        let clientStatus = await harness.client.currentStatus()
        let factoryCount = harness.factory.count()
        let closeCount = await transport.closes()
        let pairing = try XCTUnwrap(harness.state.pairing)

        for blocked in blockedStates {
            pairing.forceBlockedConnectionStateForTesting(blocked.state)
            let draft = ConnectionSettingsDraft(
                appliedRelayURLString: storedConnection.relayURLString,
                relayURLString: "wss://new.example.com/ws",
                replacementMacToken: AppStateTestToken.replacement
            )

            let apply = await harness.state.applyConnectionSettings(
                relayURLString: draft.relayURLString,
                replacementMacToken: draft.replacementMacToken
            ).value
            let reconnect = await harness.state.reconnect().value
            let currentClientStatus = await harness.client.currentStatus()
            let currentCloseCount = await transport.closes()

            XCTAssertEqual(apply, .rejected(.pairingInProgress), blocked.name)
            XCTAssertEqual(reconnect, .rejected(.pairingInProgress), blocked.name)
            XCTAssertEqual(draft.relayURLString, "wss://new.example.com/ws", blocked.name)
            XCTAssertEqual(draft.replacementMacToken, AppStateTestToken.replacement, blocked.name)
            XCTAssertEqual(
                harness.secrets.writes(account: SettingsStore.connectionRecordAccount),
                recordWrites,
                blocked.name
            )
            XCTAssertEqual(try harness.settings.connection(), storedConnection, blocked.name)
            XCTAssertEqual(harness.state.credentialRevisionForTesting, revision, blocked.name)
            XCTAssertEqual(harness.state.lastStatusSequenceForTesting, statusSequence, blocked.name)
            XCTAssertEqual(harness.state.connection, appStatus, blocked.name)
            XCTAssertEqual(currentClientStatus, clientStatus, blocked.name)
            XCTAssertEqual(harness.factory.count(), factoryCount, blocked.name)
            XCTAssertEqual(currentCloseCount, closeCount, blocked.name)
            XCTAssertEqual(
                ObjectIdentifier(try XCTUnwrap(harness.state.pairing)),
                controllerIdentity,
                blocked.name
            )
        }

        pairing.clearBlockedConnectionStateForTesting()
        await harness.client.stop()
    }

    func testApplyAndReconnectBlockDuringPairingThenResumeAfterConfirmedCancellation() async throws {
        let current = AppStateTransport(gateClose: false, gatePairingCancel: true)
        let replacement = AppStateTransport(gateClose: false)
        let harness = try makeHarness(connection: connection(), transports: [current, replacement])
        defer { harness.cleanUp() }
        let controller = try await makePairingReady(in: harness, transport: current)
        harness.state.confirmReplacement()
        let creating = await eventually { harness.state.pairing?.state == .creating }
        XCTAssertTrue(creating)
        let identity = ObjectIdentifier(controller)
        let writesBefore = harness.secrets.writes(account: SettingsStore.connectionRecordAccount)

        let blockedApply = await harness.state.applyConnectionSettings(
            relayURLString: "wss://new.example.com/ws",
            replacementMacToken: AppStateTestToken.replacement
        ).value
        let blockedReconnect = await harness.state.reconnect().value

        XCTAssertEqual(blockedApply, .rejected(.pairingInProgress))
        XCTAssertEqual(blockedReconnect, .rejected(.pairingInProgress))
        XCTAssertEqual(harness.state.notice, ConnectionActionIssue.pairingInProgress.errorDescription)
        XCTAssertEqual(harness.secrets.writes(account: SettingsStore.connectionRecordAccount), writesBefore)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(harness.state.pairing)), identity)
        XCTAssertEqual(harness.factory.count(), 1)
        let closeCount = await current.closes()
        XCTAssertEqual(closeCount, 0)

        let cancel = Task { await controller.cancel() }
        let cancelling = await eventually { controller.state == .cancelling }
        XCTAssertTrue(cancelling)
        let cancellingReconnect = await harness.state.reconnect().value
        XCTAssertEqual(cancellingReconnect, .rejected(.pairingInProgress))
        await current.releasePairingCancel()
        await cancel.value
        XCTAssertEqual(controller.state, .cancelling)
        let stillBlocked = await harness.state.applyConnectionSettings(
            relayURLString: "wss://new.example.com/ws",
            replacementMacToken: AppStateTestToken.replacement
        ).value
        XCTAssertEqual(stillBlocked, .rejected(.pairingInProgress))
        let sentMessages = await current.sentMessages()
        let cancelRequestID = try XCTUnwrap(sentMessages.compactMap { text -> String? in
            guard case .pairCancel(let cancel) = try? StrictWireDecoder().decodeText(text) else { return nil }
            return cancel.requestId
        }.last)
        await current.push(try Wire.encode(PairFailed(
            requestId: cancelRequestID,
            claimId: nil,
            reason: .cancelled
        )))
        let cancellationConfirmed = await eventually { controller.state == .ready }
        XCTAssertTrue(cancellationConfirmed)

        let accepted = await harness.state.applyConnectionSettings(
            relayURLString: "wss://new.example.com/ws",
            replacementMacToken: AppStateTestToken.replacement
        ).value
        XCTAssertEqual(accepted, .accepted)
        await replacement.waitForHello(token: AppStateTestToken.replacement)
        XCTAssertEqual(harness.factory.count(), 2)
        await harness.client.stop()
    }

    func testClearRemainsAnEmergencyRevokeWhilePairingIsCreating() async throws {
        let current = AppStateTransport(gateClose: false)
        let harness = try makeHarness(connection: connection(), transports: [current])
        defer { harness.cleanUp() }
        let controller = try await makePairingReady(in: harness, transport: current)
        harness.state.confirmReplacement()
        let creating = await eventually { controller.state == .creating }
        XCTAssertTrue(creating)

        await harness.state.clearToken().value
        XCTAssertNil(try harness.settings.connection())
        let status = await harness.client.currentStatus()
        XCTAssertEqual(status, .disconnected)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
