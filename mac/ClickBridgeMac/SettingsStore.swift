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

enum SettingsStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidConnectionRecord
    case missingConnectionRecord

    var errorDescription: String? {
        switch self {
        case .invalidConnectionRecord:
            return "The saved connection is invalid. Enter the connection details again."
        case .missingConnectionRecord:
            return "The saved connection is unavailable. Enter the connection details again."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let relayURLKey = "relayURL"
    static let remoteEnabledKey = "remoteEnabled"
    static let connectionEstablishedKey = "connectionRecordEstablished"
    static let connectionRevokedKey = "connectionCredentialRevoked"
    static let connectionRecordAccount = "connection.v1"
    static let legacyMacTokenAccount = "macToken"

    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    @Published private(set) var relayURLString: String
    @Published var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Self.remoteEnabledKey) }
    }
    @Published private(set) var hasToken: Bool
    @Published private(set) var storageError: String?

    init(defaults: UserDefaults = .standard, secrets: any SecretStoring = KeychainStore()) throws {
        self.defaults = defaults
        self.secrets = secrets
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        remoteEnabled = defaults.object(forKey: Self.remoteEnabledKey) as? Bool ?? false
        hasToken = false

        do {
            if let stored = try loadConnection() {
                relayURLString = stored.relayURLString
                hasToken = true
            }
        } catch let error as SettingsStoreError {
            storageError = error.localizedDescription
        }
    }

    init(
        defaults: UserDefaults = .standard,
        unavailableSecrets: UnavailableSecretStore,
        failure: any Error
    ) {
        self.defaults = defaults
        secrets = unavailableSecrets
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        remoteEnabled = defaults.object(forKey: Self.remoteEnabledKey) as? Bool ?? false
        hasToken = false
        storageError = "Keychain is unavailable: \(failure.localizedDescription)"
    }

    func connection() throws -> StoredConnection? {
        do {
            let stored = try loadConnection()
            hasToken = stored != nil
            if let stored {
                relayURLString = stored.relayURLString
            }
            storageError = nil
            return stored
        } catch {
            hasToken = false
            storageError = connectionReadErrorMessage(error)
            throw error
        }
    }

    func saveConnection(_ connection: StoredConnection) throws {
        let canonical: StoredConnection
        do {
            canonical = try canonicalConnection(connection)
        } catch {
            storageError = SettingsStoreError.invalidConnectionRecord.localizedDescription
            throw SettingsStoreError.invalidConnectionRecord
        }

        let encoded = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
        do {
            // This single Security-framework item is the authoritative commit point.
            try secrets.write(encoded, account: Self.connectionRecordAccount)
        } catch {
            storageError = "Could not save the connection securely: \(error.localizedDescription)"
            throw error
        }

        // These values are nonauthoritative mirrors and markers. They move only
        // after the complete URL+token record exists.
        defaults.set(true, forKey: Self.connectionEstablishedKey)
        defaults.removeObject(forKey: Self.connectionRevokedKey)
        defaults.set(canonical.relayURLString, forKey: Self.relayURLKey)
        relayURLString = canonical.relayURLString
        hasToken = true
        storageError = nil

        // The established marker prevents legacy fallback even if cleanup fails.
        try? secrets.delete(account: Self.legacyMacTokenAccount)
    }

    func clearConnection() throws {
        // Persist fail-closed intent before either credential deletion so a
        // crash or deletion failure cannot resurrect the prior connection.
        defaults.set(true, forKey: Self.connectionRevokedKey)
        hasToken = false

        var firstFailure: (any Error)?
        for account in [Self.connectionRecordAccount, Self.legacyMacTokenAccount] {
            do {
                try secrets.delete(account: account)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure {
            storageError = "Could not clear the saved connection: \(firstFailure.localizedDescription)"
            throw firstFailure
        }
        storageError = nil
    }

    // Transitional compatibility for AppState while Task 2 moves every caller
    // onto the atomic URL+token apply boundary.
    func macToken() throws -> String? {
        try connection()?.macToken
    }

    func saveMacToken(_ value: String) throws {
        let validated = try ConnectionSettingsValidator.validate(
            relayURLString: relayURLString,
            replacementMacToken: value
        )
        guard case .replacement(let token) = validated.tokenInput else {
            throw ConnectionSettingsValidationError.invalidReplacementToken
        }
        try saveConnection(
            StoredConnection(
                version: StoredConnection.currentVersion,
                relayURLString: validated.relayURLString,
                macToken: token
            )
        )
    }

    func clearMacToken() throws {
        try clearConnection()
    }

    // Compile staging only. The current Settings view still owns a Binding;
    // Task 2 replaces it with ConnectionSettingsDraft and removes this seam.
    func stageRelayURLDraft(_ value: String) {
        relayURLString = value
    }

    private func loadConnection() throws -> StoredConnection? {
        if defaults.bool(forKey: Self.connectionRevokedKey) {
            return nil
        }

        if let encoded = try secrets.read(account: Self.connectionRecordAccount) {
            guard let data = encoded.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(StoredConnection.self, from: data) else {
                throw SettingsStoreError.invalidConnectionRecord
            }
            do {
                return try canonicalConnection(decoded)
            } catch {
                throw SettingsStoreError.invalidConnectionRecord
            }
        }

        guard !defaults.bool(forKey: Self.connectionEstablishedKey) else {
            throw SettingsStoreError.missingConnectionRecord
        }

        guard let legacyToken = try secrets.read(account: Self.legacyMacTokenAccount),
              !legacyToken.isEmpty,
              !relayURLString.isEmpty else {
            return nil
        }
        return StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: relayURLString,
            macToken: legacyToken
        )
    }

    private func canonicalConnection(_ connection: StoredConnection) throws -> StoredConnection {
        guard connection.version == StoredConnection.currentVersion else {
            throw SettingsStoreError.invalidConnectionRecord
        }
        let validated = try ConnectionSettingsValidator.validate(
            relayURLString: connection.relayURLString,
            replacementMacToken: connection.macToken
        )
        guard validated.relayURLString == connection.relayURLString,
              case .replacement(let token) = validated.tokenInput,
              token == connection.macToken else {
            throw SettingsStoreError.invalidConnectionRecord
        }
        return connection
    }

    private func connectionReadErrorMessage(_ error: any Error) -> String {
        if let error = error as? SettingsStoreError {
            return error.localizedDescription
        }
        return "Could not read the saved connection: \(error.localizedDescription)"
    }
}
