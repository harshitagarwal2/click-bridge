import Foundation
import Observation

protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

enum RelayConfigurationError: LocalizedError {
    case invalidURL, invalidToken
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Relay URL must be a wss:// URL ending in /ws."
        case .invalidToken: "Phone token must be 64 lowercase hexadecimal characters."
        }
    }
}

enum PhoneSettingsStorageError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Secure storage is unavailable. Try again or restart the app."
    }
}

enum PhonePairingCredentialStorageError: LocalizedError {
    case invalidState

    var errorDescription: String? { "The saved pairing state changed. Start pairing again." }
}

struct PhonePairingCredential: Codable, Equatable, Sendable {
    let token: String
    let version: Int
}

private struct StoredPhoneCredential: Codable, Equatable {
    enum Provenance: String, Codable { case unknown, relay }
    let token: String
    let version: Int?
    let provenance: Provenance
}

private struct StoredPhoneCredentialRecord: Codable, Equatable {
    let schema: Int
    let active: StoredPhoneCredential?
    let pending: StoredPhoneCredential?
}

struct UnavailablePhoneSecretStore: SecretStoring {
    func read(account: String) throws -> String? {
        throw PhoneSettingsStorageError.unavailable
    }

    func write(_ value: String, account: String) throws {
        throw PhoneSettingsStorageError.unavailable
    }

    func delete(account: String) throws {
        throw PhoneSettingsStorageError.unavailable
    }
}

extension RelayConfiguration {
    static func validatedURL(_ urlString: String) throws -> URL {
        guard let components = URLComponents(string: urlString),
              components.scheme == "wss", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/ws", let url = components.url else {
            throw RelayConfigurationError.invalidURL
        }
        return url
    }

    static func validateToken(_ token: String) throws {
        guard token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RelayConfigurationError.invalidToken
        }
    }

    static func validated(urlString: String, token: String) throws -> Self {
        let url = try validatedURL(urlString)
        try validateToken(token)
        return .init(url: url, token: token)
    }
}

@MainActor
@Observable
final class PhoneSettingsStore {
    static let relayURLKey = "relayURL"
    static let phoneTokenAccount = "phoneToken"

    var relayURLString: String {
        didSet { defaults.set(relayURLString, forKey: Self.relayURLKey) }
    }
    private(set) var hasToken: Bool
    private(set) var storageError: String?
    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    init(defaults: UserDefaults = .standard,
         secrets: any SecretStoring = KeychainStore()) throws {
        self.defaults = defaults
        self.secrets = secrets
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        do {
            hasToken = try Self.decodeRecord(
                secrets.read(account: Self.phoneTokenAccount)
            ).active != nil
        } catch {
            hasToken = false
            throw PhoneSettingsStorageError.unavailable
        }
    }

    static func unavailable(defaults: UserDefaults = .standard) -> PhoneSettingsStore {
        PhoneSettingsStore(defaults: defaults,
                           unavailableSecrets: UnavailablePhoneSecretStore())
    }

    private init(defaults: UserDefaults,
                 unavailableSecrets: UnavailablePhoneSecretStore) {
        self.defaults = defaults
        secrets = unavailableSecrets
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        hasToken = false
        storageError = PhoneSettingsStorageError.unavailable.localizedDescription
    }

    func phoneToken() throws -> String? { try readRecord().active?.token }

    func savePhoneToken(_ token: String) throws {
        try RelayConfiguration.validateToken(token)
        try writeRecord(.init(
            schema: 1,
            active: .init(token: token, version: nil, provenance: .unknown),
            pending: nil
        ))
        hasToken = true
    }

    func clearPhoneToken() throws {
        try perform { try secrets.delete(account: Self.phoneTokenAccount) }
        hasToken = false
    }

    func activePairingCredential() throws -> PhonePairingCredential? {
        let active = try readRecord().active
        guard active?.provenance == .relay, let token = active?.token, let version = active?.version else {
            return nil
        }
        return .init(token: token, version: version)
    }

    func pendingPairingCredential() throws -> PhonePairingCredential? {
        let pending = try readRecord().pending
        guard pending?.provenance == .relay, let token = pending?.token, let version = pending?.version else {
            return nil
        }
        return .init(token: token, version: version)
    }

    func stagePairingCredential(_ credential: PhonePairingCredential) throws {
        try RelayConfiguration.validateToken(credential.token)
        guard credential.version > 0, credential.version <= 9_007_199_254_740_991 else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        let current = try readRecord()
        guard current.pending == nil else { throw PhonePairingCredentialStorageError.invalidState }
        if let activeVersion = current.active?.version, current.active?.provenance == .relay {
            guard credential.version == activeVersion + 1 else {
                throw PhonePairingCredentialStorageError.invalidState
            }
        } else if current.active == nil {
            guard credential.version == 1 else { throw PhonePairingCredentialStorageError.invalidState }
        } else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        try writeRecord(.init(
            schema: 1,
            active: current.active,
            pending: .init(token: credential.token, version: credential.version, provenance: .relay)
        ))
    }

    func promotePairingCredential(_ expected: PhonePairingCredential) throws {
        let current = try readRecord()
        let pending = current.pending
        guard pending?.provenance == .relay,
              pending?.token == expected.token,
              pending?.version == expected.version else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        try writeRecord(.init(schema: 1, active: pending, pending: nil))
        hasToken = true
    }

    func discardPairingCredential(_ expected: PhonePairingCredential) throws {
        let current = try readRecord()
        guard current.pending?.token == expected.token,
              current.pending?.version == expected.version else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        try writeRecord(.init(schema: 1, active: current.active, pending: nil))
    }

    private func readRecord() throws -> StoredPhoneCredentialRecord {
        try perform {
            try Self.decodeRecord(secrets.read(account: Self.phoneTokenAccount))
        }
    }

    private static func decodeRecord(_ raw: String?) throws -> StoredPhoneCredentialRecord {
        guard let raw else { return .init(schema: 1, active: nil, pending: nil) }
        if (try? RelayConfiguration.validateToken(raw)) != nil {
            return .init(
                schema: 1,
                active: .init(token: raw, version: nil, provenance: .unknown),
                pending: nil
            )
        }
        guard let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(StoredPhoneCredentialRecord.self, from: data),
              record.schema == 1,
              validRecord(record) else {
            throw PhoneSettingsStorageError.unavailable
        }
        return record
    }

    private func writeRecord(_ record: StoredPhoneCredentialRecord) throws {
        try perform {
            let data = try JSONEncoder().encode(record)
            guard let value = String(data: data, encoding: .utf8) else {
                throw PhoneSettingsStorageError.unavailable
            }
            try secrets.write(value, account: Self.phoneTokenAccount)
        }
    }

    private static func valid(_ slot: StoredPhoneCredential?) -> Bool {
        guard let slot else { return true }
        guard (try? RelayConfiguration.validateToken(slot.token)) != nil else { return false }
        switch slot.provenance {
        case .unknown: return slot.version == nil
        case .relay:
            return slot.version.map { $0 > 0 && $0 <= 9_007_199_254_740_991 } == true
        }
    }

    private static func validRecord(_ record: StoredPhoneCredentialRecord) -> Bool {
        guard valid(record.active), valid(record.pending) else { return false }
        guard let pending = record.pending else { return true }
        if let active = record.active {
            guard active.provenance == .relay,
                  let activeVersion = active.version,
                  pending.version == activeVersion + 1 else { return false }
        } else {
            guard pending.version == 1 else { return false }
        }
        return pending.provenance == .relay
    }

    private func perform<T>(_ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            storageError = nil
            return result
        } catch {
            let sanitized = PhoneSettingsStorageError.unavailable
            storageError = sanitized.localizedDescription
            throw sanitized
        }
    }
}
