import Foundation
import Security

private let service = "com.clickbridge.mac"
private let account = "macToken"
private let relayURLKey = "relayURL"
private let applicationDomain = "com.clickbridge.mac"

private func fail() -> Never { exit(1) }

guard CommandLine.arguments.count == 3,
      CommandLine.arguments[1] == "--relay-url",
      let components = URLComponents(string: CommandLine.arguments[2]),
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.host?.isEmpty == false,
      components.scheme == "wss" || components.scheme == "https" else { fail() }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var token = String(data: input, encoding: .utf8) else { fail() }
if token.hasSuffix("\n") { token.removeLast() }
guard token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { fail() }

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
]
let data = Data(token.utf8)
let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
if update == errSecItemNotFound {
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { fail() }
} else if update != errSecSuccess {
    fail()
}

var domain = UserDefaults.standard.persistentDomain(forName: applicationDomain) ?? [:]
domain[relayURLKey] = CommandLine.arguments[2]
UserDefaults.standard.setPersistentDomain(domain, forName: applicationDomain)
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.clickbridge.mac.configurationChanged"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
