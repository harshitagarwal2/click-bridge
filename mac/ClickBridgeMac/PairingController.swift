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
            reset(to: .unavailable)
            return
        }
        let identifier = requestID()
        currentRequestID = identifier
        state = .checkingStatus
        do {
            try await transport.sendPairing(.pairStatusRequest(PairStatusRequest(requestId: identifier)))
        } catch {
            reset(to: .failed)
        }
    }

    func beginPairing() async {
        guard enrollment != nil else { return }
        state = .replacementConfirmation
    }

    func confirmReplacement() async {
        let identifier = requestID()
        currentRequestID = identifier
        currentClaimID = nil
        state = .creating
        do {
            try await transport.sendPairing(.pairCreate(PairCreate(requestId: identifier)))
        } catch {
            reset(to: .failed)
        }
    }

    func regenerate() async {
        guard state == .expired || state == .failed else { return }
        await confirmReplacement()
    }

    func approve() async {
        guard let requestID = currentRequestID, let claimID = currentClaimID else { return }
        state = .approving
        do {
            try await transport.sendPairing(.pairApprove(PairApprove(requestId: requestID, claimId: claimID)))
        } catch {
            state = .failed
        }
    }

    func deny() async { await rejectClaim(terminalState: .denied) }

    func codesDoNotMatch() async { await rejectClaim(terminalState: .denied) }

    func cancel() async {
        guard let requestID = currentRequestID else { return }
        do { try await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID))) }
        catch { }
        reset(to: .ready)
    }

    func refreshExpiry() async {
        let expiresAt: Date?
        switch state {
        case .invitation(let invitation): expiresAt = invitation.expiresAt
        case .approval(let approval): expiresAt = approval.expiresAt
        default: expiresAt = nil
        }
        guard let expiresAt, now() >= expiresAt else { return }
        if let requestID = currentRequestID {
            try? await transport.sendPairing(.pairCancel(PairCancel(requestId: requestID)))
        }
        reset(to: .expired)
    }

    func receive(_ message: WireMessage) async {
        switch message {
        case .pairStatus(let status)
            where state == .checkingStatus && status.requestId == currentRequestID:
            enrollment = status
            state = .ready
        case .pairCreated(let created)
            where state == .creating && created.requestId == currentRequestID:
            guard let link = try? PairingLink.make(relayURL: relayURL, reference: created.reference) else {
                reset(to: .failed)
                return
            }
            state = .invitation(Invitation(
                url: link,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(created.expiresAtUnixMs) / 1_000)
            ))
        case .pairClaimedMac(let claimed)
            where isWaitingForClaim && claimed.requestId == currentRequestID:
            currentClaimID = claimed.claimId
            state = .approval(Approval(
                confirmationCode: claimed.confirmationCode,
                clientKind: claimed.clientKind,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(claimed.expiresAtUnixMs) / 1_000)
            ))
        case .pairCompleted(let completed)
            where state == .approving
                && completed.requestId == currentRequestID && completed.claimId == currentClaimID:
            state = .completed(activePhoneCredentialVersion: completed.activePhoneCredentialVersion)
            currentClaimID = nil
        case .pairFailed(let failed)
            where failed.requestId == currentRequestID
                && (failed.claimId == nil || failed.claimId == currentClaimID):
            reset(to: failed.reason == .expired ? .expired : .failed)
        default:
            break
        }
    }

    private func rejectClaim(terminalState: State) async {
        guard let requestID = currentRequestID, let claimID = currentClaimID else { return }
        do {
            try await transport.sendPairing(.pairDeny(PairDeny(requestId: requestID, claimId: claimID)))
        } catch {
            state = .failed
            return
        }
        currentClaimID = nil
        state = terminalState
    }

    private var isWaitingForClaim: Bool {
        if case .invitation = state { return true }
        return false
    }

    private func reset(to state: State) {
        currentRequestID = nil
        currentClaimID = nil
        if state == .unavailable { enrollment = nil }
        self.state = state
    }
}
