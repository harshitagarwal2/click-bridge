import Foundation
import Security

/// Relay URL and the remote toggle live in UserDefaults; the token lives in
/// the Keychain and is never echoed back to the UI.
final class SettingsStore: ObservableObject, @unchecked Sendable {

    private enum Key {
        static let relayURL = "relayURL"
        static let remoteEnabled = "remoteEnabled"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    @Published var relayURLString: String {
        didSet { defaults.set(relayURLString, forKey: Key.relayURL) }
    }

    /// Defaults to OFF on first launch, then preserves the user's choice.
    @Published var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Key.remoteEnabled) }
    }

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.relayURLString = defaults.string(forKey: Key.relayURL) ?? ""
        // Only absence means "first launch" — a stored false must survive.
        self.remoteEnabled = defaults.object(forKey: Key.remoteEnabled) as? Bool ?? false
    }

    var relayURL: URL? {
        guard !relayURLString.isEmpty else { return nil }
        return URL(string: relayURLString)
    }

    var hasToken: Bool { (macToken?.isEmpty == false) }

    var macToken: String? {
        get { keychain.read(account: "macToken") }
        set {
            if let newValue, !newValue.isEmpty { keychain.write(newValue, account: "macToken") }
            else { keychain.delete(account: "macToken") }
        }
    }

    /// Milestone 2 only. Never enters the relay environment.
    var directToken: String? {
        get { keychain.read(account: "directToken") }
        set {
            if let newValue, !newValue.isEmpty { keychain.write(newValue, account: "directToken") }
            else { keychain.delete(account: "directToken") }
        }
    }
}

struct KeychainStore: Sendable {
    var service = "com.clickbridge.mac"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data]

        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        } else {
            var insert = q
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
