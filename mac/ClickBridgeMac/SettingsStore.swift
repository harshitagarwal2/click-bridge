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
    private static let macTokenAccount = "macToken"

    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    @Published var relayURLString: String {
        didSet { defaults.set(relayURLString, forKey: Self.relayURLKey) }
    }
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
        hasToken = try secrets.read(account: Self.macTokenAccount)?.isEmpty == false
    }

    init(defaults: UserDefaults = .standard,
         unavailableSecrets: UnavailableSecretStore,
         failure: any Error) {
        self.defaults = defaults
        secrets = unavailableSecrets
        relayURLString = defaults.string(forKey: Self.relayURLKey) ?? ""
        remoteEnabled = defaults.object(forKey: Self.remoteEnabledKey) as? Bool ?? false
        hasToken = false
        storageError = "Keychain is unavailable: \(failure.localizedDescription)"
    }

    func macToken() throws -> String? {
        do { return try secrets.read(account: Self.macTokenAccount) }
        catch { storageError = "Could not read MAC_TOKEN: \(error.localizedDescription)"; throw error }
    }

    func saveMacToken(_ value: String) throws {
        do {
            try secrets.write(value, account: Self.macTokenAccount)
            hasToken = true; storageError = nil
        } catch {
            storageError = "Could not save MAC_TOKEN: \(error.localizedDescription)"; throw error
        }
    }

    func clearMacToken() throws {
        do {
            try secrets.delete(account: Self.macTokenAccount)
            hasToken = false; storageError = nil
        } catch {
            storageError = "Could not clear MAC_TOKEN: \(error.localizedDescription)"; throw error
        }
    }
}
