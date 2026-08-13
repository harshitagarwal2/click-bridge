import Foundation
import XCTest
@testable import ClickBridgeMac

private final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    enum Operation: Equatable {
        case read(String)
        case write(String)
        case delete(String)
    }

    enum Failure: Error, Equatable { case read, write, delete }

    private let lock = NSLock()
    var values: [String: String] = [:]
    var operations: [Operation] = []
    var failure: Failure?
    var onWrite: ((String, String) -> Void)?
    var onDelete: ((String) -> Void)?

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        operations.append(.read(account))
        if failure == .read { throw Failure.read }
        return values[account]
    }

    func write(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        operations.append(.write(account))
        if failure == .write { throw Failure.write }
        onWrite?(value, account)
        values[account] = value
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        operations.append(.delete(account))
        onDelete?(account)
        if failure == .delete { throw Failure.delete }
        values.removeValue(forKey: account)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private let legacyURL = "wss://legacy.example.com/ws"
    private let replacementURL = "wss://replacement.example.com/ws"
    private let legacyToken = String(repeating: "a1", count: 32)
    private let replacementToken = String(repeating: "b2", count: 32)

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

    func testVersionedConnectionRoundTripsThroughOneAuthoritativeSecret() throws {
        let connection = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: replacementURL,
            macToken: replacementToken
        )
        let store = try SettingsStore(defaults: defaults, secrets: secrets)

        try store.saveConnection(connection)

        XCTAssertEqual(try store.connection(), connection)
        XCTAssertEqual(store.relayURLString, replacementURL)
        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(Set(secrets.values.keys), [SettingsStore.connectionRecordAccount])
        XCTAssertEqual(try SettingsStore(defaults: defaults, secrets: secrets).connection(), connection)
    }

    func testLegacyPairRemainsReadableUntilFirstAcceptedSaveMigratesIt() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken
        let store = try SettingsStore(defaults: defaults, secrets: secrets)

        let legacy = try XCTUnwrap(store.connection())
        XCTAssertEqual(legacy.relayURLString, legacyURL)
        XCTAssertEqual(legacy.macToken, legacyToken)
        XCTAssertNil(secrets.values[SettingsStore.connectionRecordAccount])
        XCTAssertFalse(defaults.bool(forKey: SettingsStore.connectionEstablishedKey))

        try store.saveConnection(legacy)

        XCTAssertNotNil(secrets.values[SettingsStore.connectionRecordAccount])
        XCTAssertNil(secrets.values[SettingsStore.legacyMacTokenAccount])
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.connectionEstablishedKey))
        XCTAssertEqual(try SettingsStore(defaults: defaults, secrets: secrets).connection(), legacy)
    }

    func testURLOnlyMigrationWritesCompleteRecordBeforeEstablishingMigrationOrUpdatingMirror() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        let migrated = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: replacementURL,
            macToken: try XCTUnwrap(store.connection()).macToken
        )
        var stateObservedAtCommit: (established: Bool, mirror: String?)?
        secrets.onWrite = { [defaults] _, account in
            guard account == SettingsStore.connectionRecordAccount else { return }
            stateObservedAtCommit = (
                defaults!.bool(forKey: SettingsStore.connectionEstablishedKey),
                defaults!.string(forKey: SettingsStore.relayURLKey)
            )
        }

        try store.saveConnection(migrated)

        XCTAssertEqual(stateObservedAtCommit?.established, false)
        XCTAssertEqual(stateObservedAtCommit?.mirror, legacyURL)
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.connectionEstablishedKey))
        XCTAssertEqual(defaults.string(forKey: SettingsStore.relayURLKey), replacementURL)
        XCTAssertEqual(try store.connection(), migrated)
    }

    func testReplacementSaveWritesCompleteRecordBeforeClearingRevocationOrUpdatingMirror() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        defaults.set(true, forKey: SettingsStore.connectionRevokedKey)
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        let replacement = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: replacementURL,
            macToken: replacementToken
        )
        var stateObservedAtCommit: (revoked: Bool, mirror: String?)?
        secrets.onWrite = { [defaults] _, account in
            guard account == SettingsStore.connectionRecordAccount else { return }
            stateObservedAtCommit = (
                defaults!.bool(forKey: SettingsStore.connectionRevokedKey),
                defaults!.string(forKey: SettingsStore.relayURLKey)
            )
        }

        try store.saveConnection(replacement)

        XCTAssertEqual(stateObservedAtCommit?.revoked, true)
        XCTAssertEqual(stateObservedAtCommit?.mirror, legacyURL)
        XCTAssertFalse(defaults.bool(forKey: SettingsStore.connectionRevokedKey))
        XCTAssertEqual(defaults.string(forKey: SettingsStore.relayURLKey), replacementURL)
        XCTAssertEqual(try store.connection(), replacement)
    }

    func testFailedRecordWritePreservesPriorAuthoritativePairAndMirrors() throws {
        let oldConnection = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: legacyURL,
            macToken: legacyToken
        )
        let replacement = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: replacementURL,
            macToken: replacementToken
        )
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        try store.saveConnection(oldConnection)
        secrets.failure = .write

        XCTAssertThrowsError(try store.saveConnection(replacement))
        XCTAssertNotNil(store.storageError)

        secrets.failure = nil
        XCTAssertEqual(try store.connection(), oldConnection)
        XCTAssertEqual(store.relayURLString, legacyURL)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.relayURLKey), legacyURL)
    }

    func testCorruptVersionedRecordFailsClosedWithoutReadingLegacyCredential() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        secrets.values[SettingsStore.connectionRecordAccount] = "not-json"
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.operations.removeAll()

        XCTAssertThrowsError(try store.connection()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .invalidConnectionRecord)
        }
        XCTAssertFalse(store.hasToken)
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(secrets.operations.contains(.read(SettingsStore.legacyMacTokenAccount)))
    }

    func testMissingRecordAfterMigrationWasEstablishedFailsClosedWithoutLegacyFallback() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        defaults.set(true, forKey: SettingsStore.connectionEstablishedKey)
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.operations.removeAll()

        XCTAssertThrowsError(try store.connection()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .missingConnectionRecord)
        }
        XCTAssertFalse(store.hasToken)
        XCTAssertFalse(secrets.operations.contains(.read(SettingsStore.legacyMacTokenAccount)))
    }

    func testRevocationMarkerPreventsRestartTimeLegacyOrCurrentCredentialResurrection() throws {
        defaults.set(legacyURL, forKey: SettingsStore.relayURLKey)
        defaults.set(true, forKey: SettingsStore.connectionRevokedKey)
        secrets.values[SettingsStore.connectionRecordAccount] = try encodedRecord(
            StoredConnection(
                version: StoredConnection.currentVersion,
                relayURLString: legacyURL,
                macToken: legacyToken
            )
        )
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken

        let store = try SettingsStore(defaults: defaults, secrets: secrets)

        XCTAssertNil(try store.connection())
        XCTAssertNil(try store.macToken())
        XCTAssertFalse(store.hasToken)
    }

    func testClearMarksRevokedBeforeAttemptingBothDeletesAndFailedDeletionStaysRevoked() throws {
        let connection = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: legacyURL,
            macToken: legacyToken
        )
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        try store.saveConnection(connection)
        secrets.values[SettingsStore.legacyMacTokenAccount] = legacyToken
        var markerValuesAtDelete: [Bool] = []
        secrets.onDelete = { [defaults] _ in
            markerValuesAtDelete.append(defaults!.bool(forKey: SettingsStore.connectionRevokedKey))
        }
        secrets.failure = .delete

        XCTAssertThrowsError(try store.clearConnection())

        XCTAssertEqual(markerValuesAtDelete, [true, true])
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.connectionRevokedKey))
        XCTAssertFalse(store.hasToken)
        secrets.failure = nil
        XCTAssertNil(try SettingsStore(defaults: defaults, secrets: secrets).connection())
    }

    func testTokenNeverEntersUserDefaults() throws {
        let connection = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: replacementURL,
            macToken: replacementToken
        )
        let store = try SettingsStore(defaults: defaults, secrets: secrets)

        try store.saveConnection(connection)

        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            (value as? String)?.contains(replacementToken) == true
        })
        XCTAssertNil(defaults.string(forKey: SettingsStore.legacyMacTokenAccount))
    }

    func testSecretFailuresReachVisibleErrorState() throws {
        secrets.failure = .read
        XCTAssertThrowsError(try SettingsStore(defaults: defaults, secrets: secrets))

        secrets.failure = nil
        let store = try SettingsStore(defaults: defaults, secrets: secrets)
        secrets.failure = .write
        XCTAssertThrowsError(
            try store.saveConnection(
                StoredConnection(
                    version: StoredConnection.currentVersion,
                    relayURLString: replacementURL,
                    macToken: replacementToken
                )
            )
        )
        XCTAssertNotNil(store.storageError)

        secrets.failure = .delete
        XCTAssertThrowsError(try store.clearConnection())
        XCTAssertNotNil(store.storageError)
    }

    func testKnownKeychainInitializationFailureKeepsAllOperationsThrowing() throws {
        let failure = FakeSecretStore.Failure.read
        let unavailable = UnavailableSecretStore(failure: failure)
        let store = SettingsStore(defaults: defaults, unavailableSecrets: unavailable, failure: failure)
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.connection())
        XCTAssertThrowsError(
            try store.saveConnection(
                StoredConnection(
                    version: StoredConnection.currentVersion,
                    relayURLString: replacementURL,
                    macToken: replacementToken
                )
            )
        )
        XCTAssertThrowsError(try store.clearConnection())
        XCTAssertFalse(store.hasToken)
    }

    private func encodedRecord(_ connection: StoredConnection) throws -> String {
        String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
    }
}
