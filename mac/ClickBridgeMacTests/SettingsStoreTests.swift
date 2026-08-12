import XCTest
@testable import ClickBridgeMac

private final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    enum Failure: Error, Equatable { case read, write, delete }
    private let lock = NSLock()
    var values: [String: String] = [:]
    var failure: Failure?

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failure == .read { throw Failure.read }
        return values[account]
    }

    func write(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failure == .write { throw Failure.write }
        values[account] = value
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failure == .delete { throw Failure.delete }
        values.removeValue(forKey: account)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: FakeSecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "ClickBridgeMacTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        secrets = FakeSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStoredFalseIsPreservedAndFirstLaunchDefaultsFalse() throws {
        XCTAssertFalse(try SettingsStore(defaults: defaults, secrets: secrets).remoteEnabled)
        defaults.set(false, forKey: SettingsStore.remoteEnabledKey)
        XCTAssertFalse(try SettingsStore(defaults: defaults, secrets: secrets).remoteEnabled)
    }

    func testRelayURLPersists() throws {
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        store.relayURLString = "wss://relay.example/ws"
        XCTAssertEqual(try SettingsStore(defaults: defaults, secrets: secrets).relayURLString,
                       "wss://relay.example/ws")
    }

    func testTokenSaveAndClearUseSecretStore() throws {
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        try store.saveMacToken("token")
        XCTAssertEqual(try store.macToken(), "token")
        try store.clearMacToken()
        XCTAssertNil(try store.macToken())
    }

    func testSecretFailuresReachVisibleErrorState() throws {
        secrets.failure = .read
        XCTAssertThrowsError(try SettingsStore(defaults: defaults, secrets: secrets))

        secrets.failure = nil
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.failure = .write
        XCTAssertThrowsError(try store.saveMacToken("token"))
        XCTAssertNotNil(store.storageError)

        secrets.failure = .delete
        XCTAssertThrowsError(try store.clearMacToken())
        XCTAssertNotNil(store.storageError)
    }
}
