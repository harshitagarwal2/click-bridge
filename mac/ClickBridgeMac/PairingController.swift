import AppKit
import Foundation

protocol PairingTransport: Sendable {
    func sendPairing(_ message: WireMessage) async throws
}

enum PairingLinkError: Error, Equatable {
    case invalidRelayURL
    case invalidReference
}

enum PairingInvitationDestination {
    case nativeApp
    case browser
}

typealias PairingInvitationURLResolver = @MainActor () -> URL?

enum PairingLink {
    static func make(relayURL: URL, reference: String) throws -> URL {
        guard relayURL.scheme == "wss",
              relayURL.path == "/ws" || relayURL.path.range(of: "^/ws/[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil,
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
        components.path = relayURL.path == "/ws" ? "/pair" : "/pair/" + String(relayURL.path.dropFirst("/ws/".count))
        components.fragment = "v=1&r=\(reference)"
        guard let link = components.url, link.absoluteString.utf8.count <= 512 else {
            throw PairingLinkError.invalidRelayURL
        }
        return link
    }

    static func validateInvitation(_ invitation: URL) throws -> URL {
        guard invitation.scheme == "https",
              invitation.path == "/pair" || invitation.path.range(of: "^/pair/[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil,
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
        relay.path = invitation.path == "/pair" ? "/ws" : "/ws/" + String(invitation.path.dropFirst("/pair/".count))
        guard let relayURL = relay.url else { throw PairingLinkError.invalidRelayURL }
        let canonical = try make(relayURL: relayURL, reference: reference)
        guard canonical.absoluteString == invitation.absoluteString else {
            throw PairingLinkError.invalidRelayURL
        }
        return canonical
    }

    static func makeWebInvitation(from invitation: URL) throws -> URL {
        let canonical = try validateInvitation(invitation)
        var components = URLComponents()
        components.scheme = canonical.scheme
        components.host = canonical.host
        components.port = canonical.port
        components.path = canonical.path == "/pair" ? "/pair/web" : "/pair/web/" + String(canonical.path.dropFirst("/pair/".count))
        components.fragment = canonical.fragment
        guard let webInvitation = components.url,
              webInvitation.absoluteString.utf8.count <= 512 else {
            throw PairingLinkError.invalidRelayURL
        }
        return webInvitation
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
        case denying
        case cancelling
        case cancelFailed
        case completed(activePhoneCredentialVersion: Int)
        case denied
        case expired
        case failed
    }

    enum RecoveryAction: Equatable {
        case retry
        case startAgain
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
        case startAgain
    }

    var recoveryAction: RecoveryAction? {
        switch retryAction {
        case .status, .create: return .retry
        case .startAgain: return .startAgain
        case .none: return nil
        }
    }

    var blocksConnectionChanges: Bool {
        Self.blocksConnectionChanges(in: state)
    }

    var preventsInteractiveDismissal: Bool {
        blocksConnectionChanges
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
        let cancellationUncertain = state == .cancelling || state == .cancelFailed
        guard capabilityAvailable else {
            self.capabilityAvailable = false
            if cancellationUncertain {
                markCancellationUncertain()
            } else {
                enrollment = nil
                retryAction = .none
                reset(to: .unavailable)
            }
            return
        }
        self.capabilityAvailable = true
        enrollment = nil
        retryAction = cancellationUncertain ? .status : .none
        let identifier = requestID()
        currentRequestID = identifier
        currentClaimID = nil
        let ownership = beginSend(in: cancellationUncertain ? .cancelFailed : .checkingStatus)
        do {
            try await transport.sendPairing(.pairStatusRequest(PairStatusRequest(requestId: identifier)))
            guard owns(ownership) else { return }
        } catch {
            guard owns(ownership) else { return }
            retryAction = .status
            reset(to: cancellationUncertain ? .cancelFailed : .failed)
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
        case (.failed, .status), (.cancelling, .status), (.cancelFailed, .status):
            await refreshStatus(capabilityAvailable: true)
        case (.failed, .create), (.expired, .create):
            await createInvitation()
        case (.failed, .startAgain), (.denied, .startAgain), (.expired, .startAgain):
            await refreshStatus(capabilityAvailable: true)
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
            retryAction = .startAgain
            reset(to: .failed)
        }
    }

    func deny() async { await rejectClaim(terminalState: .denied) }

    func codesDoNotMatch() async { await rejectClaim(terminalState: .denied) }

    func cancel() async {
        guard let requestID = currentRequestID else { return }
        switch state {
        case .creating, .invitation, .approval:
            break
        default:
            return
        }
        let ownership = beginSend(in: .cancelling)
        do {
            try await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID)))
            guard owns(ownership) else { return }
            retryAction = .status
        } catch {
            guard owns(ownership) else { return }
            markCancellationUncertain()
        }
    }

    func invitationURL(
        for expected: Invitation,
        destination: PairingInvitationDestination
    ) -> URL? {
        guard case .invitation(let current) = state,
              current == expected,
              now() < current.expiresAt,
              let canonical = try? PairingLink.validateInvitation(current.url) else {
            return nil
        }
        switch destination {
        case .nativeApp:
            return canonical
        case .browser:
            return try? PairingLink.makeWebInvitation(from: canonical)
        }
    }

    func invitationURLResolver(
        for expected: Invitation,
        destination: PairingInvitationDestination
    ) -> PairingInvitationURLResolver {
        { [weak self] in
            self?.invitationURL(for: expected, destination: destination)
        }
    }

    @discardableResult
    func copyInvitation(
        _ expected: Invitation,
        destination: PairingInvitationDestination,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let invitation = invitationURL(for: expected, destination: destination) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(invitation.absoluteString, forType: .string)
    }

    @discardableResult
    func copyWebInvitation(
        _ expected: Invitation,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        copyInvitation(expected, destination: .browser, to: pasteboard)
    }

    func refreshExpiry() async {
        let expiresAt: Date?
        switch state {
        case .invitation(let invitation):
            expiresAt = invitation.expiresAt
        case .approval(let approval):
            expiresAt = approval.expiresAt
        default:
            expiresAt = nil
        }
        guard let expiresAt, now() >= expiresAt else { return }
        guard let requestID = currentRequestID else {
            markCancellationUncertain()
            return
        }
        let ownership = beginSend(in: .cancelling)
        do {
            try await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID)))
            guard owns(ownership) else { return }
            retryAction = .status
        } catch {
            guard owns(ownership) else { return }
            markCancellationUncertain()
        }
    }

    func receive(_ message: WireMessage) async {
        switch message {
        case .pairStatus(let status)
            where canAcceptStatus && status.requestId == currentRequestID:
            enrollment = status
            retryAction = .none
            reset(to: .ready)
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
            where canAcceptClaim && claimed.requestId == currentRequestID:
            currentClaimID = claimed.claimId
            transition(to: .approval(Approval(
                confirmationCode: claimed.confirmationCode,
                clientKind: claimed.clientKind,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(claimed.expiresAtUnixMs) / 1_000)
            )))
        case .pairCompleted(let completed)
            where state == .approving
                && completed.requestId == currentRequestID && completed.claimId == currentClaimID:
            retryAction = .none
            reset(to: .completed(activePhoneCredentialVersion: completed.activePhoneCredentialVersion))
        case .pairFailed(let failed) where state == .cancelling:
            guard failed.requestId == currentRequestID else {
                markCancellationUncertain()
                return
            }
            receivePairingFailure(failed)
        case .pairFailed(let failed) where failed.requestId == currentRequestID:
            receivePairingFailure(failed)
        default:
            break
        }
    }

    private func rejectClaim(terminalState: State) async {
        guard let requestID = currentRequestID, let claimID = currentClaimID else { return }
        guard case .approval = state else { return }
        let ownership = beginSend(in: .denying)
        do {
            try await transport.sendPairing(.pairDeny(PairDeny(requestId: requestID, claimId: claimID)))
        } catch {
            guard owns(ownership) else { return }
            retryAction = .startAgain
            reset(to: .failed)
            return
        }
        guard owns(ownership) else { return }
        retryAction = .startAgain
        reset(to: terminalState)
    }

    private var canAcceptClaim: Bool {
        if case .invitation = state { return true }
        return false
    }

    private func receivePairingFailure(_ failed: PairFailed) {
        switch state {
        case .checkingStatus where failed.claimId == nil:
            retryAction = .status
            reset(to: .failed)
        case .creating where failed.claimId == nil,
             .invitation where failed.claimId == nil:
            retryAction = failed.reason == .expired ? .create : .none
            switch failed.reason {
            case .expired:
                reset(to: .expired)
            case .cancelled:
                retryAction = .none
                reset(to: .ready)
            default:
                retryAction = .startAgain
                reset(to: .failed)
            }
        case .approval where failed.claimId == currentClaimID,
             .approving where failed.claimId == currentClaimID:
            retryAction = .startAgain
            switch failed.reason {
            case .denied:
                reset(to: .denied)
            case .cancelled:
                retryAction = .none
                reset(to: .ready)
            case .expired:
                reset(to: .expired)
            default:
                reset(to: .failed)
            }
        case .denying where failed.claimId == currentClaimID:
            retryAction = .startAgain
            switch failed.reason {
            case .denied:
                reset(to: .denied)
            case .cancelled:
                retryAction = .none
                reset(to: .ready)
            case .expired:
                reset(to: .expired)
            default:
                reset(to: .failed)
            }
        case .cancelling:
            if failed.claimId == currentClaimID, failed.reason == .cancelled {
                retryAction = .none
                reset(to: .ready)
            } else {
                markCancellationUncertain()
            }
        default:
            break
        }
    }

    private var canAcceptStatus: Bool {
        state == .checkingStatus || state == .cancelFailed
    }

    private func markCancellationUncertain() {
        enrollment = nil
        retryAction = .status
        reset(to: .cancelFailed)
    }

    static func blocksConnectionChanges(in state: State) -> Bool {
        switch state {
        case .creating, .invitation, .approval, .approving, .denying, .cancelling, .cancelFailed:
            return true
        default:
            return false
        }
    }

#if DEBUG
    func forceBlockedConnectionStateForTesting(_ state: State) {
        precondition(Self.blocksConnectionChanges(in: state))
        transition(to: state)
    }

    func clearBlockedConnectionStateForTesting() {
        precondition(blocksConnectionChanges)
        reset(to: .ready)
    }
#endif

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
