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
    static let credentialReplacedCloseCode = 4_004
    static let credentialReplacedCloseReason = "credential_replaced"
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
    let type = "pair.approve"; let v = 1; var requestId: String; var claimId: String
}
struct PairDeny: Codable, Equatable, Sendable {
    let type = "pair.deny"; let v = 1; var requestId: String; var claimId: String
}
struct PairCompleted: Codable, Equatable, Sendable {
    var type = "pair.completed"; var v = 1; var requestId: String; var claimId: String
    var activePhoneCredentialVersion: Int
}
struct PairFailed: Codable, Equatable, Sendable {
    var type = "pair.failed"; var v = 1; var requestId: String?; var claimId: String?
    var reason: PairingFailureReason
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
        let data = try encoder.encode(value)
        guard data.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}
