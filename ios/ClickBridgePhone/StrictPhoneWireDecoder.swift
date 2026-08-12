import CoreFoundation
import Foundation

struct StrictPhoneWireDecoder: Sendable {
    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    )
    private let decoder = JSONDecoder()

    func rejectBinary(_ data: Data) throws -> Never {
        throw PhoneWireError.binaryFrame
    }

    func decodeText(_ text: String) throws -> PhoneServerMessage {
        let data = Data(text.utf8)
        guard data.count <= PhoneProtocolV1.maximumMessageBytes else { throw PhoneWireError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else { throw PhoneWireError.notJSONObject }

        let type = try string(message, "type")
        guard try number(message, "v") == Double(PhoneProtocolV1.version) else {
            throw PhoneWireError.unsupportedVersion
        }

        try validate(message, type: type)
        do {
            switch type {
            case "hello.ok": return .helloOK(try decoder.decode(HelloOK.self, from: data))
            case "heartbeat.ack": return .heartbeatAck(try decoder.decode(HeartbeatAck.self, from: data))
            case "state": return .state(try decoder.decode(RelayState.self, from: data))
            case "relay.ack": return .relayAck(try decoder.decode(RelayAck.self, from: data))
            case "action.result": return .actionResult(try decoder.decode(ActionResult.self, from: data))
            case "diagnostics.counters": return .diagnosticsCounters(try decoder.decode(DiagnosticsCounters.self, from: data))
            case "time.sync.response": return .timeSyncResponse(try decoder.decode(TimeSyncResponse.self, from: data))
            default: throw PhoneWireError.messageNotAllowed
            }
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError.decodeFailed(type)
        }
    }

    private func validate(_ message: [String: Any], type: String) throws {
        switch type {
        case "hello.ok":
            try exact(message, ["type", "v", "role"])
            guard try string(message, "role") == "phone" else { throw PhoneWireError.messageNotAllowed }
        case "heartbeat.ack":
            try exact(message, ["type", "v", "sequence"])
            _ = try nonnegativeInteger(message, "sequence")
        case "state":
            try exact(message, ["type", "v", "macOnline", "remoteEnabled", "permission"])
            _ = try boolean(message, "macOnline")
            _ = try boolean(message, "remoteEnabled")
            try oneOf(string(message, "permission"), PermissionState.allWireValues)
        case "relay.ack":
            try exact(message, ["type", "v", "actionId", "status", "reason", "relayProcessingUs"])
            try validUUID(message, "actionId")
            let status = try string(message, "status")
            let reason = try string(message, "reason")
            try oneOf(status, RelayAckStatus.allWireValues)
            try oneOf(reason, RelayAckReason.allWireValues)
            guard try number(message, "relayProcessingUs") >= 0 else { throw PhoneWireError.invalidValue }
            let valid = (status == "forwarded" && reason == "ok")
                || (status == "mac_offline" && reason == "mac_offline")
                || (status == "rejected" && ["expired", "invalid_request"].contains(reason))
            guard valid else { throw PhoneWireError.invalidValue }
        case "action.result":
            let status = try string(message, "status")
            try oneOf(status, ResultStatus.allWireValues)
            var fields = ["type", "v", "actionId", "status", "reason", "acceptedVia", "macProcessingUs"]
            if status == "posted" { fields.append("mouseDownPostedUnixMs") }
            try exact(message, fields)
            try validUUID(message, "actionId")
            let reason = try string(message, "reason")
            try oneOf(reason, ResultReason.allCases.map(\.rawValue))
            try oneOf(string(message, "acceptedVia"), ActionIngress.allWireValues)
            guard try number(message, "macProcessingUs") >= 0 else { throw PhoneWireError.invalidValue }
            if status == "posted" {
                guard reason == "ok", try number(message, "mouseDownPostedUnixMs") > 0 else {
                    throw PhoneWireError.invalidValue
                }
            } else {
                guard reason != "ok" else { throw PhoneWireError.invalidValue }
            }
        case "diagnostics.counters":
            try exact(message, ["type", "v", "requestId", "mouseDownPostCount", "mouseUpPostCount"])
            try validUUID(message, "requestId")
            _ = try nonnegativeInteger(message, "mouseDownPostCount")
            _ = try nonnegativeInteger(message, "mouseUpPostCount")
        case "time.sync.response":
            try exact(message, ["type", "v", "syncId", "phoneSendUnixMs", "macReceiveUnixMs", "macSendUnixMs"])
            try validUUID(message, "syncId")
            let phone = try number(message, "phoneSendUnixMs")
            let receive = try number(message, "macReceiveUnixMs")
            let send = try number(message, "macSendUnixMs")
            guard phone > 0, receive > 0, send >= receive else { throw PhoneWireError.invalidValue }
        case "hello", "heartbeat.request", "time.sync.request", "action.request", "mac.state", "diagnostics.request":
            throw PhoneWireError.messageNotAllowed
        default:
            throw PhoneWireError.unknownType(type)
        }
    }

    private func exact(_ message: [String: Any], _ expectedFields: [String]) throws {
        let expected = Set(expectedFields)
        let extras = Set(message.keys).subtracting(expected).sorted()
        guard extras.isEmpty else { throw PhoneWireError.unknownKeys(extras) }
        guard expected.isSubset(of: message.keys) else { throw PhoneWireError.invalidValue }
    }

    private func string(_ message: [String: Any], _ key: String) throws -> String {
        guard let value = message[key] as? String else { throw PhoneWireError.invalidValue }
        return value
    }

    private func boolean(_ message: [String: Any], _ key: String) throws -> Bool {
        guard let value = message[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw PhoneWireError.invalidValue }
        return value.boolValue
    }

    private func number(_ message: [String: Any], _ key: String) throws -> Double {
        guard let value = message[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { throw PhoneWireError.invalidValue }
        return value.doubleValue
    }

    private func nonnegativeInteger(_ message: [String: Any], _ key: String) throws -> Int {
        let value = try number(message, key)
        guard value >= 0, value.rounded(.towardZero) == value, value <= Double(Int.max) else {
            throw PhoneWireError.invalidValue
        }
        return Int(value)
    }

    private func validUUID(_ message: [String: Any], _ key: String) throws {
        let value = try string(message, key)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard Self.uuid.firstMatch(in: value, range: range)?.range == range else {
            throw PhoneWireError.invalidValue
        }
    }

    private func oneOf(_ value: String, _ allowed: [String]) throws {
        guard allowed.contains(value) else { throw PhoneWireError.invalidValue }
    }
}

private extension PermissionState {
    static let allWireValues = ["ready", "required", "unknown"]
}

private extension RelayAckStatus {
    static let allWireValues = ["forwarded", "mac_offline", "rejected"]
}

private extension RelayAckReason {
    static let allWireValues = ["ok", "mac_offline", "expired", "invalid_request"]
}

private extension ResultStatus {
    static let allWireValues = ["posted", "rejected"]
}

private extension ActionIngress {
    static let allWireValues = ["oci", "tailscale"]
}
