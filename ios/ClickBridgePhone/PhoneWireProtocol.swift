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
    static let phoneTakenOverCloseCode = 4_004
    static let clockSampleCount = 5
    static let clockExchangeTimeout: TimeInterval = 3.5
    static let clockRefreshInterval: TimeInterval = 300
    static let clockSkewToleranceMilliseconds: Double = 1_000
    static let pairingVersion = 1
    static let pairingTTL: TimeInterval = 300
    static let credentialReplacedCloseCode = 4_004
    static let credentialReplacedCloseReason = "credential_replaced"
}

enum PermissionState: String, Codable, Sendable { case ready, required, unknown }
enum ResultStatus: String, Codable, Sendable { case posted, rejected }
enum ActionIngress: String, Codable, Sendable { case oci, tailscale }
enum RelayAckStatus: String, Codable, Sendable { case forwarded, macOffline = "mac_offline", rejected }
enum RelayAckReason: String, Codable, Sendable { case ok, macOffline = "mac_offline", expired, invalidRequest = "invalid_request" }
enum PairingClientKind: String, Codable, Sendable { case ios, pwa }
enum PhonePairingReceiveState: String, Sendable {
    case claiming
    case awaitingCredential = "awaiting_credential"
    case awaitingActivation = "awaiting_activation"
}
struct PhonePairingReceiveContext: Equatable, Sendable {
    let claimID: UUID
    let generation: UInt64
    let state: PhonePairingReceiveState
}
enum PairingFailureReason: String, Codable, Sendable, CaseIterable {
    case expired, used, cancelled, denied
    case macOffline = "mac_offline"
    case storageFailed = "storage_failed"
    case activationFailed = "activation_failed"
    case invalidRequest = "invalid_request"
    case replaced, unsupported
}

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

struct PairClaim: Codable, Equatable, Sendable {
    var type = "pair.claim"
    var v = PhoneProtocolV1.version
    let reference: String
    let claimID: UUID
    let sessionNonce: String
    var pairingVersion = PhoneProtocolV1.pairingVersion
    let clientKind: PairingClientKind

    enum CodingKeys: String, CodingKey {
        case type, v, reference, sessionNonce, pairingVersion, clientKind
        case claimID = "claimId"
    }

    func encode(to encoder: Encoder) throws {
        guard type == "pair.claim",
              v == PhoneProtocolV1.version,
              pairingVersion == PhoneProtocolV1.pairingVersion,
              isCanonicalPairingReference(reference),
              isLowercaseHex64(sessionNonce) else { throw PhoneWireError.invalidValue }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(v, forKey: .v)
        try values.encode(reference, forKey: .reference)
        try values.encode(claimID.uuidString.lowercased(), forKey: .claimID)
        try values.encode(sessionNonce, forKey: .sessionNonce)
        try values.encode(pairingVersion, forKey: .pairingVersion)
        try values.encode(clientKind, forKey: .clientKind)
    }
}

struct PairCredentialAcknowledgement: Codable, Equatable, Sendable {
    var type = "pair.credential.ack"
    var v = PhoneProtocolV1.version
    let claimID: UUID
    let credentialVersion: Int
    let proof: String

    enum CodingKeys: String, CodingKey { case type, v, credentialVersion, proof; case claimID = "claimId" }

    func encode(to encoder: Encoder) throws {
        guard type == "pair.credential.ack",
              v == PhoneProtocolV1.version,
              credentialVersion > 0,
              credentialVersion <= 9_007_199_254_740_991,
              isLowercaseHex64(proof) else { throw PhoneWireError.invalidValue }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(v, forKey: .v)
        try values.encode(claimID.uuidString.lowercased(), forKey: .claimID)
        try values.encode(credentialVersion, forKey: .credentialVersion)
        try values.encode(proof, forKey: .proof)
    }
}

struct PairCancelClaim: Codable, Equatable, Sendable {
    var type = "pair.cancel.claim"
    var v = PhoneProtocolV1.version
    let claimID: UUID

    enum CodingKeys: String, CodingKey { case type, v; case claimID = "claimId" }

    func encode(to encoder: Encoder) throws {
        guard type == "pair.cancel.claim",
              v == PhoneProtocolV1.version else { throw PhoneWireError.invalidValue }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(v, forKey: .v)
        try values.encode(claimID.uuidString.lowercased(), forKey: .claimID)
    }
}

struct PairClaimedPhone: Codable, Equatable, Sendable {
    var type = "pair.claimed.phone"; var v = PhoneProtocolV1.version; let claimId: String
    let confirmationCode: String; let expiresAtUnixMs: Int
}
struct PairCredential: Codable, Equatable, Sendable {
    var type = "pair.credential"; var v = PhoneProtocolV1.version; let claimId: String
    let credential: String; let credentialVersion: Int
}
struct PairActive: Codable, Equatable, Sendable {
    var type = "pair.active"; var v = PhoneProtocolV1.version; let claimId: String
    let activePhoneCredentialVersion: Int
}
struct PairFailedClaimant: Codable, Equatable, Sendable {
    var type = "pair.failed"; var v = PhoneProtocolV1.version; let claimId: String
    let reason: PairingFailureReason
}

enum PhoneClientMessage: Equatable, Sendable {
    case hello(Hello)
    case heartbeatRequest(HeartbeatRequest)
    case timeSyncRequest(TimeSyncRequest)
    case actionRequest(ActionRequest)
    case pairClaim(PairClaim)
    case pairCredentialAcknowledgement(PairCredentialAcknowledgement)
    case pairCancelClaim(PairCancelClaim)

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
        case .pairClaim(let message): return try PhoneWireEncoder.encode(message)
        case .pairCredentialAcknowledgement(let message): return try PhoneWireEncoder.encode(message)
        case .pairCancelClaim(let message): return try PhoneWireEncoder.encode(message)
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
    case pairClaimedPhone(PairClaimedPhone)
    case pairCredential(PairCredential)
    case pairActive(PairActive)
    case pairFailed(PairFailedClaimant)
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

private func isCanonicalPairingReference(_ value: String) -> Bool {
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

private func isLowercaseHex64(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}
