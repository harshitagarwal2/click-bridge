import Foundation
import Security

enum KeychainStoreError: Error, LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        switch self { case .status(let status): return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }
}

struct KeychainStore: SecretStoring {
    let service: String
    init(service: String = "com.clickbridge.mac") { self.service = service }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.status(errSecDecode)
        }
        return value
    }

    func write(_ value: String, account: String) throws {
        let query = query(account: account)
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainStoreError.status(updateStatus) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
    }
}
