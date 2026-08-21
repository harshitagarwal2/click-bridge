import Foundation

enum PhoneAppIssue: LocalizedError, Equatable, Sendable {
    case invalidSettings
    case secureStorageUnavailable
    case volumeMonitoringUnavailable

    var message: String {
        switch self {
        case .invalidSettings:
            "Relay settings are invalid. Open Settings to reconnect."
        case .secureStorageUnavailable:
            "Secure storage is unavailable. Try again or restart the app."
        case .volumeMonitoringUnavailable:
            "System volume monitoring is unavailable. Try reopening the app."
        }
    }

    var errorDescription: String? { message }

    var settingsMessage: String? {
        switch self {
        case .invalidSettings, .secureStorageUnavailable:
            message
        case .volumeMonitoringUnavailable:
            nil
        }
    }
}

enum PhonePrimaryStatus: Equatable, Sendable {
    case notConnected, anotherPhoneTookOver, credentialReplaced, macOffline, macNotReady, checkingClock, clockUnavailable, clockMismatch, sending
    case atVolumeBoundary(VolumeBoundary)
    case ready

    var title: String {
        switch self {
        case .notConnected: "Not connected"
        case .anotherPhoneTookOver: "Another phone took over"
        case .credentialReplaced: "This phone was un-paired"
        case .macOffline: "Mac offline"
        case .macNotReady: "Mac not ready"
        case .checkingClock: "Checking clock"
        case .clockUnavailable: "Clock check unavailable"
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
        case .credentialReplaced: "A newer phone was paired. Pair this phone again to use it."
        case .macOffline: "Start Click Bridge on the Mac."
        case .macNotReady: "Enable remote control and macOS Accessibility permission."
        case .checkingClock: "Validating phone and Mac clocks."
        case .clockUnavailable: "Unable to validate the phone and Mac clocks. Retry the clock check."
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
    var desktops: [DesktopInfo] = []
    var desktopCount: Int = 0
    var macCount: Int = 0
    var windowsCount: Int = 0
    var clock = ClockHealth(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
    var volume = VolumeReading(value: 0)
    var actionPhase: PhoneActionPhase = .idle
    var lastActionOutcome: String?
    var issue: PhoneAppIssue?

    var desktopLabel: String? {
        let total = desktopCount
        if total == 0 { return nil }
        var parts: [String] = []
        if macCount > 0 { parts.append("\(macCount) Mac\(macCount>1 ? "s" : "")") }
        if windowsCount > 0 { parts.append("\(windowsCount) Windows") }
        let inv = parts.isEmpty ? "\(total) desktops" : parts.joined(separator: " + ")
        let notReady = desktops.filter { $0.permission != .ready || !$0.remoteEnabled }.count
        if notReady > 0 { return "\(inv) — \(notReady) needs attention" }
        return inv
    }

    var phoneTakenOver: Bool { connection == .takenOver }
    var credentialReplaced: Bool { connection == .credentialReplaced }
    var blocksAutomaticReconnect: Bool { phoneTakenOver || credentialReplaced }
    var primaryStatus: PhonePrimaryStatus {
        if credentialReplaced { return .credentialReplaced }
        if phoneTakenOver { return .anotherPhoneTookOver }
        guard foregroundSessionActive, connection == .authenticated else { return .notConnected }
        guard mac.online else { return .macOffline }
        guard mac.remoteEnabled, mac.permission == .ready else { return .macNotReady }
        switch clock.status {
        case .unchecked, .checking: return .checkingClock
        case .unavailable: return .clockUnavailable
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

    var showsClockRetry: Bool { clock.status == .unavailable }

    var primaryStatusDetail: String? {
        guard foregroundSessionActive else { return primaryStatus.detail }
        switch connection {
        case .connecting:
            return "Connecting to the relay."
        case .authenticating:
            return "Authenticating with the relay."
        case .backoff:
            return "Connection lost. Retrying automatically."
        case .authenticationRejected:
            return "Credential rejected. Pair this phone again."
        case .disconnected, .authenticated, .takenOver, .credentialReplaced:
            return primaryStatus.detail
        }
    }
}
