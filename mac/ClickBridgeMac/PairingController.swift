import Foundation

protocol PairingTransport: Sendable {
    func sendPairing(_ message: WireMessage) async throws
}

enum PairingLinkError: Error, Equatable {
    case invalidRelayURL
    case invalidReference
}

enum PairingLink {
    static func make(relayURL: URL, reference: String) throws -> URL {
        guard relayURL.scheme == "wss",
              relayURL.path == "/ws",
              relayURL.user == nil,
              relayURL.password == nil,
              relayURL.query == nil,
              relayURL.fragment == nil,
              relayURL.host != nil else {
            throw PairingLinkError.invalidRelayURL
        }
        guard isCanonicalReference(reference) else { throw PairingLinkError.invalidReference }

        var components = URLComponents()
        components.scheme = "https"
        components.host = relayURL.host
        components.port = relayURL.port
        components.path = "/pair"
        components.fragment = "v=1&r=\(reference)"
        guard let link = components.url, link.absoluteString.utf8.count <= 512 else {
            throw PairingLinkError.invalidRelayURL
        }
        return link
    }

    static func validateInvitation(_ invitation: URL) throws -> URL {
        guard invitation.scheme == "https",
              invitation.path == "/pair",
              invitation.user == nil,
              invitation.password == nil,
              invitation.query == nil,
              invitation.host != nil,
              let fragment = invitation.fragment,
              fragment.hasPrefix("v=1&r=") else {
            throw PairingLinkError.invalidRelayURL
        }
        let reference = String(fragment.dropFirst("v=1&r=".count))
        guard !reference.contains("&") else { throw PairingLinkError.invalidReference }

        var relay = URLComponents()
        relay.scheme = "wss"
        relay.host = invitation.host
        relay.port = invitation.port
        relay.path = "/ws"
        guard let relayURL = relay.url else { throw PairingLinkError.invalidRelayURL }
        let canonical = try make(relayURL: relayURL, reference: reference)
        guard canonical.absoluteString == invitation.absoluteString else {
            throw PairingLinkError.invalidRelayURL
        }
        return canonical
    }

    private static func isCanonicalReference(_ value: String) -> Bool {
        guard value.count == 43,
              value.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || (48...57).contains(scalar.value)
                      || scalar == "-" || scalar == "_"
              }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }
}

@MainActor
final class PairingController: ObservableObject {
    struct Invitation: Equatable {
        let url: URL
        let expiresAt: Date

        var qrPayload: String { url.absoluteString }
        var sharePayload: String { url.absoluteString }
        var accessibilityLabel: String { "Pairing QR code. Expires in five minutes." }
    }

    struct Approval: Equatable {
        let confirmationCode: String
        let clientKind: PairingClientKind
        let expiresAt: Date

        var accessibilityCode: String { "Confirmation code \(confirmationCode)" }
    }

    enum State: Equatable {
        case unavailable
        case checkingStatus
        case ready
        case replacementConfirmation
        case creating
        case invitation(Invitation)
        case approval(Approval)
        case approving
        case completed(activePhoneCredentialVersion: Int)
        case denied
        case expired
        case failed
    }

    @Published private(set) var state: State = .unavailable

    private let transport: any PairingTransport
    private let relayURL: URL
    private let requestID: () -> String
    private let now: () -> Date
    private var currentRequestID: String?
    private var currentClaimID: String?
    private var enrollment: PairStatus?
    private var capabilityAvailable = false
    private var operationEpoch: UInt64 = 0
    private var retryAction: RetryAction = .none

    private enum RetryAction {
        case none
        case status
        case create
    }

    private struct SendOwnership {
        let operation: UInt64
        let requestID: String?
        let claimID: String?
        let state: State
    }

    init(
        transport: any PairingTransport,
        relayURL: URL,
        requestID: @escaping () -> String = { UUID().uuidString.lowercased() },
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.relayURL = relayURL
        self.requestID = requestID
        self.now = now
    }

    func refreshStatus(capabilityAvailable: Bool) async {
        guard capabilityAvailable else {
            self.capabilityAvailable = false
            enrollment = nil
            retryAction = .none
            reset(to: .unavailable)
            return
        }
        self.capabilityAvailable = true
        enrollment = nil
        retryAction = .none
        let identifier = requestID()
        currentRequestID = identifier
        currentClaimID = nil
        let ownership = beginSend(in: .checkingStatus)
        do {
            try await transport.sendPairing(.pairStatusRequest(PairStatusRequest(requestId: identifier)))
            guard owns(ownership) else { return }
        } catch {
            guard owns(ownership) else { return }
            retryAction = .status
            reset(to: .failed)
        }
    }

    func beginPairing() async {
        guard capabilityAvailable,
              enrollment?.requiresReplacementConfirmation == true,
              state == .ready else { return }
        transition(to: .replacementConfirmation)
    }

    func confirmReplacement() async {
        guard state == .replacementConfirmation else { return }
        await createInvitation()
    }

    func regenerate() async {
        guard capabilityAvailable else { return }
        switch (state, retryAction) {
        case (.failed, .status):
            await refreshStatus(capabilityAvailable: true)
        case (.failed, .create), (.expired, .create):
            await createInvitation()
        default:
            return
        }
    }

    private func createInvitation() async {
        guard capabilityAvailable, enrollment?.requiresReplacementConfirmation == true else { return }
        let identifier = requestID()
        currentRequestID = identifier
        currentClaimID = nil
        retryAction = .none
        let ownership = beginSend(in: .creating)
        do {
            try await transport.sendPairing(.pairCreate(PairCreate(requestId: identifier)))
            guard owns(ownership) else { return }
        } catch {
            guard owns(ownership) else { return }
            retryAction = .create
            reset(to: .failed)
        }
    }

    func approve() async {
        guard let requestID = currentRequestID, let claimID = currentClaimID else { return }
        guard case .approval = state else { return }
        retryAction = .none
        let ownership = beginSend(in: .approving)
        do {
            try await transport.sendPairing(.pairApprove(PairApprove(requestId: requestID, claimId: claimID)))
            guard owns(ownership) else { return }
        } catch {
            guard owns(ownership) else { return }
            reset(to: .failed)
        }
    }

    func deny() async { await rejectClaim(terminalState: .denied) }

    func codesDoNotMatch() async { await rejectClaim(terminalState: .denied) }

    func cancel() async {
        guard let requestID = currentRequestID else { return }
        let ownership = beginSend(in: state)
        _ = try? await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID)))
        guard owns(ownership) else { return }
        retryAction = .none
        reset(to: .ready)
    }

    func refreshExpiry() async {
        let expiresAt: Date?
        let canRegenerateInvitation: Bool
        switch state {
        case .invitation(let invitation):
            expiresAt = invitation.expiresAt
            canRegenerateInvitation = true
        case .approval(let approval):
            expiresAt = approval.expiresAt
            canRegenerateInvitation = false
        default:
            expiresAt = nil
            canRegenerateInvitation = false
        }
        guard let expiresAt, now() >= expiresAt else { return }
        if let requestID = currentRequestID {
            let ownership = beginSend(in: state)
            try? await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID)))
            guard owns(ownership) else { return }
        }
        retryAction = canRegenerateInvitation ? .create : .none
        reset(to: .expired)
    }

    func receive(_ message: WireMessage) async {
        switch message {
        case .pairStatus(let status)
            where state == .checkingStatus && status.requestId == currentRequestID:
            enrollment = status
            retryAction = .none
            transition(to: .ready)
        case .pairCreated(let created)
            where state == .creating && created.requestId == currentRequestID:
            guard let link = try? PairingLink.make(relayURL: relayURL, reference: created.reference) else {
                retryAction = .create
                reset(to: .failed)
                return
            }
            retryAction = .create
            transition(to: .invitation(Invitation(
                url: link,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(created.expiresAtUnixMs) / 1_000)
            )))
        case .pairClaimedMac(let claimed)
            where isWaitingForClaim && claimed.requestId == currentRequestID:
            currentClaimID = claimed.claimId
            transition(to: .approval(Approval(
                confirmationCode: claimed.confirmationCode,
                clientKind: claimed.clientKind,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(claimed.expiresAtUnixMs) / 1_000)
            )))
        case .pairCompleted(let completed)
            where state == .approving
                && completed.requestId == currentRequestID && completed.claimId == currentClaimID:
            currentClaimID = nil
            retryAction = .none
            transition(to: .completed(activePhoneCredentialVersion: completed.activePhoneCredentialVersion))
        case .pairFailed(let failed)
            where failed.requestId == currentRequestID
                && (failed.claimId == nil || failed.claimId == currentClaimID):
            switch state {
            case .checkingStatus: retryAction = .status
            case .creating, .invitation: retryAction = .create
            default: retryAction = .none
            }
            reset(to: failed.reason == .expired ? .expired : .failed)
        default:
            break
        }
    }

    private func rejectClaim(terminalState: State) async {
        guard let requestID = currentRequestID, let claimID = currentClaimID else { return }
        guard case .approval = state else { return }
        let ownership = beginSend(in: state)
        do {
            try await transport.sendPairing(.pairDeny(PairDeny(requestId: requestID, claimId: claimID)))
        } catch {
            guard owns(ownership) else { return }
            retryAction = .none
            reset(to: .failed)
            return
        }
        guard owns(ownership) else { return }
        currentClaimID = nil
        retryAction = .none
        transition(to: terminalState)
    }

    private var isWaitingForClaim: Bool {
        if case .invitation = state { return true }
        return false
    }

    private func reset(to state: State) {
        operationEpoch &+= 1
        currentRequestID = nil
        currentClaimID = nil
        if state == .unavailable { enrollment = nil }
        self.state = state
    }

    private func transition(to state: State) {
        operationEpoch &+= 1
        self.state = state
    }

    private func beginSend(in state: State) -> SendOwnership {
        operationEpoch &+= 1
        self.state = state
        return SendOwnership(
            operation: operationEpoch,
            requestID: currentRequestID,
            claimID: currentClaimID,
            state: state
        )
    }

    private func owns(_ ownership: SendOwnership) -> Bool {
        operationEpoch == ownership.operation
            && currentRequestID == ownership.requestID
            && currentClaimID == ownership.claimID
            && state == ownership.state
    }
}
