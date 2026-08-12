import XCTest
import AppKit
@testable import ClickBridgeMac

private final class AppStateSecretStore: SecretStoring, @unchecked Sendable {
    func read(account: String) throws -> String? { nil }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
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
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
