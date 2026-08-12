import Foundation

enum PhonePendingAuthenticationResult: Equatable, Sendable {
    case authenticated, rejected, unavailable
}

@MainActor
final class PhonePendingAuthenticator {
    private let transport: any PhoneActionTransport
    private var continuation: CheckedContinuation<PhonePendingAuthenticationResult, Never>?
    private var cancellationToken: CancellationToken?
    private var expectedGeneration: Int?

    init(transport: any PhoneActionTransport) {
        self.transport = transport
    }

    func authenticate(_ configuration: RelayConfiguration) async -> PhonePendingAuthenticationResult {
        finish(.unavailable, reason: "pending_authentication_superseded")
        let cancellationToken = CancellationToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !cancellationToken.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                self.continuation = continuation
                self.cancellationToken = cancellationToken
                transport.onEvent = { [weak self] event in self?.handle(event) }
                transport.connect(configuration: configuration)
                expectedGeneration = transport.generation
            }
        } onCancel: {
            cancellationToken.cancel()
            Task { @MainActor [weak self] in
                self?.finish(
                    .unavailable,
                    reason: "pending_authentication_cancelled",
                    cancellationToken: cancellationToken
                )
            }
        }
    }

    private func handle(_ event: PhoneTransportEvent) {
        guard case .connection(let generation, let state) = event,
              expectedGeneration != nil,
              generation == transport.generation else { return }
        if cancellationToken?.isCancelled == true {
            finish(.unavailable, reason: "pending_authentication_cancelled")
            return
        }
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

    private func finish(
        _ result: PhonePendingAuthenticationResult,
        reason: String,
        cancellationToken expectedCancellationToken: CancellationToken? = nil
    ) {
        if let expectedCancellationToken,
           cancellationToken !== expectedCancellationToken { return }
        guard let continuation else { return }
        self.continuation = nil
        cancellationToken = nil
        expectedGeneration = nil
        transport.onEvent = nil
        transport.disconnect(reason: reason)
        continuation.resume(returning: result)
    }
}

private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
