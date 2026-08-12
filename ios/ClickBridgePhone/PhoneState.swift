import Foundation

enum PhonePrimaryStatus: Equatable, Sendable {
    case notConnected, anotherPhoneTookOver, macOffline, macNotReady, checkingClock, clockMismatch, sending
    case atVolumeBoundary(VolumeBoundary)
    case ready

    var title: String {
        switch self {
        case .notConnected: "Not connected"
        case .anotherPhoneTookOver: "Another phone took over"
        case .macOffline: "Mac offline"
        case .macNotReady: "Mac not ready"
        case .checkingClock: "Checking clock"
        case .clockMismatch: "Clock mismatch"
        case .sending: "Sending"
        case .atVolumeBoundary: "At volume boundary"
        case .ready: "Ready"
        }
    }

    var detail: String? {
        switch self {
        case .atVolumeBoundary(.minimum):
            "Volume Down cannot create another change, so it cannot be detected. Volume Up can still trigger."
        case .atVolumeBoundary(.maximum):
            "Volume Up cannot create another change, so it cannot be detected. Volume Down can still trigger."
        case .notConnected: "Open settings and connect to the relay."
        case .anotherPhoneTookOver: "Reconnect this phone when you are ready to take control again."
        case .macOffline: "Start Click Bridge on the Mac."
        case .macNotReady: "Enable remote control and macOS Accessibility permission."
        case .checkingClock: "Validating phone and Mac clocks."
        case .clockMismatch: "Enable automatic date and time."
        case .sending: "Waiting for the Mac terminal result."
        case .ready: nil
        }
    }
}

struct PhoneState: Equatable, Sendable {
    var foregroundSessionActive = false
    var connection: PhoneConnectionState = .disconnected
    var mac = MacReadiness()
    var clock = ClockHealth(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
    var volume = VolumeReading(value: 0)
    var actionPhase: PhoneActionPhase = .idle
    var lastActionOutcome: String?
    var settingsError: String?
    var phoneTakenOver = false

    var primaryStatus: PhonePrimaryStatus {
        if phoneTakenOver { return .anotherPhoneTookOver }
        guard foregroundSessionActive, connection == .authenticated else { return .notConnected }
        guard mac.online else { return .macOffline }
        guard mac.remoteEnabled, mac.permission == .ready else { return .macNotReady }
        switch clock.status {
        case .unchecked, .checking, .unavailable: return .checkingClock
        case .mismatch: return .clockMismatch
        case .healthy: break
        }
        switch actionPhase {
        case .sending, .forwarded: return .sending
        default: break
        }
        if let boundary = volume.boundary { return .atVolumeBoundary(boundary) }
        return .ready
    }
}
