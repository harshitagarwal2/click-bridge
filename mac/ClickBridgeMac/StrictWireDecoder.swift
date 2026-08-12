import Foundation
import CoreFoundation

struct StrictWireDecoder: Sendable {
    private let decoder = JSONDecoder()
    private static let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private static let token = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")

    func rejectBinary(_ data: Data) throws -> Never { throw WireError.binaryFrame }

    func decodeText(_ text: String, for role: WireRole? = nil) throws -> WireMessage {
        let data = Data(text.utf8)
        guard data.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { throw WireError.notJSONObject }
        let type = try string(dictionary, "type")
        guard try number(dictionary, "v") == Double(Constants.protocolVersion) else {
            throw WireError.unsupportedVersion
        }
        try validateFieldsAndScalars(dictionary, type: type)
        do {
            let message = try decoder.decode(WireMessage.self, from: data)
            if let role { try validate(message, allowedFor: role) }
            return message
        } catch let error as WireError {
            throw error
        } catch {
            throw WireError.decodeFailed(type)
        }
    }

    private func validateFieldsAndScalars(_ message: [String: Any], type: String) throws {
        switch type {
        case "hello":
            try exact(message, ["type", "v", "role", "token"])
            try oneOf(string(message, "role"), ["phone", "mac"])
            guard Self.matches(Self.token, try string(message, "token")) else { throw WireError.invalidValue }
        case "hello.ok":
            try exact(message, ["type", "v", "role"])
            try oneOf(string(message, "role"), ["phone", "mac"])
        case "heartbeat.request", "heartbeat.ack":
            try exact(message, ["type", "v", "sequence"])
            _ = try nonNegativeInteger(message, "sequence")
        case "time.sync.request":
            try exact(message, ["type", "v", "syncId", "phoneSendUnixMs"])
            try uuid(message, "syncId")
            guard try number(message, "phoneSendUnixMs") > 0 else { throw WireError.invalidValue }
        case "time.sync.response":
            try exact(message, ["type", "v", "syncId", "phoneSendUnixMs", "macReceiveUnixMs", "macSendUnixMs"])
            try uuid(message, "syncId")
            let phone = try number(message, "phoneSendUnixMs")
            let received = try number(message, "macReceiveUnixMs")
            let sent = try number(message, "macSendUnixMs")
            guard phone > 0, received > 0, sent > 0, sent >= received else { throw WireError.invalidValue }
        case "diagnostics.request":
            try exact(message, ["type", "v", "requestId"])
            try uuid(message, "requestId")
        case "diagnostics.counters":
            try exact(message, ["type", "v", "requestId", "mouseDownPostCount", "mouseUpPostCount"])
            try uuid(message, "requestId")
            _ = try nonNegativeInteger(message, "mouseDownPostCount")
            _ = try nonNegativeInteger(message, "mouseUpPostCount")
        case "mac.state":
            try exact(message, ["type", "v", "remoteEnabled", "permission"])
            _ = try boolean(message, "remoteEnabled")
            try permission(message)
        case "state":
            try exact(message, ["type", "v", "macOnline", "remoteEnabled", "permission"])
            _ = try boolean(message, "macOnline")
            _ = try boolean(message, "remoteEnabled")
            try permission(message)
        case "action.request":
            try exact(message, ["type", "v", "actionId", "action", "issuedAtUnixMs", "expiresAtUnixMs"])
            try uuid(message, "actionId")
            try oneOf(string(message, "action"), ["click"])
            let issued = try number(message, "issuedAtUnixMs")
            let expires = try number(message, "expiresAtUnixMs")
            guard issued > 0, expires - issued == Constants.actionLifetimeMs else { throw WireError.invalidValue }
        case "relay.ack":
            try exact(message, ["type", "v", "actionId", "status", "reason", "relayProcessingUs"])
            try uuid(message, "actionId")
            let status = try string(message, "status")
            let reason = try string(message, "reason")
            try oneOf(status, ["forwarded", "mac_offline", "rejected"])
            try oneOf(reason, ["ok", "mac_offline", "expired", "invalid_request"])
            guard try number(message, "relayProcessingUs") >= 0 else { throw WireError.invalidValue }
            let valid = (status == "forwarded" && reason == "ok")
                || (status == "mac_offline" && reason == "mac_offline")
                || (status == "rejected" && ["expired", "invalid_request"].contains(reason))
            guard valid else { throw WireError.invalidValue }
        case "action.result":
            let status = try string(message, "status")
            try oneOf(status, ["posted", "rejected"])
            var fields = ["type", "v", "actionId", "status", "reason", "acceptedVia", "macProcessingUs"]
            if status == "posted" { fields.append("mouseDownPostedUnixMs") }
            try exact(message, fields)
            try uuid(message, "actionId")
            let reason = try string(message, "reason")
            try oneOf(reason, ResultReason.allWireValues)
            try oneOf(string(message, "acceptedVia"), ["oci", "tailscale"])
            guard try number(message, "macProcessingUs") >= 0 else { throw WireError.invalidValue }
            if status == "posted" {
                guard reason == "ok", try number(message, "mouseDownPostedUnixMs") > 0 else { throw WireError.invalidValue }
            } else {
                guard reason != "ok" else { throw WireError.invalidValue }
            }
        default:
            throw WireError.unknownType(type)
        }
    }

    private func exact(_ message: [String: Any], _ fields: [String]) throws {
        let expected = Set(fields)
        let extras = Set(message.keys).subtracting(expected).sorted()
        guard extras.isEmpty else { throw WireError.unknownKeys(extras) }
        guard expected.isSubset(of: message.keys) else { throw WireError.invalidValue }
    }

    private func string(_ message: [String: Any], _ key: String) throws -> String {
        guard let value = message[key] as? String else { throw WireError.invalidValue }
        return value
    }

    private func boolean(_ message: [String: Any], _ key: String) throws -> Bool {
        guard let value = message[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw WireError.invalidValue }
        return value.boolValue
    }

    private func number(_ message: [String: Any], _ key: String) throws -> Double {
        guard let value = message[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw WireError.invalidValue
        }
        return value.doubleValue
    }

    private func nonNegativeInteger(_ message: [String: Any], _ key: String) throws -> Int {
        let value = try number(message, key)
        guard value >= 0, value.rounded(.towardZero) == value, value <= Double(Int.max) else {
            throw WireError.invalidValue
        }
        return Int(value)
    }

    private func uuid(_ message: [String: Any], _ key: String) throws {
        guard Self.matches(Self.uuid, try string(message, key)) else { throw WireError.invalidValue }
    }

    private func permission(_ message: [String: Any]) throws {
        try oneOf(string(message, "permission"), ["ready", "required", "unknown"])
    }

    private func oneOf(_ value: String, _ allowed: [String]) throws {
        guard allowed.contains(value) else { throw WireError.invalidValue }
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private func validate(_ message: WireMessage, allowedFor role: WireRole) throws {
        let allowed: Bool
        switch (role, message) {
        case (.mac, .helloOK(let hello)): allowed = hello.role == "mac"
        case (.mac, .heartbeatAck), (.mac, .actionRequest), (.mac, .timeSyncRequest), (.mac, .diagnosticsRequest): allowed = true
        case (.phone, .helloOK(let hello)): allowed = hello.role == "phone"
        case (.phone, .heartbeatAck), (.phone, .state), (.phone, .relayAck), (.phone, .actionResult),
             (.phone, .timeSyncResponse), (.phone, .diagnosticsCounters): allowed = true
        default: allowed = false
        }
        guard allowed else { throw WireError.messageNotAllowed }
    }
}

private extension ResultReason {
    static let allWireValues = [
        "ok", "permission_required", "remote_disabled", "expired", "capacity_exceeded",
        "id_conflict", "event_creation_failed", "invalid_request",
    ]
}
