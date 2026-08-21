import CoreFoundation
import Foundation

struct StrictPhoneWireDecoder: Sendable {
    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    )
    private static let token = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    private static let confirmationCode = try! NSRegularExpression(pattern: "^[0-9]{3} [0-9]{3}$")
    private let decoder = JSONDecoder()

    func rejectBinary(_ data: Data) throws -> Never {
        throw PhoneWireError.binaryFrame
    }

    func decodeText(_ text: String) throws -> PhoneServerMessage {
        try decode(text, pairingContext: nil, activeGeneration: nil)
    }

    func decodePairingText(
        _ text: String,
        context: PhonePairingReceiveContext,
        activeGeneration: UInt64
    ) throws -> PhoneServerMessage {
        try decode(text, pairingContext: context, activeGeneration: activeGeneration)
    }

    private func decode(
        _ text: String,
        pairingContext: PhonePairingReceiveContext?,
        activeGeneration: UInt64?
    ) throws -> PhoneServerMessage {
        let data = Data(text.utf8)
        guard data.count <= PhoneProtocolV1.maximumMessageBytes else { throw PhoneWireError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else { throw PhoneWireError.notJSONObject }

        let type = try string(message, "type")
        guard try number(message, "v") == Double(PhoneProtocolV1.version) else {
            throw PhoneWireError.unsupportedVersion
        }

        try validateReceiveContext(
            message,
            type: type,
            pairingContext: pairingContext,
            activeGeneration: activeGeneration
        )
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
            case "pair.claimed.phone": return .pairClaimedPhone(try decoder.decode(PairClaimedPhone.self, from: data))
            case "pair.credential": return .pairCredential(try decoder.decode(PairCredential.self, from: data))
            case "pair.active": return .pairActive(try decoder.decode(PairActive.self, from: data))
            case "pair.failed": return .pairFailed(try decoder.decode(PairFailedClaimant.self, from: data))
            default: throw PhoneWireError.messageNotAllowed
            }
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError.decodeFailed(type)
        }
    }

    private func validateReceiveContext(
        _ message: [String: Any],
        type: String,
        pairingContext: PhonePairingReceiveContext?,
        activeGeneration: UInt64?
    ) throws {
        let pairingTypes = Set([
            "pair.claimed.phone", "pair.credential", "pair.active", "pair.failed",
        ])
        guard let pairingContext else {
            guard !pairingTypes.contains(type) else { throw PhoneWireError.messageNotAllowed }
            return
        }
        guard activeGeneration == pairingContext.generation else {
            throw PhoneWireError.messageNotAllowed
        }
        let allowed: Set<String>
        switch pairingContext.state {
        case .claiming: allowed = ["pair.claimed.phone", "pair.failed"]
        case .awaitingCredential: allowed = ["pair.credential", "pair.failed"]
        case .awaitingActivation: allowed = ["pair.active", "pair.failed"]
        }
        guard allowed.contains(type),
              try string(message, "claimId") == pairingContext.claimID.uuidString.lowercased() else {
            throw PhoneWireError.messageNotAllowed
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
            // Allow optional desktop inventory fields for multi-desktop fan-out (2 Windows + 1 Mac etc.)
            let allowedState = Set(["type", "v", "macOnline", "remoteEnabled", "permission", "desktops", "desktopCount", "macCount", "windowsCount"])
            let extrasState = Set(message.keys).subtracting(allowedState)
            guard extrasState.isEmpty else { throw PhoneWireError.unknownKeys(Array(extrasState).sorted()) }
            guard Set(["type", "v", "macOnline", "remoteEnabled", "permission"]).isSubset(of: Set(message.keys)) else { throw PhoneWireError.invalidValue }
            _ = try boolean(message, "macOnline")
            _ = try boolean(message, "remoteEnabled")
            try oneOf(string(message, "permission"), PermissionState.allWireValues)
            if let desktops = message["desktops"] as? [[String: Any]] {
                for d in desktops {
                    let allowedD = Set(["id", "platform", "remoteEnabled", "permission"])
                    let extraD = Set(d.keys).subtracting(allowedD)
                    guard extraD.isEmpty else { throw PhoneWireError.unknownKeys(Array(extraD).sorted()) }
                    guard Set(["id", "platform", "remoteEnabled", "permission"]).isSubset(of: Set(d.keys)) else { throw PhoneWireError.invalidValue }
                    _ = try string(d, "platform"); try oneOf(try string(d, "platform"), ["mac", "windows"])
                    _ = try boolean(d, "remoteEnabled")
                    try oneOf(try string(d, "permission"), PermissionState.allWireValues)
                    guard let id = d["id"] as? String, !id.isEmpty, id.count <= 64 else { throw PhoneWireError.invalidValue }
                }
            } else if message["desktops"] != nil { throw PhoneWireError.invalidValue }
            if let _ = message["desktopCount"] { _ = try nonnegativeInteger(message, "desktopCount") }
            if let _ = message["macCount"] { _ = try nonnegativeInteger(message, "macCount") }
            if let _ = message["windowsCount"] { _ = try nonnegativeInteger(message, "windowsCount") }
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
        case "pair.claimed.phone":
            try exact(message, ["type", "v", "claimId", "confirmationCode", "expiresAtUnixMs"])
            try validUUID(message, "claimId")
            guard matches(Self.confirmationCode, try string(message, "confirmationCode")),
                  try safeNonnegativeInteger(message, "expiresAtUnixMs") > 0 else { throw PhoneWireError.invalidValue }
        case "pair.credential":
            try exact(message, ["type", "v", "claimId", "credential", "credentialVersion"])
            try validUUID(message, "claimId")
            guard matches(Self.token, try string(message, "credential")) else { throw PhoneWireError.invalidValue }
            guard try safeNonnegativeInteger(message, "credentialVersion") > 0 else {
                throw PhoneWireError.invalidValue
            }
        case "pair.active":
            try exact(message, ["type", "v", "claimId", "activePhoneCredentialVersion"])
            try validUUID(message, "claimId")
            guard try safeNonnegativeInteger(message, "activePhoneCredentialVersion") > 0 else {
                throw PhoneWireError.invalidValue
            }
        case "pair.failed":
            try exact(message, ["type", "v", "claimId", "reason"])
            try validUUID(message, "claimId")
            try oneOf(string(message, "reason"), PairingFailureReason.allCases.map(\.rawValue))
        case "hello", "heartbeat.request", "time.sync.request", "action.request", "mac.state", "diagnostics.request",
             "pair.create", "pair.status.request", "pair.created", "pair.status", "pair.cancel", "pair.claim", "pair.claimed.mac",
             "pair.approve", "pair.deny", "pair.credential.ack", "pair.completed", "pair.cancel.claim":
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
        guard value >= 0,
              value.rounded(.towardZero) == value,
              let integer = Int(exactly: value) else {
            throw PhoneWireError.invalidValue
        }
        return integer
    }

    private func validUUID(_ message: [String: Any], _ key: String) throws {
        let value = try string(message, key)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard Self.uuid.firstMatch(in: value, range: range)?.range == range else {
            throw PhoneWireError.invalidValue
        }
    }

    private func safeNonnegativeInteger(_ message: [String: Any], _ key: String) throws -> Int {
        let value = try number(message, key)
        guard value >= 0,
              value.rounded(.towardZero) == value,
              value <= 9_007_199_254_740_991,
              let integer = Int(exactly: value) else { throw PhoneWireError.invalidValue }
        return integer
    }

    private func oneOf(_ value: String, _ allowed: [String]) throws {
        guard allowed.contains(value) else { throw PhoneWireError.invalidValue }
    }

    private func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
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
