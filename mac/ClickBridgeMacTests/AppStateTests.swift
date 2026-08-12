import XCTest
import AppKit
@testable import ClickBridgeMac

private enum AppStateTestError: Error { case deleteFailed }

private final class AppStateSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let deleteError: Error?
    private let writeError: Error?

    init(token: String? = nil, deleteError: Error? = nil, writeError: Error? = nil) {
        self.token = token
        self.deleteError = deleteError
        self.writeError = writeError
    }

    func read(account: String) throws -> String? { lock.withLock { token } }
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
    private var inboundContinuation: CheckedContinuation<String, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private let gateClose: Bool
    private(set) var closeCount = 0
    private(set) var closeStarted = false
    private(set) var sent: [String] = []

    init(gateClose: Bool) { self.gateClose = gateClose }

    func connect(to url: URL) async throws {}
    func sendText(_ text: String) async throws { sent.append(text) }
    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { inboundContinuation = $0 }
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
    func sentMessages() -> [String] { sent }
    func containsHello(token: String) -> Bool {
        sent.contains { (try? JSONDecoder().decode(Hello.self, from: Data($0.utf8)))?.token == token }
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
