import Foundation

enum PhoneProtocolV1 {
    static let version = 1
    static let maximumMessageBytes = 4_096
    static let actionLifetimeMilliseconds: Double = 2_000
    static let resultTimeout: TimeInterval = 4
    static let heartbeatInterval: TimeInterval = 20
    static let heartbeatTimeout: TimeInterval = 10
    static let reconnectBase: TimeInterval = 0.25
    static let reconnectCap: TimeInterval = 8
    static let clockSampleCount = 5
    static let clockExchangeTimeout: TimeInterval = 3.5
    static let clockRefreshInterval: TimeInterval = 300
    static let clockSkewToleranceMilliseconds: Double = 1_000
}

enum PermissionState: String, Codable, Sendable { case ready, required, unknown }
enum ResultStatus: String, Codable, Sendable { case posted, rejected }
enum ActionIngress: String, Codable, Sendable { case oci, tailscale }
enum RelayAckStatus: String, Codable, Sendable { case forwarded, macOffline = "mac_offline", rejected }
enum RelayAckReason: String, Codable, Sendable { case ok, macOffline = "mac_offline", expired, invalidRequest = "invalid_request" }

enum ResultReason: String, Codable, Sendable, CaseIterable {
    case ok
    case permissionRequired = "permission_required"
    case remoteDisabled = "remote_disabled"
    case idConflict = "id_conflict"
    case expired
    case capacityExceeded = "capacity_exceeded"
    case eventCreationFailed = "event_creation_failed"
    case invalidRequest = "invalid_request"
}

struct Hello: Codable, Equatable, Sendable {
    var type = "hello"
    var v = PhoneProtocolV1.version
    let role: String
    let token: String
}

struct HeartbeatRequest: Codable, Equatable, Sendable {
    var type = "heartbeat.request"
    var v = PhoneProtocolV1.version
    let sequence: Int
}

struct TimeSyncRequest: Codable, Equatable, Sendable {
    var type = "time.sync.request"
    var v = PhoneProtocolV1.version
    let syncID: UUID
    let phoneSendUnixMilliseconds: Double

    enum CodingKeys: String, CodingKey {
        case type, v
        case syncID = "syncId"
        case phoneSendUnixMilliseconds = "phoneSendUnixMs"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(v, forKey: .v)
        try values.encode(syncID.uuidString.lowercased(), forKey: .syncID)
        try values.encode(phoneSendUnixMilliseconds, forKey: .phoneSendUnixMilliseconds)
    }

    init(syncID: UUID, phoneSendUnixMilliseconds: Double) {
        self.syncID = syncID
        self.phoneSendUnixMilliseconds = phoneSendUnixMilliseconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        syncID = try decodeUUID(values, key: .syncID)
        phoneSendUnixMilliseconds = try values.decode(Double.self, forKey: .phoneSendUnixMilliseconds)
    }
}

struct ActionRequest: Codable, Equatable, Sendable {
    var type = "action.request"
    var v = PhoneProtocolV1.version
    let actionID: UUID
    let action: String
    let issuedAtUnixMilliseconds: Double
    let expiresAtUnixMilliseconds: Double

    enum CodingKeys: String, CodingKey {
        case type, v, action
        case actionID = "actionId"
        case issuedAtUnixMilliseconds = "issuedAtUnixMs"
        case expiresAtUnixMilliseconds = "expiresAtUnixMs"
    }

    init(actionID: UUID, action: String, issuedAtUnixMilliseconds: Double, expiresAtUnixMilliseconds: Double) {
        self.actionID = actionID
        self.action = action
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(v, forKey: .v)
        try values.encode(actionID.uuidString.lowercased(), forKey: .actionID)
        try values.encode(action, forKey: .action)
        try values.encode(issuedAtUnixMilliseconds, forKey: .issuedAtUnixMilliseconds)
        try values.encode(expiresAtUnixMilliseconds, forKey: .expiresAtUnixMilliseconds)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        actionID = try decodeUUID(values, key: .actionID)
        action = try values.decode(String.self, forKey: .action)
        issuedAtUnixMilliseconds = try values.decode(Double.self, forKey: .issuedAtUnixMilliseconds)
        expiresAtUnixMilliseconds = try values.decode(Double.self, forKey: .expiresAtUnixMilliseconds)
    }
}

struct HelloOK: Codable, Equatable, Sendable {
    var type = "hello.ok"
    var v = PhoneProtocolV1.version
    let role: String
}

struct HeartbeatAck: Codable, Equatable, Sendable {
    var type = "heartbeat.ack"
    var v = PhoneProtocolV1.version
    let sequence: Int
}

struct RelayState: Codable, Equatable, Sendable {
    var type = "state"
    var v = PhoneProtocolV1.version
    let macOnline: Bool
    let remoteEnabled: Bool
    let permission: PermissionState
}

struct RelayAck: Codable, Equatable, Sendable {
    var type = "relay.ack"
    var v = PhoneProtocolV1.version
    let actionID: UUID
    let status: RelayAckStatus
    let reason: RelayAckReason
    let relayProcessingMicroseconds: Double

    enum CodingKeys: String, CodingKey {
        case type, v, status, reason
        case actionID = "actionId"
        case relayProcessingMicroseconds = "relayProcessingUs"
    }

    init(actionID: UUID, status: RelayAckStatus, reason: RelayAckReason, relayProcessingMicroseconds: Double) {
        self.actionID = actionID
        self.status = status
        self.reason = reason
        self.relayProcessingMicroseconds = relayProcessingMicroseconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        actionID = try decodeUUID(values, key: .actionID)
        status = try values.decode(RelayAckStatus.self, forKey: .status)
        reason = try values.decode(RelayAckReason.self, forKey: .reason)
        relayProcessingMicroseconds = try values.decode(Double.self, forKey: .relayProcessingMicroseconds)
    }
}

struct TimeSyncResponse: Codable, Equatable, Sendable {
    var type = "time.sync.response"
    var v = PhoneProtocolV1.version
    let syncID: UUID
    let phoneSendUnixMilliseconds: Double
    let macReceiveUnixMilliseconds: Double
    let macSendUnixMilliseconds: Double

    enum CodingKeys: String, CodingKey {
        case type, v
        case syncID = "syncId"
        case phoneSendUnixMilliseconds = "phoneSendUnixMs"
        case macReceiveUnixMilliseconds = "macReceiveUnixMs"
        case macSendUnixMilliseconds = "macSendUnixMs"
    }

    init(syncID: UUID, phoneSendUnixMilliseconds: Double, macReceiveUnixMilliseconds: Double,
         macSendUnixMilliseconds: Double) {
        self.syncID = syncID
        self.phoneSendUnixMilliseconds = phoneSendUnixMilliseconds
        self.macReceiveUnixMilliseconds = macReceiveUnixMilliseconds
        self.macSendUnixMilliseconds = macSendUnixMilliseconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        syncID = try decodeUUID(values, key: .syncID)
        phoneSendUnixMilliseconds = try values.decode(Double.self, forKey: .phoneSendUnixMilliseconds)
        macReceiveUnixMilliseconds = try values.decode(Double.self, forKey: .macReceiveUnixMilliseconds)
        macSendUnixMilliseconds = try values.decode(Double.self, forKey: .macSendUnixMilliseconds)
    }
}

struct DiagnosticsCounters: Codable, Equatable, Sendable {
    var type = "diagnostics.counters"
    var v = PhoneProtocolV1.version
    let requestID: UUID
    let mouseDownPostCount: Int
    let mouseUpPostCount: Int

    enum CodingKeys: String, CodingKey {
        case type, v, mouseDownPostCount, mouseUpPostCount
        case requestID = "requestId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        requestID = try decodeUUID(values, key: .requestID)
        mouseDownPostCount = try values.decode(Int.self, forKey: .mouseDownPostCount)
        mouseUpPostCount = try values.decode(Int.self, forKey: .mouseUpPostCount)
    }
}

struct ActionResult: Codable, Equatable, Sendable {
    var type = "action.result"
    var v = PhoneProtocolV1.version
    let actionID: UUID
    let status: ResultStatus
    let reason: ResultReason
    let acceptedVia: ActionIngress
    let macProcessingMicroseconds: Double
    let mouseDownPostedUnixMilliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case type, v, status, reason, acceptedVia
        case actionID = "actionId"
        case macProcessingMicroseconds = "macProcessingUs"
        case mouseDownPostedUnixMilliseconds = "mouseDownPostedUnixMs"
    }

    init(actionID: UUID, status: ResultStatus, reason: ResultReason, acceptedVia: ActionIngress,
         macProcessingMicroseconds: Double, mouseDownPostedUnixMilliseconds: Double?) {
        self.actionID = actionID
        self.status = status
        self.reason = reason
        self.acceptedVia = acceptedVia
        self.macProcessingMicroseconds = macProcessingMicroseconds
        self.mouseDownPostedUnixMilliseconds = mouseDownPostedUnixMilliseconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        v = try values.decode(Int.self, forKey: .v)
        actionID = try decodeUUID(values, key: .actionID)
        status = try values.decode(ResultStatus.self, forKey: .status)
        reason = try values.decode(ResultReason.self, forKey: .reason)
        acceptedVia = try values.decode(ActionIngress.self, forKey: .acceptedVia)
        macProcessingMicroseconds = try values.decode(Double.self, forKey: .macProcessingMicroseconds)
        mouseDownPostedUnixMilliseconds = try values.decodeIfPresent(Double.self, forKey: .mouseDownPostedUnixMilliseconds)
    }
}

enum PhoneClientMessage: Equatable, Sendable {
    case hello(Hello)
    case heartbeatRequest(HeartbeatRequest)
    case timeSyncRequest(TimeSyncRequest)
    case actionRequest(ActionRequest)

    var actionID: UUID? {
        guard case .actionRequest(let request) = self else { return nil }
        return request.actionID
    }

    func encodedText() throws -> String {
        switch self {
        case .hello(let message): return try PhoneWireEncoder.encode(message)
        case .heartbeatRequest(let message): return try PhoneWireEncoder.encode(message)
        case .timeSyncRequest(let message): return try PhoneWireEncoder.encode(message)
        case .actionRequest(let message): return try PhoneWireEncoder.encode(message)
        }
    }
}

enum PhoneServerMessage: Equatable, Sendable {
    case helloOK(HelloOK)
    case heartbeatAck(HeartbeatAck)
    case state(RelayState)
    case relayAck(RelayAck)
    case actionResult(ActionResult)
    case diagnosticsCounters(DiagnosticsCounters)
    case timeSyncResponse(TimeSyncResponse)
}

enum PhoneWireError: Error, Equatable {
    case tooLarge
    case binaryFrame
    case notJSONObject
    case unsupportedVersion
    case unknownType(String)
    case unknownKeys([String])
    case messageNotAllowed
    case invalidValue
    case decodeFailed(String)
}

private enum PhoneWireEncoder {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard data.count <= PhoneProtocolV1.maximumMessageBytes else { throw PhoneWireError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}

private func decodeUUID<Key: CodingKey>(
    _ values: KeyedDecodingContainer<Key>,
    key: Key
) throws -> UUID {
    let rawValue = try values.decode(String.self, forKey: key)
    guard rawValue == rawValue.lowercased(), let value = UUID(uuidString: rawValue) else {
        throw PhoneWireError.invalidValue
    }
    return value
}
