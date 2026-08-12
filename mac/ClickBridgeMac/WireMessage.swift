import Foundation

enum Constants {
    static let protocolVersion = 1
    static let maxMessageBytes = 4096
    static let actionLifetimeMs: Double = 2000
    static let clockSkewTolerance: TimeInterval = 1.0
    static let heartbeatInterval: TimeInterval = 20
    static let heartbeatTimeout: TimeInterval = 10
    static let macReconnectCap: TimeInterval = 5
    static let completedActionTTL: TimeInterval = 300
    static let completedActionCap = 4096
    static let clickGapMs: Int = 0
    static let directListenerPort: UInt16 = 8787
}

enum PermissionState: String, Codable, Sendable {
    case ready, required, unknown
}

enum ResultStatus: String, Codable, Sendable {
    case posted, rejected
}

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

enum RelayAckStatus: String, Codable, Sendable {
    case forwarded
    case macOffline = "mac_offline"
    case rejected
}

// MARK: - Payloads

struct Hello: Codable, Equatable, Sendable {
    var type = "hello"
    var v = Constants.protocolVersion
    var role: String
    var token: String
}

struct HelloOK: Codable, Equatable, Sendable {
    var type = "hello.ok"
    var v = Constants.protocolVersion
    var role: String
}

struct HeartbeatRequest: Codable, Equatable, Sendable {
    var type = "heartbeat.request"
    var v = Constants.protocolVersion
    var sequence: Int
}

struct HeartbeatAck: Codable, Equatable, Sendable {
    var type = "heartbeat.ack"
    var v = Constants.protocolVersion
    var sequence: Int
}

struct MacState: Codable, Equatable, Sendable {
    var type = "mac.state"
    var v = Constants.protocolVersion
    var remoteEnabled: Bool
    var permission: PermissionState
}

struct PhoneState: Codable, Equatable, Sendable {
    var type = "state"
    var v = Constants.protocolVersion
    var macOnline: Bool
    var remoteEnabled: Bool
    var permission: PermissionState
}

struct ActionRequest: Codable, Equatable, Sendable {
    var type = "action.request"
    var v = Constants.protocolVersion
    var actionId: String
    var action: String
    var issuedAtUnixMs: Double
    var expiresAtUnixMs: Double

    /// Deterministic and EXCLUDES actionId: two requests sharing an ID but
    /// differing here are an id_conflict, not a duplicate.
    var fingerprint: String {
        "\(action)|\(issuedAtUnixMs)|\(expiresAtUnixMs)"
    }
}

struct RelayAck: Codable, Equatable, Sendable {
    var type = "relay.ack"
    var v = Constants.protocolVersion
    var actionId: String
    var status: RelayAckStatus
    var relayProcessingUs: Double
}

struct ActionResult: Codable, Equatable, Sendable {
    var type = "action.result"
    var v = Constants.protocolVersion
    var actionId: String
    var status: ResultStatus
    var reason: ResultReason
    var acceptedVia: ActionIngress
    var macProcessingUs: Double
    var mouseDownPostedUnixMs: Double?
}

struct TimeSyncRequest: Codable, Equatable, Sendable {
    var type = "time.sync.request"
    var v = Constants.protocolVersion
    var syncId: String
    var phoneSendUnixMs: Double
}

struct TimeSyncResponse: Codable, Equatable, Sendable {
    var type = "time.sync.response"
    var v = Constants.protocolVersion
    var syncId: String
    var phoneSendUnixMs: Double
    var macReceiveUnixMs: Double
    var macSendUnixMs: Double
}

// MARK: - Envelope

enum WireMessage: Equatable, Sendable {
    case hello(Hello)
    case helloOK(HelloOK)
    case heartbeatRequest(HeartbeatRequest)
    case heartbeatAck(HeartbeatAck)
    case macState(MacState)
    case state(PhoneState)
    case actionRequest(ActionRequest)
    case relayAck(RelayAck)
    case actionResult(ActionResult)
    case timeSyncRequest(TimeSyncRequest)
    case timeSyncResponse(TimeSyncResponse)
}

enum WireError: Error, Equatable {
    case tooLarge
    case notJSON
    case missingType
    case unknownType(String)
    case unsupportedVersion
    case decodeFailed(String)
}

enum Wire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder = JSONDecoder()

    private struct Envelope: Decodable {
        let type: String
        let v: Int
    }

    static func decode(_ text: String) throws -> WireMessage {
        guard text.utf8.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        guard let data = text.data(using: .utf8) else { throw WireError.notJSON }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw WireError.missingType
        }
        guard envelope.v == Constants.protocolVersion else { throw WireError.unsupportedVersion }

        func make<T: Decodable>(_ t: T.Type, _ wrap: (T) -> WireMessage) throws -> WireMessage {
            do { return wrap(try decoder.decode(T.self, from: data)) }
            catch { throw WireError.decodeFailed(envelope.type) }
        }

        switch envelope.type {
        case "hello":               return try make(Hello.self, WireMessage.hello)
        case "hello.ok":            return try make(HelloOK.self, WireMessage.helloOK)
        case "heartbeat.request":   return try make(HeartbeatRequest.self, WireMessage.heartbeatRequest)
        case "heartbeat.ack":       return try make(HeartbeatAck.self, WireMessage.heartbeatAck)
        case "mac.state":           return try make(MacState.self, WireMessage.macState)
        case "state":               return try make(PhoneState.self, WireMessage.state)
        case "action.request":      return try make(ActionRequest.self, WireMessage.actionRequest)
        case "relay.ack":           return try make(RelayAck.self, WireMessage.relayAck)
        case "action.result":       return try make(ActionResult.self, WireMessage.actionResult)
        case "time.sync.request":   return try make(TimeSyncRequest.self, WireMessage.timeSyncRequest)
        case "time.sync.response":  return try make(TimeSyncResponse.self, WireMessage.timeSyncResponse)
        default:                    throw WireError.unknownType(envelope.type)
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard data.count <= Constants.maxMessageBytes else { throw WireError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}
