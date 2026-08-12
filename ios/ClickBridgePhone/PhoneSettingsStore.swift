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
            hasToken = try secrets.read(account: Self.phoneTokenAccount) != nil
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

    func phoneToken() throws -> String? { try perform { try secrets.read(account: Self.phoneTokenAccount) } }

    func savePhoneToken(_ token: String) throws {
        try RelayConfiguration.validateToken(token)
        try perform { try secrets.write(token, account: Self.phoneTokenAccount) }
        hasToken = true
    }

    func clearPhoneToken() throws {
        try perform { try secrets.delete(account: Self.phoneTokenAccount) }
        hasToken = false
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
