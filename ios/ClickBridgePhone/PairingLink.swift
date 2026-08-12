import Foundation

enum PhonePairingLinkError: LocalizedError {
    case invalid

    var errorDescription: String? { "This pairing link is invalid or has expired." }
}

struct PhonePairingLink: Equatable, Sendable {
    let reference: String
    let claimantWebSocketURL: URL

    static func parse(_ url: URL, expectedHost: String) throws -> Self {
        let raw = url.absoluteString
        guard Data(raw.utf8).count <= 512,
              !raw.contains("%"),
              expectedHost.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == expectedHost,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              ["/pair", "/pair/web"].contains(components.path),
              components.query == nil,
              let fragment = components.fragment,
              fragment.hasPrefix("v=1&r="),
              !fragment.dropFirst(6).contains("&") else {
            throw PhonePairingLinkError.invalid
        }
        let reference = String(fragment.dropFirst(6))
        guard canonicalReference(reference),
              raw == "https://\(expectedHost)\(components.path)#v=1&r=\(reference)",
              let socketURL = canonicalClaimantWebSocketURL(
                URL(string: "wss://\(expectedHost)/ws")
              ) else {
            throw PhonePairingLinkError.invalid
        }
        return Self(reference: reference, claimantWebSocketURL: socketURL)
    }

    static func canonicalClaimantWebSocketURL(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "wss",
              let host = components.host,
              host.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path == "/ws",
              components.query == nil,
              components.fragment == nil,
              url.absoluteString == "wss://\(host)/ws" else {
            return nil
        }
        return url
    }

    private static func canonicalReference(_ value: String) -> Bool {
        guard value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            return false
        }
        let base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return false }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }
}
