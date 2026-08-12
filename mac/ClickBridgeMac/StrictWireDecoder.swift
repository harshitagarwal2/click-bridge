import Foundation

struct StrictWireDecoder: Sendable {
    private let decoder = JSONDecoder()

    func rejectBinary(_ data: Data) throws -> Never { throw WireError.binaryFrame }

    func decodeText(_ text: String, for role: WireRole? = nil) throws -> WireMessage {
        let data = Data(text.utf8)
        guard data.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { throw WireError.notJSONObject }
        guard let type = dictionary["type"] as? String else { throw WireError.missingType }
        guard let version = dictionary["v"] as? Int, version == Constants.protocolVersion else {
            throw WireError.unsupportedVersion
        }
        guard let allowed = Self.allowedKeys[type] else { throw WireError.unknownType(type) }
        let extras = Set(dictionary.keys).subtracting(allowed).sorted()
        guard extras.isEmpty else { throw WireError.unknownKeys(extras) }
        if type == "hello" || type == "hello.ok" {
            guard let role = dictionary["role"] as? String, role == "phone" || role == "mac" else {
                throw WireError.invalidRole(dictionary["role"] as? String ?? "")
            }
        }
        do {
            let message = try decoder.decode(WireMessage.self, from: data)
            try validateSemantics(message)
            if let role { try validate(message, allowedFor: role) }
            return message
        }
        catch let error as WireError { throw error }
        catch { throw WireError.decodeFailed(type) }
    }

    private func validateSemantics(_ message: WireMessage) throws {
        switch message {
        case .relayAck(let ack):
            let valid = (ack.status == .forwarded && ack.reason == .ok)
                || (ack.status == .macOffline && ack.reason == .macOffline)
                || (ack.status == .rejected && (ack.reason == .expired || ack.reason == .invalidRequest))
            guard valid else { throw WireError.invalidValue }
        case .actionResult(let result):
            let validPosted = result.status == .posted && result.reason == .ok && result.mouseDownPostedUnixMs != nil
            let validRejected = result.status == .rejected && result.reason != .ok && result.mouseDownPostedUnixMs == nil
            guard validPosted || validRejected else { throw WireError.invalidValue }
        default: break
        }
    }

    private func validate(_ message: WireMessage, allowedFor role: WireRole) throws {
        let allowed: Bool
        switch (role, message) {
        case (.mac, .helloOK(let hello)): allowed = hello.role == "mac"
        case (.mac, .heartbeatRequest), (.mac, .heartbeatAck), (.mac, .actionRequest),
             (.mac, .timeSyncRequest), (.mac, .diagnosticsRequest): allowed = true
        case (.phone, .helloOK(let hello)): allowed = hello.role == "phone"
        case (.phone, .heartbeatRequest), (.phone, .heartbeatAck), (.phone, .state),
             (.phone, .relayAck), (.phone, .actionResult), (.phone, .timeSyncResponse),
             (.phone, .diagnosticsCounters): allowed = true
        default: allowed = false
        }
        guard allowed else { throw WireError.messageNotAllowed }
    }

    private static let allowedKeys: [String: Set<String>] = [
        "hello": ["type", "v", "role", "token"],
        "hello.ok": ["type", "v", "role"],
        "heartbeat.request": ["type", "v", "sequence"],
        "heartbeat.ack": ["type", "v", "sequence"],
        "time.sync.request": ["type", "v", "syncId", "phoneSendUnixMs"],
        "time.sync.response": ["type", "v", "syncId", "phoneSendUnixMs", "macReceiveUnixMs", "macSendUnixMs"],
        "diagnostics.request": ["type", "v", "requestId"],
        "diagnostics.counters": ["type", "v", "requestId", "mouseDownPostCount", "mouseUpPostCount"],
        "mac.state": ["type", "v", "remoteEnabled", "permission"],
        "state": ["type", "v", "macOnline", "remoteEnabled", "permission"],
        "action.request": ["type", "v", "actionId", "action", "issuedAtUnixMs", "expiresAtUnixMs"],
        "relay.ack": ["type", "v", "actionId", "status", "reason", "relayProcessingUs"],
        "action.result": ["type", "v", "actionId", "status", "reason", "acceptedVia", "macProcessingUs", "mouseDownPostedUnixMs"],
    ]
}
