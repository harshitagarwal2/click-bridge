import Foundation

struct MacReadiness: Equatable, Sendable {
    var online = false
    var remoteEnabled = false
    var permission: PermissionState = .unknown
}

struct ClockHealth: Equatable, Sendable {
    enum Status: Equatable, Sendable { case unchecked, checking, healthy, mismatch, unavailable }
    let status: Status
    let offsetMilliseconds: Double?
    let uncertaintyMilliseconds: Double?
}

struct ActionGateSnapshot: Equatable, Sendable {
    let foregroundGeneration: Int?
    let socketGeneration: Int
    let transportAuthenticated: Bool
    let mac: MacReadiness
    let clock: ClockHealth
}

enum ActionDisposition: Equatable, Sendable {
    case sent(actionID: UUID)
    case ignoredNotReady
    case ignoredPending
    case sendFailed
}

enum PhoneActionRejectionReason: String, Equatable, Sendable {
    case macOffline = "mac_offline"
    case permissionRequired = "permission_required"
    case remoteDisabled = "remote_disabled"
    case idConflict = "id_conflict"
    case expired
    case capacityExceeded = "capacity_exceeded"
    case eventCreationFailed = "event_creation_failed"
    case invalidRequest = "invalid_request"

    init(_ reason: ResultReason) {
        switch reason {
        case .ok: self = .invalidRequest
        case .permissionRequired: self = .permissionRequired
        case .remoteDisabled: self = .remoteDisabled
        case .idConflict: self = .idConflict
        case .expired: self = .expired
        case .capacityExceeded: self = .capacityExceeded
        case .eventCreationFailed: self = .eventCreationFailed
        case .invalidRequest: self = .invalidRequest
        }
    }

    var userFacingDescription: String {
        switch self {
        case .macOffline:
            "The Mac went offline."
        case .permissionRequired:
            "Mac Accessibility permission is required."
        case .remoteDisabled:
            "Remote control is disabled on the Mac."
        case .idConflict:
            "The click request conflicted with an earlier request."
        case .expired:
            "The click request expired before it could be posted."
        case .capacityExceeded:
            "The relay is busy. Try again."
        case .eventCreationFailed:
            "The Mac could not create the click event."
        case .invalidRequest:
            "The relay rejected the click request."
        }
    }
}

enum PhoneActionPhase: Equatable, Sendable {
    case idle
    case sending(actionID: UUID)
    case forwarded(actionID: UUID)
    case posted(actionID: UUID, elapsedMilliseconds: Double)
    case rejected(actionID: UUID, reason: PhoneActionRejectionReason, elapsedMilliseconds: Double)
    case unknown(actionID: UUID)
}

@MainActor
final class PhoneActionCoordinator {
    private struct PendingAction {
        let request: ActionRequest
        let foregroundGeneration: Int
        let socketGeneration: Int
        let startedMonotonicMilliseconds: Double
        let timeout: ScheduledToken
    }

    private let transport: any PhoneActionTransport
    private let clock: any PhoneClock
    private let scheduler: any PhoneScheduler
    private let haptics: any PhoneHaptics
    private let makeActionID: @MainActor () -> UUID
    private let onPhase: @MainActor (PhoneActionPhase) -> Void
    private var pending: PendingAction?

    init(
        transport: any PhoneActionTransport,
        clock: any PhoneClock,
        scheduler: any PhoneScheduler,
        haptics: any PhoneHaptics,
        makeActionID: @escaping @MainActor () -> UUID = UUID.init,
        onPhase: @escaping @MainActor (PhoneActionPhase) -> Void
    ) {
        self.transport = transport
        self.clock = clock
        self.scheduler = scheduler
        self.haptics = haptics
        self.makeActionID = makeActionID
        self.onPhase = onPhase
    }

    var hasPendingAction: Bool { pending != nil }

    func canAccept(readiness: ActionGateSnapshot) -> Bool {
        pending == nil && isReady(readiness)
    }

    func accept(readiness: ActionGateSnapshot) -> ActionDisposition {
        guard pending == nil else { return .ignoredPending }
        guard isReady(readiness) else { return .ignoredNotReady }
        return sendAction(readiness: readiness)
    }

    func accept(_ delta: ObservedVolumeDelta, readiness: ActionGateSnapshot) -> ActionDisposition {
        guard pending == nil else { return .ignoredPending }
        guard let foregroundGeneration = readiness.foregroundGeneration,
              foregroundGeneration == delta.foregroundGeneration,
              isReady(readiness) else { return .ignoredNotReady }
        return sendAction(readiness: readiness)
    }

    private func isReady(_ readiness: ActionGateSnapshot) -> Bool {
        readiness.foregroundGeneration != nil &&
            readiness.socketGeneration == transport.generation &&
            readiness.transportAuthenticated &&
            transport.isAuthenticated &&
            readiness.mac.online &&
            readiness.mac.remoteEnabled &&
            readiness.mac.permission == .ready &&
            readiness.clock.status == .healthy
    }

    private func sendAction(readiness: ActionGateSnapshot) -> ActionDisposition {
        guard let foregroundGeneration = readiness.foregroundGeneration else { return .ignoredNotReady }

        let actionID = makeActionID()
        let issuedAt = clock.nowUnixMilliseconds()
        let request = ActionRequest(
            actionID: actionID,
            action: "click",
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: issuedAt + PhoneProtocolV1.actionLifetimeMilliseconds
        )
        let message = PhoneClientMessage.actionRequest(request)
        guard transport.send(message) else {
            onPhase(.idle)
            return .sendFailed
        }

        let started = clock.nowMonotonicMilliseconds()
        let expectedSocketGeneration = readiness.socketGeneration
        let timeout = scheduler.schedule(after: PhoneProtocolV1.resultTimeout) { [weak self] in
            guard let self, let pending = self.pending,
                  pending.request.actionID == actionID,
                  pending.socketGeneration == expectedSocketGeneration else { return }
            self.pending = nil
            self.onPhase(.unknown(actionID: actionID))
        }
        pending = PendingAction(
            request: request,
            foregroundGeneration: foregroundGeneration,
            socketGeneration: expectedSocketGeneration,
            startedMonotonicMilliseconds: started,
            timeout: timeout
        )
        onPhase(.sending(actionID: actionID))
        return .sent(actionID: actionID)
    }

    func handle(_ message: PhoneServerMessage, socketGeneration: Int) -> Bool {
        guard let pending, pending.socketGeneration == socketGeneration else { return false }

        switch message {
        case .relayAck(let ack):
            guard ack.actionID == pending.request.actionID else { return false }
            if ack.status == .forwarded {
                onPhase(.forwarded(actionID: ack.actionID))
            } else {
                settleWithoutHaptic(
                    pending,
                    reason: resultReason(for: ack.reason),
                    actionID: ack.actionID
                )
            }
            return true
        case .actionResult(let result):
            guard result.actionID == pending.request.actionID else { return false }
            scheduler.cancel(pending.timeout)
            let elapsed = max(0, clock.nowMonotonicMilliseconds() - pending.startedMonotonicMilliseconds)
            haptics.terminalResult(result)
            self.pending = nil
            switch result.status {
            case .posted:
                onPhase(.posted(actionID: result.actionID, elapsedMilliseconds: elapsed))
            case .rejected:
                onPhase(.rejected(actionID: result.actionID,
                                  reason: PhoneActionRejectionReason(result.reason),
                                  elapsedMilliseconds: elapsed))
            }
            return true
        default:
            return false
        }
    }

    func abandonPending(reason: String) {
        guard let pending else { return }
        scheduler.cancel(pending.timeout)
        self.pending = nil
        onPhase(.unknown(actionID: pending.request.actionID))
    }

    private func settleWithoutHaptic(_ pending: PendingAction,
                                     reason: PhoneActionRejectionReason,
                                     actionID: UUID) {
        scheduler.cancel(pending.timeout)
        let elapsed = max(0, clock.nowMonotonicMilliseconds() - pending.startedMonotonicMilliseconds)
        self.pending = nil
        onPhase(.rejected(actionID: actionID, reason: reason, elapsedMilliseconds: elapsed))
    }

    private func resultReason(for reason: RelayAckReason) -> PhoneActionRejectionReason {
        switch reason {
        case .ok: .invalidRequest
        case .macOffline: .macOffline
        case .expired: .expired
        case .invalidRequest: .invalidRequest
        }
    }
}
