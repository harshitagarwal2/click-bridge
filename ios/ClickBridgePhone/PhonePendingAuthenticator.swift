import Foundation

@MainActor
final class PhonePendingAuthenticator {
    private let transport: any PhoneActionTransport
    private var continuation: CheckedContinuation<Bool, Never>?
    private var expectedGeneration: Int?

    init(transport: any PhoneActionTransport) {
        self.transport = transport
    }

    func authenticate(_ configuration: RelayConfiguration) async -> Bool {
        finish(false, reason: "pending_authentication_superseded")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                transport.onEvent = { [weak self] event in self?.handle(event) }
                transport.connect(configuration: configuration)
                expectedGeneration = transport.generation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(false, reason: "pending_authentication_cancelled")
            }
        }
    }

    private func handle(_ event: PhoneTransportEvent) {
        guard case .connection(let generation, let state) = event,
              generation == expectedGeneration else { return }
        switch state {
        case .authenticated:
            finish(true, reason: "pending_authentication_complete")
        case .backoff, .takenOver, .disconnected:
            finish(false, reason: "pending_authentication_rejected")
        case .connecting, .authenticating:
            break
        }
    }

    private func finish(_ result: Bool, reason: String) {
        guard let continuation else { return }
        self.continuation = nil
        expectedGeneration = nil
        transport.onEvent = nil
        transport.disconnect(reason: reason)
        continuation.resume(returning: result)
    }
}
