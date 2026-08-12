import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhoneSettingsStoreTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    func testConfigurationAcceptsOnlyWSSWSPathAndLowercaseHexToken() throws {
        XCTAssertEqual(try RelayConfiguration.validated(urlString: "wss://relay.example/ws", token: token).url.absoluteString,
                       "wss://relay.example/ws")
        for invalid in ["ws://relay.example/ws", "wss://user@relay.example/ws", "wss://relay.example/ws?token=secret", "wss://relay.example/ws#x", "wss://relay.example/other"] {
            XCTAssertThrowsError(try RelayConfiguration.validated(urlString: invalid, token: token))
        }
        XCTAssertThrowsError(try RelayConfiguration.validated(urlString: "wss://relay.example/ws", token: token.uppercased()))
        XCTAssertThrowsError(try RelayConfiguration.validated(urlString: "wss://relay.example/ws", token: String(repeating: "g", count: 64)))
        XCTAssertThrowsError(try RelayConfiguration.validated(urlString: "wss://relay.example/ws", token: "abc"))
    }

    func testValidationErrorsNeverContainToken() {
        let supplied = "TOP-SECRET-" + token
        XCTAssertThrowsError(try RelayConfiguration.validated(urlString: "https://relay.example/ws", token: supplied)) { error in
            XCTAssertFalse(error.localizedDescription.contains(supplied))
        }
    }

    func testStorePersistsURLAndTokenLifecycle() throws {
        let suite = "PhoneSettingsStoreTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = TestSecretStore()
        let store = try PhoneSettingsStore(defaults: defaults, secrets: secrets)
        store.relayURLString = "wss://relay.example/ws"
        try store.savePhoneToken(token)

        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(try store.phoneToken(), token)
        XCTAssertEqual(defaults.string(forKey: PhoneSettingsStore.relayURLKey), "wss://relay.example/ws")
        try store.clearPhoneToken()
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(try store.phoneToken())
    }

    func testStorageFailureIsRedacted() throws {
        let supplied = token
        let secrets = TestSecretStore(writeError: NSError(domain: supplied, code: 1))
        let store = try PhoneSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        XCTAssertThrowsError(try store.savePhoneToken(supplied)) { error in
            XCTAssertFalse(error.localizedDescription.contains(supplied))
            XCTAssertFalse((error as NSError).domain.contains(supplied))
        }
        XCTAssertFalse((store.storageError ?? "").contains(supplied))
        XCTAssertEqual(store.storageError, "Secure storage is unavailable. Try again or restart the app.")
    }

    func testUnavailableSecretStoreAlwaysThrowsSanitizedActionableError() {
        let supplied = String(repeating: "d", count: 64)
        let subject = UnavailablePhoneSecretStore()

        for operation in [
            { try subject.read(account: supplied).map { _ in } },
            { try subject.write(supplied, account: supplied) },
            { try subject.delete(account: supplied) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error.localizedDescription,
                               "Secure storage is unavailable. Try again or restart the app.")
                XCTAssertFalse(error.localizedDescription.contains(supplied))
                XCTAssertFalse((error as NSError).domain.contains(supplied))
            }
        }
    }

    func testCompositionFallsBackWithoutCrashingAndCannotPersistToken() throws {
        let suite = "PhoneCompositionFailure-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let supplied = String(repeating: "e", count: 64)
        let failing = TestSecretStore(readError: NSError(domain: supplied, code: 1))

        let model = PhoneComposition.makeModel(defaults: defaults, secrets: failing)

        XCTAssertEqual(model.state.primaryStatus, .notConnected)
        XCTAssertFalse(model.settings.hasToken)
        XCTAssertEqual(model.settings.storageError,
                       "Secure storage is unavailable. Try again or restart the app.")
        XCTAssertThrowsError(try model.saveSettings(urlString: "wss://relay.example/ws", token: supplied)) { error in
            XCTAssertFalse(error.localizedDescription.contains(supplied))
        }
        XCTAssertFalse(model.settings.hasToken)
        XCTAssertNil(defaults.string(forKey: PhoneSettingsStore.relayURLKey))
        XCTAssertEqual(model.state.primaryStatus, .notConnected)
    }
}

private final class TestSecretStore: SecretStoring, @unchecked Sendable {
    var value: String?
    let readError: Error?
    let writeError: Error?
    let deleteError: Error?
    init(readError: Error? = nil, writeError: Error? = nil, deleteError: Error? = nil) {
        self.readError = readError
        self.writeError = writeError
        self.deleteError = deleteError
    }
    func read(account: String) throws -> String? { if let readError { throw readError }; return value }
    func write(_ value: String, account: String) throws { if let writeError { throw writeError }; self.value = value }
    func delete(account: String) throws { if let deleteError { throw deleteError }; value = nil }
}
