import Foundation
import CoreFoundation

struct StrictWireDecoder: Sendable {
    private let decoder = JSONDecoder()
    private static let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private static let token = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    private static let confirmationCode = try! NSRegularExpression(pattern: "^[0-9]{3} [0-9]{3}$")
    private static let deviceId = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{16,64}$")

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
        case "pair.create":
            try exact(message, ["type", "v", "requestId", "pairingVersion"])
            try uuid(message, "requestId")
            try pairingVersion(message)
        case "pair.status.request":
            try exact(message, ["type", "v", "requestId", "pairingVersion"])
            try uuid(message, "requestId")
            try pairingVersion(message)
        case "pair.created":
            try exact(message, ["type", "v", "requestId", "reference", "expiresAtUnixMs"])
            try uuid(message, "requestId")
            guard Self.isCanonicalPairingReference(try string(message, "reference")) else {
                throw WireError.invalidValue
            }
            try positiveInteger(message, "expiresAtUnixMs")
        case "pair.status":
            try exact(message, ["type", "v", "requestId", "enrollmentState", "activePhoneCredentialVersion"])
            try uuid(message, "requestId")
            let enrollmentState = try string(message, "enrollmentState")
            try oneOf(enrollmentState, ["legacy", "paired"])
            let credentialVersion = try safeNonNegativeInteger(message, "activePhoneCredentialVersion")
            let isConsistent = enrollmentState == "legacy"
                ? credentialVersion == Constants.legacyPhoneCredentialVersion
                : credentialVersion > Constants.legacyPhoneCredentialVersion
            guard isConsistent else { throw WireError.invalidValue }
        case "pair.cancel":
            try exact(message, ["type", "v", "requestId"])
            try uuid(message, "requestId")
        case "pair.claimed.mac":
            try exact(message, ["type", "v", "requestId", "claimId", "confirmationCode", "expiresAtUnixMs", "clientKind"])
            try uuid(message, "requestId")
            try uuid(message, "claimId")
            guard Self.matches(Self.confirmationCode, try string(message, "confirmationCode")) else { throw WireError.invalidValue }
            try positiveInteger(message, "expiresAtUnixMs")
            try oneOf(string(message, "clientKind"), ["ios", "pwa"])
        case "pair.approve", "pair.deny":
            try exact(message, ["type", "v", "requestId", "claimId"])
            try uuid(message, "requestId")
            try uuid(message, "claimId")
        case "pair.completed":
            try exact(message, ["type", "v", "requestId", "claimId", "activePhoneCredentialVersion"])
            try uuid(message, "requestId")
            try uuid(message, "claimId")
            guard try safeNonNegativeInteger(message, "activePhoneCredentialVersion") > 0 else {
                throw WireError.invalidValue
            }
        case "pair.failed":
            var fields = ["type", "v", "requestId", "reason"]
            if message["claimId"] != nil { fields.insert("claimId", at: 3) }
            try exact(message, fields)
            try uuid(message, "requestId")
            if message["claimId"] != nil { try uuid(message, "claimId") }
            try oneOf(string(message, "reason"), PairingFailureReason.allWireValues)
        case "pair.claim", "pair.claimed.phone", "pair.credential", "pair.credential.ack",
             "pair.active", "pair.cancel.claim":
            throw WireError.messageNotAllowed
        case "phone.list.request":
            try exact(message, ["type", "v", "requestId"])
            try uuid(message, "requestId")
        case "phone.list":
            try exact(message, ["type", "v", "requestId", "registryRevision", "phones"])
            try uuid(message, "requestId")
            _ = try safeNonNegativeInteger(message, "registryRevision")
            guard let phones = message["phones"] as? [[String: Any]] else { throw WireError.invalidValue }
            for phone in phones {
                try exact(phone, ["credentialVersion", "deviceId", "label", "status"])
                try deviceId(phone, "deviceId")
                let label = try string(phone, "label")
                guard (1...64).contains(label.utf8.count) else { throw WireError.invalidValue }
                try oneOf(string(phone, "status"), ["active"])
                _ = try safeNonNegativeInteger(phone, "credentialVersion")
            }
        case "phone.revoke.request":
            try exact(message, ["type", "v", "requestId", "deviceId"])
            try uuid(message, "requestId")
            try deviceId(message, "deviceId")
        case "phone.revoked":
            try exact(message, ["type", "v", "requestId", "deviceId", "registryRevision"])
            try uuid(message, "requestId")
            try deviceId(message, "deviceId")
            _ = try safeNonNegativeInteger(message, "registryRevision")
        case "phone.revoke.failed":
            try exact(message, ["type", "v", "requestId", "deviceId", "reason"])
            try uuid(message, "requestId")
            try deviceId(message, "deviceId")
            try oneOf(string(message, "reason"), ["unknown_device", "already_revoked", "storage_failed"])
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
        guard value >= 0,
              value.rounded(.towardZero) == value,
              let integer = Int(exactly: value) else {
            throw WireError.invalidValue
        }
        return integer
    }

    private func positiveInteger(_ message: [String: Any], _ key: String) throws {
        guard try safeNonNegativeInteger(message, key) > 0 else { throw WireError.invalidValue }
    }

    private func safeNonNegativeInteger(_ message: [String: Any], _ key: String) throws -> Int {
        let value = try number(message, key)
        guard value >= 0,
              value.rounded(.towardZero) == value,
              value <= 9_007_199_254_740_991,
              let integer = Int(exactly: value) else { throw WireError.invalidValue }
        return integer
    }

    private func pairingVersion(_ message: [String: Any]) throws {
        guard try safeNonNegativeInteger(message, "pairingVersion") == Constants.pairingVersion else {
            throw WireError.invalidValue
        }
    }

    private func uuid(_ message: [String: Any], _ key: String) throws {
        guard Self.matches(Self.uuid, try string(message, key)) else { throw WireError.invalidValue }
    }

    private func deviceId(_ message: [String: Any], _ key: String) throws {
        guard Self.matches(Self.deviceId, try string(message, key)) else { throw WireError.invalidValue }
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

    private static func isCanonicalPairingReference(_ value: String) -> Bool {
        guard value.count == 43,
              value.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value)
                      || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
              }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: standard), decoded.count == 32 else { return false }
        let canonical = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value
    }

    private func validate(_ message: WireMessage, allowedFor role: WireRole) throws {
        let allowed: Bool
        switch (role, message) {
        case (.mac, .helloOK(let hello)): allowed = hello.role == "mac"
        case (.mac, .heartbeatAck), (.mac, .actionRequest), (.mac, .timeSyncRequest), (.mac, .diagnosticsRequest): allowed = true
        case (.mac, .pairCreated), (.mac, .pairStatus), (.mac, .pairClaimedMac), (.mac, .pairCompleted),
             (.mac, .pairFailed): allowed = true
        case (.mac, .phoneList), (.mac, .phoneRevoked), (.mac, .phoneRevokeFailed): allowed = true
        case (.phone, .helloOK(let hello)): allowed = hello.role == "phone"
        case (.phone, .heartbeatAck), (.phone, .state), (.phone, .relayAck), (.phone, .actionResult),
             (.phone, .timeSyncResponse), (.phone, .diagnosticsCounters): allowed = true
        default: allowed = false
        }
        guard allowed else { throw WireError.messageNotAllowed }
    }
}

private extension PairingFailureReason {
    static let allWireValues = [
        "expired", "used", "cancelled", "denied", "mac_offline", "storage_failed",
        "activation_failed", "invalid_request", "replaced", "unsupported",
    ]
}

private extension ResultReason {
    static let allWireValues = [
        "ok", "permission_required", "remote_disabled", "expired", "capacity_exceeded",
        "id_conflict", "event_creation_failed", "invalid_request",
    ]
}
