import CryptoKit
import Foundation
import Security

enum PhonePairingPhase: Equatable, Sendable {
    case idle, connecting, claiming, awaitingApproval, awaitingCredential
    case awaitingActivation, active, cancelled, failed, replaced
}

enum PhonePairingRecoveryResult: Equatable, Sendable {
    case recovered, noPending, originMismatch, authenticationRejected
    case authenticationUnavailable, storageReadFailed, storageCorrupt, promotionFailed, superseded
}

private enum PhonePairingRandomnessError: Error { case unavailable }

struct PhonePairingState: Equatable, Sendable {
    var phase: PhonePairingPhase = .idle
    var confirmationCode: String?
    var expiresAtUnixMilliseconds: Int?
    var failure: String?
}

@MainActor
final class PhonePairingClient: PhonePairingCoordinating {
    private let socketFactory: any PhoneWebSocketFactory
    private let settings: PhoneSettingsStore
    private let normalTransport: any PhoneActionTransport
    private let clock: any PhoneClock
    private let scheduler: any PhoneScheduler
    private let claimID: @MainActor () -> UUID
    private let randomBytes: @MainActor () throws -> Data
    private let authenticatePending: @MainActor (RelayConfiguration) async -> PhonePendingAuthenticationResult
    private let decoder = StrictPhoneWireDecoder()

    private(set) var state = PhonePairingState()
    var onState: (@MainActor (PhonePairingState) -> Void)?

    private var generation: UInt64 = 0
    private var socket: (any PhoneWebSocket)?
    private var timeout: ScheduledToken?
    private var currentClaimID: UUID?
    private var pending: PhonePairingPendingCredential?
    private var replacementAuthorization: PhonePairingReplacementAuthorization?
    private var relayWebSocketURL: URL?
    private var receiveState: PhonePairingReceiveState = .claiming
    private var opened = false

    init(
        socketFactory: any PhoneWebSocketFactory,
        settings: PhoneSettingsStore,
        normalTransport: any PhoneActionTransport,
        clock: any PhoneClock,
        scheduler: any PhoneScheduler,
        claimID: @escaping @MainActor () -> UUID = UUID.init,
        randomBytes: @escaping @MainActor () throws -> Data = {
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard status == errSecSuccess else { throw PhonePairingRandomnessError.unavailable }
            return bytes
        },
        authenticatePending: @escaping @MainActor (RelayConfiguration) async -> PhonePendingAuthenticationResult = { _ in .rejected }
    ) {
        self.socketFactory = socketFactory
        self.settings = settings
        self.normalTransport = normalTransport
        self.clock = clock
        self.scheduler = scheduler
        self.claimID = claimID
        self.randomBytes = randomBytes
        self.authenticatePending = authenticatePending
    }

    func start(
        _ link: PhonePairingLink,
        replacementAuthorization: PhonePairingReplacementAuthorization? = nil
    ) {
        retire(reason: "replaced")
        clearSensitive()
        generation &+= 1
        let expectedGeneration = generation
        let claimID = claimID()
        let nonceBytes: Data
        do { nonceBytes = try randomBytes() }
        catch {
            publish(.failed, failure: "pairing_unavailable")
            return
        }
        guard nonceBytes.count == 32 else {
            publish(.failed, failure: "pairing_unavailable")
            return
        }
        let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()
        relayWebSocketURL = link.claimantWebSocketURL
        self.replacementAuthorization = replacementAuthorization
        currentClaimID = claimID
        receiveState = .claiming
        let socket = socketFactory.makeSocket()
        self.socket = socket
        opened = false
        bind(socket, generation: expectedGeneration, claimID: claimID, reference: link.reference, nonce: nonce)
        publish(.connecting)
        schedule(after: 10, generation: expectedGeneration, socket: socket, reason: "connection_timeout")
        socket.open(url: link.claimantWebSocketURL)
    }

    func cancel() {
        guard state.phase != .awaitingActivation,
              state.phase != .awaitingCredential else { return }
        let currentSocket = socket
        let currentClaim = currentClaimID
        if opened, let currentSocket, let currentClaim,
           let text = try? PhoneClientMessage.pairCancelClaim(.init(claimID: currentClaim)).encodedText() {
            try? currentSocket.send(text: text) { _ in }
        }
        generation &+= 1
        retire(reason: "cancelled")
        clearSensitive()
        publish(.cancelled)
    }

    func recoverPending(relayWebSocketURL: URL) async -> PhonePairingRecoveryResult {
        generation &+= 1
        let expectedGeneration = generation
        retire(reason: "recover")
        clearSensitive()
        let pending: PhonePairingPendingCredential
        do {
            guard let stored = try settings.pendingPairingRecoveryDescriptor() else { return .noPending }
            pending = stored
        } catch PhonePairingCredentialStorageError.corruptState {
            return .storageCorrupt
        } catch {
            return .storageReadFailed
        }
        guard PhonePairingLink.canonicalClaimantWebSocketURL(relayWebSocketURL) == pending.relayWebSocketURL else {
            return .originMismatch
        }
        let configuration: RelayConfiguration
        do {
            configuration = try RelayConfiguration.validated(
                urlString: pending.relayWebSocketURL.absoluteString,
                token: pending.credential.token
            )
        } catch {
            return .storageCorrupt
        }
        let authentication = await authenticatePending(configuration)
        guard generation == expectedGeneration else { return .superseded }
        switch authentication {
        case .authenticated: break
        case .rejected: return .authenticationRejected
        case .unavailable: return .authenticationUnavailable
        }
        do {
            try settings.promotePairingCredential(pending)
            settings.relayURLString = pending.relayWebSocketURL.absoluteString
        } catch PhonePairingCredentialStorageError.invalidState {
            return .superseded
        } catch PhonePairingCredentialStorageError.corruptState {
            return .storageCorrupt
        } catch {
            return .promotionFailed
        }
        guard generation == expectedGeneration else { return .superseded }
        normalTransport.connect(configuration: configuration)
        return .recovered
    }

    private func bind(
        _ socket: any PhoneWebSocket,
        generation expectedGeneration: UInt64,
        claimID: UUID,
        reference: String,
        nonce: String
    ) {
        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket, self.owns(socket, expectedGeneration) else { return }
            socket.onOpen = nil
            self.opened = true
            self.receiveState = .claiming
            self.publish(.claiming)
            let message = PhoneClientMessage.pairClaim(.init(
                reference: reference,
                claimID: claimID,
                sessionNonce: nonce,
                clientKind: .ios
            ))
            self.send(message, socket: socket, generation: expectedGeneration, failure: "claim_send_failed")
            guard self.owns(socket, expectedGeneration) else { return }
            self.schedule(after: 10, generation: expectedGeneration, socket: socket, reason: "claim_timeout")
        }
        socket.onText = { [weak self, weak socket] text in
            guard let self, let socket else { return }
            self.receive(text, socket: socket, generation: expectedGeneration, claimID: claimID)
        }
        socket.onBinary = { [weak self, weak socket] _ in
            guard let self, let socket, self.owns(socket, expectedGeneration) else { return }
            self.fail("invalid_response", socket: socket)
        }
        socket.onClose = { [weak self, weak socket] closure in
            guard let self, let socket, self.owns(socket, expectedGeneration) else { return }
            if closure.code == PhoneProtocolV1.credentialReplacedCloseCode {
                self.terminateAuthoritative(.replaced, failure: nil, socket: socket)
            } else {
                self.fail("disconnected", socket: socket)
            }
        }
    }

    private func receive(_ text: String, socket: any PhoneWebSocket, generation expectedGeneration: UInt64,
                         claimID: UUID) {
        guard owns(socket, expectedGeneration) else { return }
        let message: PhoneServerMessage
        do {
            message = try decoder.decodePairingText(
                text,
                context: .init(claimID: claimID, generation: expectedGeneration, state: receiveState),
                activeGeneration: generation
            )
        } catch {
            fail("invalid_response", socket: socket)
            return
        }
        switch message {
        case .pairClaimedPhone(let claimed):
            receiveState = .awaitingCredential
            let remaining = max(0, Double(claimed.expiresAtUnixMs) - clock.nowUnixMilliseconds()) / 1_000
            publish(.awaitingApproval,
                    confirmationCode: claimed.confirmationCode,
                    expiresAt: claimed.expiresAtUnixMs)
            schedule(after: min(PhoneProtocolV1.pairingTTL, remaining),
                     generation: expectedGeneration, socket: socket, reason: "expired")
        case .pairCredential(let offered):
            let credential = PhonePairingCredential(
                token: offered.credential,
                version: offered.credentialVersion
            )
            guard let relayWebSocketURL else {
                fail("activation_failed", socket: socket)
                return
            }
            let pending: PhonePairingPendingCredential
            do {
                pending = try settings.stagePairingCredential(
                    credential,
                    relayWebSocketURL: relayWebSocketURL,
                    replacementAuthorization: replacementAuthorization
                )
            }
            catch { fail("storage_failed", socket: socket); return }
            self.pending = pending
            let context = "clickbridge-pair-activate:v1:\(claimID.uuidString.lowercased()):\(credential.version)"
            guard let keyBytes = Self.hexBytes(credential.token) else {
                fail("activation_failed", socket: socket)
                return
            }
            let proof = HMAC<SHA256>.authenticationCode(
                for: Data(context.utf8), using: SymmetricKey(data: keyBytes)
            ).map { String(format: "%02x", $0) }.joined()
            receiveState = .awaitingActivation
            publish(.awaitingActivation)
            send(.pairCredentialAcknowledgement(.init(
                claimID: claimID,
                credentialVersion: credential.version,
                proof: proof
            )), socket: socket, generation: expectedGeneration, failure: "activation_failed")
        case .pairActive(let active):
            guard let pending,
                  pending.credential.version == active.activePhoneCredentialVersion,
                  let relayWebSocketURL,
                  let configuration = try? RelayConfiguration.validated(
                    urlString: relayWebSocketURL.absoluteString,
                    token: pending.credential.token
                  ) else {
                fail("activation_failed", socket: socket)
                return
            }
            do {
                try settings.promotePairingCredential(pending)
                settings.relayURLString = relayWebSocketURL.absoluteString
            }
            catch { fail("storage_failed", socket: socket); return }
            generation &+= 1
            retire(reason: "pairing_complete")
            clearSensitive()
            normalTransport.connect(configuration: configuration)
            publish(.active)
        case .pairFailed(let failure):
            terminateAuthoritative(
                failure.reason == .replaced ? .replaced : .failed,
                failure: failure.reason.rawValue,
                socket: socket
            )
        default:
            fail("invalid_response", socket: socket)
        }
    }

    private func send(_ message: PhoneClientMessage, socket: any PhoneWebSocket,
                      generation expectedGeneration: UInt64, failure: String) {
        do {
            try socket.send(text: message.encodedText()) { [weak self, weak socket] error in
                guard let self, let socket, error != nil, self.owns(socket, expectedGeneration) else { return }
                self.fail(failure, socket: socket)
            }
        } catch {
            fail(failure, socket: socket)
        }
    }

    private func schedule(after delay: TimeInterval, generation expectedGeneration: UInt64,
                          socket: any PhoneWebSocket, reason: String) {
        if let timeout { scheduler.cancel(timeout) }
        timeout = scheduler.schedule(after: max(0, delay)) { [weak self, weak socket] in
            guard let self, let socket, self.owns(socket, expectedGeneration) else { return }
            self.fail(reason, socket: socket)
        }
    }

    private func owns(_ candidate: any PhoneWebSocket, _ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && candidate === socket
    }

    private func fail(_ reason: String, socket: any PhoneWebSocket) {
        terminate(.failed, failure: reason, socket: socket)
    }

    private func terminate(_ phase: PhonePairingPhase, failure: String?, socket: any PhoneWebSocket) {
        guard socket === self.socket else { return }
        generation &+= 1
        retire(reason: failure ?? "terminal")
        clearSensitive()
        publish(phase, failure: failure)
    }

    private func terminateAuthoritative(
        _ phase: PhonePairingPhase,
        failure: String?,
        socket: any PhoneWebSocket
    ) {
        guard socket === self.socket else { return }
        if let pending {
            do { try settings.discardPairingCredential(pending) }
            catch {
                terminate(.failed, failure: "storage_failed", socket: socket)
                return
            }
        }
        terminate(phase, failure: failure, socket: socket)
    }

    private func retire(reason: String) {
        if let timeout { scheduler.cancel(timeout) }
        timeout = nil
        let old = socket
        socket = nil
        opened = false
        old?.onOpen = nil
        old?.onText = nil
        old?.onBinary = nil
        old?.onClose = nil
        old?.close(code: .goingAway, reason: reason)
    }

    private func clearSensitive() {
        currentClaimID = nil
        pending = nil
        relayWebSocketURL = nil
        replacementAuthorization = nil
    }

    private func publish(_ phase: PhonePairingPhase, failure: String? = nil,
                         confirmationCode: String? = nil, expiresAt: Int? = nil) {
        state = .init(
            phase: phase,
            confirmationCode: confirmationCode,
            expiresAtUnixMilliseconds: expiresAt,
            failure: failure
        )
        onState?(state)
    }

    private static func hexBytes(_ value: String) -> Data? {
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        var result = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
