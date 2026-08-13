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
    case invalidState, corruptState

    var errorDescription: String? { "The saved pairing state changed. Start pairing again." }
}

struct PhonePairingCredential: Codable, Equatable, Sendable {
    let token: String
    let version: Int
}

struct PhonePairingPendingCredential: Equatable, Sendable {
    let credential: PhonePairingCredential
    let relayWebSocketURL: URL
    fileprivate let generation: UInt64

    init(credential: PhonePairingCredential, relayWebSocketURL: URL, generation: UInt64 = 0) {
        self.credential = credential
        self.relayWebSocketURL = relayWebSocketURL
        self.generation = generation
    }
}

struct PhonePairingReplacementAuthorization: Equatable, Sendable {
    fileprivate let activeToken: String
    fileprivate let activeVersion: Int?
    fileprivate let generation: UInt64
}

private struct StoredPhoneCredential: Codable, Equatable {
    enum Provenance: String, Codable { case unknown, relay }
    let token: String
    let version: Int?
    let provenance: Provenance
    let relayWebSocketURL: String?

    init(token: String, version: Int?, provenance: Provenance,
         relayWebSocketURL: String? = nil) {
        self.token = token
        self.version = version
        self.provenance = provenance
        self.relayWebSocketURL = relayWebSocketURL
    }
}

private struct StoredPhoneCredentialRecord: Codable, Equatable {
    let schema: Int
    let generation: UInt64
    let active: StoredPhoneCredential?
    let pending: StoredPhoneCredential?

    init(schema: Int, generation: UInt64 = 0,
         active: StoredPhoneCredential?, pending: StoredPhoneCredential?) {
        self.schema = schema
        self.generation = generation
        self.active = active
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case schema, generation, active, pending }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        active = try container.decodeIfPresent(StoredPhoneCredential.self, forKey: .active)
        pending = try container.decodeIfPresent(StoredPhoneCredential.self, forKey: .pending)
    }
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
        do {
            let record = try Self.decodeRecord(secrets.read(account: Self.phoneTokenAccount))
            hasToken = record.active != nil
            relayURLString = record.active?.relayWebSocketURL
                ?? defaults.string(forKey: Self.relayURLKey) ?? ""
            if record.active?.relayWebSocketURL != nil {
                defaults.set(relayURLString, forKey: Self.relayURLKey)
            }
        } catch {
            relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
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
        let current = try readRecord()
        try writeRecord(.init(
            schema: 1,
            generation: try nextGeneration(current.generation),
            active: .init(token: token, version: nil, provenance: .unknown),
            pending: nil
        ))
        hasToken = true
    }

    func clearPhoneToken() throws {
        let current = try readRecord()
        try writeRecord(.init(
            schema: 1,
            generation: try nextGeneration(current.generation),
            active: nil,
            pending: nil
        ))
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

    func pendingPairingRecoveryDescriptor() throws -> PhonePairingPendingCredential? {
        let current = try readRecord()
        let pending = current.pending
        guard pending?.provenance == .relay,
              let token = pending?.token,
              let version = pending?.version,
              let origin = pending?.relayWebSocketURL,
              let relayWebSocketURL = PhonePairingLink.canonicalClaimantWebSocketURL(URL(string: origin)) else {
            return nil
        }
        return .init(
            credential: .init(token: token, version: version),
            relayWebSocketURL: relayWebSocketURL,
            generation: current.generation
        )
    }

    func replacementAuthorization() throws -> PhonePairingReplacementAuthorization? {
        let current = try readRecord()
        guard current.active?.provenance == .unknown,
              let token = current.active?.token else { return nil }
        return .init(
            activeToken: token,
            activeVersion: current.active?.version,
            generation: current.generation
        )
    }

    @discardableResult
    func stagePairingCredential(
        _ credential: PhonePairingCredential,
        relayWebSocketURL: URL? = nil,
        replacementAuthorization: PhonePairingReplacementAuthorization? = nil
    ) throws -> PhonePairingPendingCredential {
        try RelayConfiguration.validateToken(credential.token)
        guard credential.version > 0, credential.version <= 9_007_199_254_740_991 else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        guard let relayWebSocketURL = PhonePairingLink.canonicalClaimantWebSocketURL(relayWebSocketURL) else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        let current = try readRecord()
        guard current.pending == nil else { throw PhonePairingCredentialStorageError.invalidState }
        // The relay's credential version is a single counter shared by every
        // enrolled phone, so it advances when *another* phone pairs too. Only
        // require forward movement against whatever this phone already holds;
        // demanding an exact successor (or exactly 1 for a fresh phone) makes
        // pairing impossible as soon as the relay's counter runs ahead.
        if let activeVersion = current.active?.version, current.active?.provenance == .relay {
            guard credential.version > activeVersion else {
                throw PhonePairingCredentialStorageError.invalidState
            }
        } else if current.active != nil {
            guard current.active?.provenance == .unknown,
                  replacementAuthorization?.activeToken == current.active?.token,
                  replacementAuthorization?.activeVersion == current.active?.version,
                  replacementAuthorization?.generation == current.generation else {
                throw PhonePairingCredentialStorageError.invalidState
            }
        }
        let newGeneration = try nextGeneration(current.generation)
        try writeRecord(.init(
            schema: 1,
            generation: newGeneration,
            active: current.active,
            pending: .init(
                token: credential.token,
                version: credential.version,
                provenance: .relay,
                relayWebSocketURL: relayWebSocketURL.absoluteString
            )
        ))
        return .init(
            credential: credential,
            relayWebSocketURL: relayWebSocketURL,
            generation: newGeneration
        )
    }

    func promotePairingCredential(_ expected: PhonePairingPendingCredential) throws {
        let current = try readRecord()
        let pending = current.pending
        guard pending?.provenance == .relay,
              current.generation == expected.generation,
              pending?.token == expected.credential.token,
              pending?.version == expected.credential.version,
              pending?.relayWebSocketURL == expected.relayWebSocketURL.absoluteString else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        try writeRecord(.init(
            schema: 1,
            generation: try nextGeneration(current.generation),
            active: pending,
            pending: nil
        ))
        hasToken = true
    }

    func discardPairingCredential(_ expected: PhonePairingPendingCredential) throws {
        let current = try readRecord()
        guard current.generation == expected.generation,
              current.pending?.token == expected.credential.token,
              current.pending?.version == expected.credential.version,
              current.pending?.relayWebSocketURL == expected.relayWebSocketURL.absoluteString else {
            throw PhonePairingCredentialStorageError.invalidState
        }
        try writeRecord(.init(
            schema: 1,
            generation: try nextGeneration(current.generation),
            active: current.active,
            pending: nil
        ))
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
            throw PhonePairingCredentialStorageError.corruptState
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

    private func nextGeneration(_ current: UInt64) throws -> UInt64 {
        guard current < UInt64.max else { throw PhonePairingCredentialStorageError.invalidState }
        return current + 1
    }

    private static func valid(_ slot: StoredPhoneCredential?) -> Bool {
        guard let slot else { return true }
        guard (try? RelayConfiguration.validateToken(slot.token)) != nil else { return false }
        switch slot.provenance {
        case .unknown: return slot.version == nil && slot.relayWebSocketURL == nil
        case .relay:
            guard slot.version.map({ $0 > 0 && $0 <= 9_007_199_254_740_991 }) == true else {
                return false
            }
            if let origin = slot.relayWebSocketURL {
                return PhonePairingLink.canonicalClaimantWebSocketURL(URL(string: origin)) != nil
            }
            return true
        }
    }

    private static func validRecord(_ record: StoredPhoneCredentialRecord) -> Bool {
        guard valid(record.active), valid(record.pending) else { return false }
        guard let pending = record.pending else { return true }
        if let active = record.active {
            switch active.provenance {
            case .relay:
                guard let activeVersion = active.version,
                      pending.version == activeVersion + 1 else { return false }
            case .unknown:
                guard pending.version == 1 else { return false }
            }
        } else {
            guard pending.version == 1 else { return false }
        }
        return pending.provenance == .relay && pending.relayWebSocketURL != nil
    }

    private func perform<T>(_ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            storageError = nil
            return result
        } catch {
            if let storageError = error as? PhonePairingCredentialStorageError {
                self.storageError = PhoneSettingsStorageError.unavailable.localizedDescription
                throw storageError
            }
            let sanitized = PhoneSettingsStorageError.unavailable
            storageError = sanitized.localizedDescription
            throw sanitized
        }
    }
}
