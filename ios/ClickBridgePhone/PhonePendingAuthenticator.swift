import Foundation

enum PhonePendingAuthenticationResult: Equatable, Sendable {
    case authenticated, rejected, unavailable
}

@MainActor
final class PhonePendingAuthenticator {
    private let transport: any PhoneActionTransport
    private var continuation: CheckedContinuation<PhonePendingAuthenticationResult, Never>?
    private var expectedGeneration: Int?

    init(transport: any PhoneActionTransport) {
        self.transport = transport
    }

    func authenticate(_ configuration: RelayConfiguration) async -> PhonePendingAuthenticationResult {
        finish(.unavailable, reason: "pending_authentication_superseded")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                self.continuation = continuation
                transport.onEvent = { [weak self] event in self?.handle(event) }
                transport.connect(configuration: configuration)
                expectedGeneration = transport.generation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.unavailable, reason: "pending_authentication_cancelled")
            }
        }
    }

    private func handle(_ event: PhoneTransportEvent) {
        guard case .connection(let generation, let state) = event,
              expectedGeneration != nil,
              generation == transport.generation else { return }
        switch state {
        case .authenticated:
            finish(.authenticated, reason: "pending_authentication_complete")
        case .authenticationRejected:
            finish(.rejected, reason: "pending_authentication_rejected")
        case .backoff, .takenOver, .disconnected:
            finish(.unavailable, reason: "pending_authentication_unavailable")
        case .connecting, .authenticating:
            break
        }
    }

    private func finish(_ result: PhonePendingAuthenticationResult, reason: String) {
        guard let continuation else { return }
        self.continuation = nil
        expectedGeneration = nil
        transport.onEvent = nil
        transport.disconnect(reason: reason)
        continuation.resume(returning: result)
    }
}
