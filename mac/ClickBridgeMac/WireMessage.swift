import Foundation

enum Constants {
    static let protocolVersion = 1
    static let maxMessageBytes = 4_096
    static let actionLifetimeMs: Double = 2_000
    static let clockSkewTolerance: TimeInterval = 1
    static let heartbeatInterval: TimeInterval = 20
    static let heartbeatTimeout: TimeInterval = 10
    static let macReconnectCap: TimeInterval = 5
    static let completedActionTTL: TimeInterval = 300
    static let completedActionCap = 4_096
    static let clickGapMs = 0
    static let clickRepetitions = 3
    static let pairingVersion = 1
    static let pairingTTL: TimeInterval = 300
    static let legacyPhoneCredentialVersion = 0
}

enum PermissionState: String, Codable, Sendable { case ready, required, unknown }
enum ResultStatus: String, Codable, Sendable { case posted, rejected }
enum ResultReason: String, Codable, Sendable {
    case ok
    case permissionRequired = "permission_required"
    case remoteDisabled = "remote_disabled"
    case idConflict = "id_conflict"
    case expired
    case capacityExceeded = "capacity_exceeded"
    case eventCreationFailed = "event_creation_failed"
    case invalidRequest = "invalid_request"
}
enum RelayAckStatus: String, Codable, Sendable { case forwarded, macOffline = "mac_offline", rejected }
enum RelayAckReason: String, Codable, Sendable { case ok, macOffline = "mac_offline", expired, invalidRequest = "invalid_request" }
enum WireRole: String, Sendable { case phone, mac }
enum PairingClientKind: String, Codable, Sendable { case ios, pwa }
enum PairingEnrollmentState: String, Codable, Sendable { case legacy, paired }
enum PairingFailureReason: String, Codable, Sendable {
    case expired, used, cancelled, denied
    case macOffline = "mac_offline"
    case storageFailed = "storage_failed"
    case activationFailed = "activation_failed"
    case invalidRequest = "invalid_request"
    case replaced, unsupported
}
enum PhoneEntryStatus: String, Codable, Sendable { case active }
enum PhoneRevokeFailureReason: String, Codable, Sendable {
    case unknownDevice = "unknown_device"
    case alreadyRevoked = "already_revoked"
    case storageFailed = "storage_failed"
}

struct Hello: Codable, Equatable, Sendable { var type = "hello"; var v = 1; var role: String; var token: String }
struct HelloOK: Codable, Equatable, Sendable { var type = "hello.ok"; var v = 1; var role: String }
struct HeartbeatRequest: Codable, Equatable, Sendable { var type = "heartbeat.request"; var v = 1; var sequence: Int }
struct HeartbeatAck: Codable, Equatable, Sendable { var type = "heartbeat.ack"; var v = 1; var sequence: Int }
struct TimeSyncRequest: Codable, Equatable, Sendable { var type = "time.sync.request"; var v = 1; var syncId: String; var phoneSendUnixMs: Double }
struct TimeSyncResponse: Codable, Equatable, Sendable {
    var type = "time.sync.response"; var v = 1; var syncId: String; var phoneSendUnixMs: Double
    var macReceiveUnixMs: Double; var macSendUnixMs: Double
}
struct DiagnosticsRequest: Codable, Equatable, Sendable { var type = "diagnostics.request"; var v = 1; var requestId: String }
struct DiagnosticsCounters: Codable, Equatable, Sendable {
    var type = "diagnostics.counters"; var v = 1; var requestId: String
    var mouseDownPostCount: Int; var mouseUpPostCount: Int
}
struct MacState: Codable, Equatable, Sendable { var type = "mac.state"; var v = 1; var remoteEnabled: Bool; var permission: PermissionState }
struct PhoneState: Codable, Equatable, Sendable {
    var type = "state"; var v = 1; var macOnline: Bool; var remoteEnabled: Bool; var permission: PermissionState
}
struct ActionRequest: Codable, Equatable, Sendable {
    var type = "action.request"; var v = 1; var actionId: String; var action: String
    var issuedAtUnixMs: Double; var expiresAtUnixMs: Double
    var fingerprint: String { "\(action)|\(issuedAtUnixMs)|\(expiresAtUnixMs)" }
}
struct RelayAck: Codable, Equatable, Sendable {
    var type = "relay.ack"; var v = 1; var actionId: String; var status: RelayAckStatus
    var reason: RelayAckReason; var relayProcessingUs: Double
}
struct ActionResult: Codable, Equatable, Sendable {
    var type = "action.result"; var v = 1; var actionId: String; var status: ResultStatus
    var reason: ResultReason; var acceptedVia: ActionIngress; var macProcessingUs: Double
    var mouseDownPostedUnixMs: Double?
}
struct PairCreate: Codable, Equatable, Sendable {
    var type = "pair.create"; var v = 1; var requestId: String; var pairingVersion = Constants.pairingVersion
}
struct PairStatusRequest: Codable, Equatable, Sendable {
    var type = "pair.status.request"; var v = 1; var requestId: String
    var pairingVersion = Constants.pairingVersion
}
struct PairCreated: Codable, Equatable, Sendable {
    var type = "pair.created"; var v = 1; var requestId: String; var reference: String; var expiresAtUnixMs: Int
}
struct PairStatus: Codable, Equatable, Sendable {
    var type = "pair.status"; var v = 1; var requestId: String
    var enrollmentState: PairingEnrollmentState; var activePhoneCredentialVersion: Int

    var requiresReplacementConfirmation: Bool {
        switch enrollmentState {
        case .legacy, .paired: true
        }
    }
}
struct PairCancel: Codable, Equatable, Sendable { var type = "pair.cancel"; var v = 1; var requestId: String }
struct PairClaimedMac: Codable, Equatable, Sendable {
    var type = "pair.claimed.mac"; var v = 1; var requestId: String; var claimId: String
    var confirmationCode: String; var expiresAtUnixMs: Int; var clientKind: PairingClientKind
}
struct PairApprove: Codable, Equatable, Sendable {
    var type = "pair.approve"; var v = 1; var requestId: String; var claimId: String
}
struct PairDeny: Codable, Equatable, Sendable {
    var type = "pair.deny"; var v = 1; var requestId: String; var claimId: String
}
struct PairCompleted: Codable, Equatable, Sendable {
    var type = "pair.completed"; var v = 1; var requestId: String; var claimId: String
    var activePhoneCredentialVersion: Int
}
struct PairFailed: Codable, Equatable, Sendable {
    var type = "pair.failed"; var v = 1; var requestId: String?; var claimId: String?
    var reason: PairingFailureReason
}
struct PhoneListRequest: Codable, Equatable, Sendable {
    var type = "phone.list.request"; var v = 1; var requestId: String
}
struct PhoneListEntry: Codable, Equatable, Sendable {
    var deviceId: String; var label: String; var status: PhoneEntryStatus; var credentialVersion: Int
}
struct PhoneList: Codable, Equatable, Sendable {
    var type = "phone.list"; var v = 1; var requestId: String
    var registryRevision: Int; var phones: [PhoneListEntry]
}
struct PhoneRevokeRequest: Codable, Equatable, Sendable {
    var type = "phone.revoke.request"; var v = 1; var requestId: String; var deviceId: String
}
struct PhoneRevoked: Codable, Equatable, Sendable {
    var type = "phone.revoked"; var v = 1; var requestId: String; var deviceId: String; var registryRevision: Int
}
struct PhoneRevokeFailed: Codable, Equatable, Sendable {
    var type = "phone.revoke.failed"; var v = 1; var requestId: String; var deviceId: String
    var reason: PhoneRevokeFailureReason
}

private protocol WireEncodingValidatable {
    func validateForWireEncoding() throws
}

private enum PairingWireEncoding {
    static let maximumSafeInteger = 9_007_199_254_740_991

    static func envelope(type: String, expectedType: String, version: Int) throws {
        guard type == expectedType, version == Constants.protocolVersion else {
            throw WireError.invalidValue
        }
    }

    static func uuid(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            throw WireError.invalidValue
        }
    }

    static func positiveSafeInteger(_ value: Int) throws {
        guard value > 0, value <= maximumSafeInteger else { throw WireError.invalidValue }
    }

    static func nonNegativeSafeInteger(_ value: Int) throws {
        guard value >= 0, value <= maximumSafeInteger else { throw WireError.invalidValue }
    }

    static func pairingVersion(_ value: Int) throws {
        guard value == Constants.pairingVersion else { throw WireError.invalidValue }
    }

    static func confirmationCode(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 7,
              bytes[3] == 32,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 3 || (48...57).contains(byte)
              }) else { throw WireError.invalidValue }
    }

    static func deviceId(_ value: String) throws {
        guard (16...64).contains(value.count),
              value.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value)
                      || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
              }) else { throw WireError.invalidValue }
    }

    static func label(_ value: String) throws {
        guard (1...64).contains(value.utf8.count) else { throw WireError.invalidValue }
    }

    static func reference(_ value: String) throws {
        guard value.count == 43,
              value.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value)
                      || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
              }) else { throw WireError.invalidValue }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: standard), decoded.count == 32 else {
            throw WireError.invalidValue
        }
        let canonical = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonical == value else { throw WireError.invalidValue }
    }
}

extension PairCreate: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.create", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.pairingVersion(pairingVersion)
    }
}

extension PairStatusRequest: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.status.request", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.pairingVersion(pairingVersion)
    }
}

extension PairCreated: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.created", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.reference(reference)
        try PairingWireEncoding.positiveSafeInteger(expiresAtUnixMs)
    }
}

extension PairStatus: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.status", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.nonNegativeSafeInteger(activePhoneCredentialVersion)
        let isConsistent = enrollmentState == .legacy
            ? activePhoneCredentialVersion == Constants.legacyPhoneCredentialVersion
            : activePhoneCredentialVersion > Constants.legacyPhoneCredentialVersion
        guard isConsistent else { throw WireError.invalidValue }
    }
}

extension PairCancel: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.cancel", version: v)
        try PairingWireEncoding.uuid(requestId)
    }
}

extension PairClaimedMac: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.claimed.mac", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.uuid(claimId)
        try PairingWireEncoding.confirmationCode(confirmationCode)
        try PairingWireEncoding.positiveSafeInteger(expiresAtUnixMs)
    }
}

extension PairApprove: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.approve", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.uuid(claimId)
    }
}

extension PairDeny: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.deny", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.uuid(claimId)
    }
}

extension PairCompleted: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.completed", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.uuid(claimId)
        try PairingWireEncoding.positiveSafeInteger(activePhoneCredentialVersion)
    }
}

extension PairFailed: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "pair.failed", version: v)
        guard requestId != nil || claimId != nil else { throw WireError.invalidValue }
        if let requestId { try PairingWireEncoding.uuid(requestId) }
        if let claimId { try PairingWireEncoding.uuid(claimId) }
    }
}

extension PhoneListRequest: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "phone.list.request", version: v)
        try PairingWireEncoding.uuid(requestId)
    }
}

extension PhoneList: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "phone.list", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.nonNegativeSafeInteger(registryRevision)
        for phone in phones {
            try PairingWireEncoding.deviceId(phone.deviceId)
            try PairingWireEncoding.label(phone.label)
            try PairingWireEncoding.nonNegativeSafeInteger(phone.credentialVersion)
        }
    }
}

extension PhoneRevokeRequest: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "phone.revoke.request", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.deviceId(deviceId)
    }
}

extension PhoneRevoked: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "phone.revoked", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.deviceId(deviceId)
        try PairingWireEncoding.nonNegativeSafeInteger(registryRevision)
    }
}

extension PhoneRevokeFailed: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        try PairingWireEncoding.envelope(type: type, expectedType: "phone.revoke.failed", version: v)
        try PairingWireEncoding.uuid(requestId)
        try PairingWireEncoding.deviceId(deviceId)
    }
}

enum WireMessage: Equatable, Codable, Sendable {
    case hello(Hello), helloOK(HelloOK)
    case heartbeatRequest(HeartbeatRequest), heartbeatAck(HeartbeatAck)
    case timeSyncRequest(TimeSyncRequest), timeSyncResponse(TimeSyncResponse)
    case diagnosticsRequest(DiagnosticsRequest), diagnosticsCounters(DiagnosticsCounters)
    case macState(MacState), state(PhoneState), actionRequest(ActionRequest)
    case relayAck(RelayAck), actionResult(ActionResult)
    case pairCreate(PairCreate), pairStatusRequest(PairStatusRequest), pairCreated(PairCreated)
    case pairStatus(PairStatus), pairCancel(PairCancel)
    case pairClaimedMac(PairClaimedMac), pairApprove(PairApprove), pairDeny(PairDeny)
    case pairCompleted(PairCompleted), pairFailed(PairFailed)
    case phoneListRequest(PhoneListRequest), phoneList(PhoneList)
    case phoneRevokeRequest(PhoneRevokeRequest), phoneRevoked(PhoneRevoked), phoneRevokeFailed(PhoneRevokeFailed)

    private enum CodingKeys: String, CodingKey { case type }
    private struct Kind: Decodable { let type: String }

    init(from decoder: Decoder) throws {
        let kind = try Kind(from: decoder).type
        switch kind {
        case "hello": self = .hello(try Hello(from: decoder))
        case "hello.ok": self = .helloOK(try HelloOK(from: decoder))
        case "heartbeat.request": self = .heartbeatRequest(try HeartbeatRequest(from: decoder))
        case "heartbeat.ack": self = .heartbeatAck(try HeartbeatAck(from: decoder))
        case "time.sync.request": self = .timeSyncRequest(try TimeSyncRequest(from: decoder))
        case "time.sync.response": self = .timeSyncResponse(try TimeSyncResponse(from: decoder))
        case "diagnostics.request": self = .diagnosticsRequest(try DiagnosticsRequest(from: decoder))
        case "diagnostics.counters": self = .diagnosticsCounters(try DiagnosticsCounters(from: decoder))
        case "mac.state": self = .macState(try MacState(from: decoder))
        case "state": self = .state(try PhoneState(from: decoder))
        case "action.request": self = .actionRequest(try ActionRequest(from: decoder))
        case "relay.ack": self = .relayAck(try RelayAck(from: decoder))
        case "action.result": self = .actionResult(try ActionResult(from: decoder))
        case "pair.create": self = .pairCreate(try PairCreate(from: decoder))
        case "pair.status.request": self = .pairStatusRequest(try PairStatusRequest(from: decoder))
        case "pair.created": self = .pairCreated(try PairCreated(from: decoder))
        case "pair.status": self = .pairStatus(try PairStatus(from: decoder))
        case "pair.cancel": self = .pairCancel(try PairCancel(from: decoder))
        case "pair.claimed.mac": self = .pairClaimedMac(try PairClaimedMac(from: decoder))
        case "pair.approve": self = .pairApprove(try PairApprove(from: decoder))
        case "pair.deny": self = .pairDeny(try PairDeny(from: decoder))
        case "pair.completed": self = .pairCompleted(try PairCompleted(from: decoder))
        case "pair.failed": self = .pairFailed(try PairFailed(from: decoder))
        case "phone.list.request": self = .phoneListRequest(try PhoneListRequest(from: decoder))
        case "phone.list": self = .phoneList(try PhoneList(from: decoder))
        case "phone.revoke.request": self = .phoneRevokeRequest(try PhoneRevokeRequest(from: decoder))
        case "phone.revoked": self = .phoneRevoked(try PhoneRevoked(from: decoder))
        case "phone.revoke.failed": self = .phoneRevokeFailed(try PhoneRevokeFailed(from: decoder))
        default: throw WireError.unknownType(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let value): try value.encode(to: encoder)
        case .helloOK(let value): try value.encode(to: encoder)
        case .heartbeatRequest(let value): try value.encode(to: encoder)
        case .heartbeatAck(let value): try value.encode(to: encoder)
        case .timeSyncRequest(let value): try value.encode(to: encoder)
        case .timeSyncResponse(let value): try value.encode(to: encoder)
        case .diagnosticsRequest(let value): try value.encode(to: encoder)
        case .diagnosticsCounters(let value): try value.encode(to: encoder)
        case .macState(let value): try value.encode(to: encoder)
        case .state(let value): try value.encode(to: encoder)
        case .actionRequest(let value): try value.encode(to: encoder)
        case .relayAck(let value): try value.encode(to: encoder)
        case .actionResult(let value): try value.encode(to: encoder)
        case .pairCreate(let value): try value.encode(to: encoder)
        case .pairStatusRequest(let value): try value.encode(to: encoder)
        case .pairCreated(let value): try value.encode(to: encoder)
        case .pairStatus(let value): try value.encode(to: encoder)
        case .pairCancel(let value): try value.encode(to: encoder)
        case .pairClaimedMac(let value): try value.encode(to: encoder)
        case .pairApprove(let value): try value.encode(to: encoder)
        case .pairDeny(let value): try value.encode(to: encoder)
        case .pairCompleted(let value): try value.encode(to: encoder)
        case .pairFailed(let value): try value.encode(to: encoder)
        case .phoneListRequest(let value): try value.encode(to: encoder)
        case .phoneList(let value): try value.encode(to: encoder)
        case .phoneRevokeRequest(let value): try value.encode(to: encoder)
        case .phoneRevoked(let value): try value.encode(to: encoder)
        case .phoneRevokeFailed(let value): try value.encode(to: encoder)
        }
    }
}

extension WireMessage: WireEncodingValidatable {
    fileprivate func validateForWireEncoding() throws {
        switch self {
        case .pairCreate(let value): try value.validateForWireEncoding()
        case .pairStatusRequest(let value): try value.validateForWireEncoding()
        case .pairCreated(let value): try value.validateForWireEncoding()
        case .pairStatus(let value): try value.validateForWireEncoding()
        case .pairCancel(let value): try value.validateForWireEncoding()
        case .pairClaimedMac(let value): try value.validateForWireEncoding()
        case .pairApprove(let value): try value.validateForWireEncoding()
        case .pairDeny(let value): try value.validateForWireEncoding()
        case .pairCompleted(let value): try value.validateForWireEncoding()
        case .pairFailed(let value): try value.validateForWireEncoding()
        case .phoneListRequest(let value): try value.validateForWireEncoding()
        case .phoneList(let value): try value.validateForWireEncoding()
        case .phoneRevokeRequest(let value): try value.validateForWireEncoding()
        case .phoneRevoked(let value): try value.validateForWireEncoding()
        case .phoneRevokeFailed(let value): try value.validateForWireEncoding()
        default: break
        }
    }
}

enum WireError: Error, Equatable {
    case tooLarge, binaryFrame, notJSONObject, missingType, unsupportedVersion
    case unknownType(String), unknownKeys([String]), invalidRole(String), messageNotAllowed, invalidValue
    case decodeFailed(String)
}

enum Wire {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; return encoder
    }()

    static func decode(_ text: String) throws -> WireMessage { try StrictWireDecoder().decodeText(text) }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        if let validatable = value as? any WireEncodingValidatable {
            try validatable.validateForWireEncoding()
        }
        let data = try encoder.encode(value)
        guard data.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}
