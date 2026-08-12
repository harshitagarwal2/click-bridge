import XCTest
import AppKit
@testable import ClickBridgeMac

private enum AppStateTestError: Error { case deleteFailed }

private final class AppStateSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let deleteError: Error?

    init(token: String? = nil, deleteError: Error? = nil) {
        self.token = token
        self.deleteError = deleteError
    }

    func read(account: String) throws -> String? { lock.withLock { token } }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {
        if let deleteError { throw deleteError }
        lock.withLock { token = nil }
    }
}

private actor AppStateTransport: WebSocketTransport {
    private var inboundContinuation: CheckedContinuation<String, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private let gateClose: Bool
    private(set) var closeCount = 0
    private(set) var closeStarted = false

    init(gateClose: Bool) { self.gateClose = gateClose }

    func connect(to url: URL) async throws {}
    func sendText(_ text: String) async throws {}
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
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
