import Foundation

protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

struct SecretStoreUnavailable: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct UnavailableSecretStore: SecretStoring {
    private let unavailable: SecretStoreUnavailable
    init(failure: any Error) { unavailable = SecretStoreUnavailable(message: failure.localizedDescription) }
    func read(account: String) throws -> String? { throw unavailable }
    func write(_ value: String, account: String) throws { throw unavailable }
    func delete(account: String) throws { throw unavailable }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let relayURLKey = "relayURL"
    static let remoteEnabledKey = "remoteEnabled"
    private static let legacyMacTokenAccount = "macToken"

    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    private let enrollments: DesktopEnrollmentStore

    @Published var relayURLString: String
    @Published var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Self.remoteEnabledKey) }
    }
    @Published private(set) var hasToken: Bool
    @Published private(set) var storageError: String?
    private(set) var hasPartialLegacyEnrollment: Bool

    init(defaults: UserDefaults = .standard, secrets: any SecretStoring = KeychainStore()) throws {
        self.defaults = defaults
        self.secrets = secrets
        enrollments = DesktopEnrollmentStore(secrets: secrets)
        remoteEnabled = defaults.object(forKey: Self.remoteEnabledKey) as? Bool ?? false

        let legacyURL = defaults.string(forKey: Self.relayURLKey) ?? ""
        if let current = try enrollments.load() {
            relayURLString = current.relayURL
            hasToken = true
            hasPartialLegacyEnrollment = false
        } else {
            let legacyToken = try secrets.read(account: Self.legacyMacTokenAccount) ?? ""
            if Self.validLegacy(relayURL: legacyURL, token: legacyToken) {
                let migrated = DesktopEnrollmentRecord(
                    relayURL: legacyURL,
                    macToken: legacyToken,
                    automaticRecoveryUsed: false
                )
                try enrollments.save(migrated)
                relayURLString = migrated.relayURL
                hasToken = true
                hasPartialLegacyEnrollment = false
                clearLegacyEnrollmentBestEffort()
            } else {
                relayURLString = legacyURL
                hasToken = false
                hasPartialLegacyEnrollment = !legacyURL.isEmpty || !legacyToken.isEmpty
            }
        }
    }

    init(defaults: UserDefaults = .standard,
         unavailableSecrets: UnavailableSecretStore,
         failure: any Error) {
        self.defaults = defaults
        secrets = unavailableSecrets
        enrollments = DesktopEnrollmentStore(secrets: unavailableSecrets)
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        remoteEnabled = defaults.object(forKey: Self.remoteEnabledKey) as? Bool ?? false
        hasToken = false
        hasPartialLegacyEnrollment = false
        storageError = "Keychain is unavailable: \(failure.localizedDescription)"
    }

    func enrollment() throws -> DesktopEnrollmentRecord? {
        do { return try enrollments.load() }
        catch {
            storageError = "Could not read relay enrollment: \(error.localizedDescription)"
            throw error
        }
    }

    @discardableResult
    func saveEnrollment(_ enrollment: DesktopEnrollment,
                        automaticRecoveryUsed: Bool = false) throws -> DesktopEnrollmentRecord {
        let record = DesktopEnrollmentRecord(
            relayURL: enrollment.relayURL,
            macToken: enrollment.token,
            automaticRecoveryUsed: automaticRecoveryUsed
        )
        try saveEnrollmentRecord(record)
        return record
    }

    func saveEnrollmentRecord(_ record: DesktopEnrollmentRecord) throws {
        do {
            try enrollments.save(record)
            relayURLString = record.relayURL
            hasToken = true
            hasPartialLegacyEnrollment = false
            storageError = nil
            clearLegacyEnrollmentBestEffort()
        } catch {
            storageError = "Could not save relay enrollment: \(error.localizedDescription)"
            throw error
        }
    }

    func clearAutomaticRecoveryMarker() throws {
        guard let record = try enrollment(), record.automaticRecoveryUsed else { return }
        try saveEnrollmentRecord(record.replacingAutomaticRecoveryUsed(false))
    }

    // Compatibility seams for non-UI callers. Production setup never exposes a token field.
    func macToken() throws -> String? { try enrollment()?.macToken }

    func saveMacToken(_ value: String) throws {
        let current = try enrollment()
        let record = DesktopEnrollmentRecord(
            relayURL: relayURLString,
            macToken: value,
            enrollmentId: current?.enrollmentId ?? UUID().uuidString.lowercased(),
            automaticRecoveryUsed: current?.automaticRecoveryUsed ?? false
        )
        try saveEnrollmentRecord(record)
    }

    func clearMacToken() throws {
        do {
            try enrollments.clear()
            try secrets.delete(account: Self.legacyMacTokenAccount)
            defaults.removeObject(forKey: Self.relayURLKey)
            relayURLString = ""
            hasToken = false
            hasPartialLegacyEnrollment = false
            storageError = nil
        } catch {
            storageError = "Could not clear relay enrollment: \(error.localizedDescription)"
            throw error
        }
    }

    private static func validLegacy(relayURL: String, token: String) -> Bool {
        (try? RelayEndpoint.validated(relayURL, allowLocalSimulator: false)) != nil
            && token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private func clearLegacyEnrollmentBestEffort() {
        try? secrets.delete(account: Self.legacyMacTokenAccount)
        defaults.removeObject(forKey: Self.relayURLKey)
    }
}
