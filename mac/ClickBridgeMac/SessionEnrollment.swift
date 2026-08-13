import Foundation

struct DesktopEnrollment: Sendable {
    let relayURL: String
    let token: String
}

enum SessionEnrollmentError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Could not create a private relay session. Check your internet connection and try again."
        case .invalidResponse: "The relay returned an invalid private session. Try again."
        }
    }
}

enum SessionEnrollmentService {
    static let endpoint = URL(string: "https://clickbridge-sjc.duckdns.org/v1/sessions")!

    static func enroll(session: URLSession = .shared) async throws -> DesktopEnrollment {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw SessionEnrollmentError.unavailable
        }
        struct Response: Decodable { let relayURL: String; let token: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (try? RelayEndpoint.validated(decoded.relayURL, allowLocalSimulator: false)) != nil else {
            throw SessionEnrollmentError.invalidResponse
        }
        return DesktopEnrollment(relayURL: decoded.relayURL, token: decoded.token)
    }
}
