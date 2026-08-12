import Foundation
@testable import ClickBridgePhone

final class FakePhoneClock: @unchecked Sendable, PhoneClock {
    private let lock = NSLock()
    private var unixMilliseconds: Double
    private var monotonicMilliseconds: Double

    init(unixMilliseconds: Double = 1_786_579_200_000, monotonicMilliseconds: Double = 1_000) {
        self.unixMilliseconds = unixMilliseconds
        self.monotonicMilliseconds = monotonicMilliseconds
    }

    func nowUnixMilliseconds() -> Double {
        lock.withLock { unixMilliseconds }
    }

    func nowMonotonicMilliseconds() -> Double {
        lock.withLock { monotonicMilliseconds }
    }

    func set(unixMilliseconds: Double? = nil, monotonicMilliseconds: Double? = nil) {
        lock.withLock {
            if let unixMilliseconds { self.unixMilliseconds = unixMilliseconds }
            if let monotonicMilliseconds { self.monotonicMilliseconds = monotonicMilliseconds }
        }
    }
}

@MainActor
final class FakePhoneScheduler: PhoneScheduler {
    struct Entry {
        let token: ScheduledToken
        let delay: TimeInterval
        let action: @MainActor () -> Void
    }

    private(set) var entries: [Entry] = []

    @discardableResult
    func schedule(after delay: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let token = ScheduledToken(rawValue: UUID())
        entries.append(Entry(token: token, delay: delay, action: action))
        return token
    }

    func cancel(_ token: ScheduledToken) {
        entries.removeAll { $0.token == token }
    }

    func run(_ token: ScheduledToken) {
        guard let entry = entries.first(where: { $0.token == token }) else { return }
        cancel(token)
        entry.action()
    }

    func runFirst(after delay: TimeInterval) {
        guard let entry = entries.first(where: { $0.delay == delay }) else { return }
        run(entry.token)
    }
}

@MainActor
final class FakeVolumeChangeSource: VolumeChangeSource {
    var currentVolume: Float
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handlers: [(@MainActor (Float) -> Void)] = []
    var startError: Error?

    init(volume: Float = 0.5) {
        currentVolume = volume
    }

    func start(observing handler: @escaping @MainActor (Float) -> Void) throws {
        if let startError { throw startError }
        startCount += 1
        handlers.append(handler)
        handler(currentVolume)
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ volume: Float, observer index: Int? = nil) {
        currentVolume = volume
        if let index {
            guard handlers.indices.contains(index) else { return }
            handlers[index](volume)
        } else {
            handlers.last?(volume)
        }
    }
}

@MainActor
final class FakePhoneHaptics: PhoneHaptics {
    private(set) var terminalResults: [ActionResult] = []

    func terminalResult(_ result: ActionResult) {
        terminalResults.append(result)
    }
}

@MainActor
final class FakePhoneActionTransport: PhoneActionTransport {
    var generation = 0
    var isAuthenticated = false
    var onEvent: (@MainActor (PhoneTransportEvent) -> Void)?
    private(set) var configurations: [RelayConfiguration] = []
    private(set) var disconnectReasons: [String] = []
    private(set) var sendAttempts: [PhoneClientMessage] = []
    private(set) var sentMessages: [PhoneClientMessage] = []
    var sendResult = true

    func connect(configuration: RelayConfiguration) {
        generation += 1
        configurations.append(configuration)
    }

    func disconnect(reason: String) {
        generation += 1
        isAuthenticated = false
        disconnectReasons.append(reason)
    }

    func send(_ message: PhoneClientMessage) -> Bool {
        sendAttempts.append(message)
        guard sendResult else { return false }
        sentMessages.append(message)
        return true
    }

    func emit(_ event: PhoneTransportEvent) {
        onEvent?(event)
    }
}

enum FakePhoneWebSocketError: Error { case sendFailed, closed }

@MainActor
final class FakePhoneWebSocket: PhoneWebSocket {
    var onOpen: (@MainActor () -> Void)?
    var onText: (@MainActor (String) -> Void)?
    var onBinary: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor (PhoneWebSocketClosure) -> Void)?
    private(set) var openedURLs: [URL] = []
    private(set) var sentTexts: [String] = []
    private(set) var closes: [(URLSessionWebSocketTask.CloseCode, String)] = []
    var sendError: Error?
    var automaticallyCompletesSends = true
    private var pendingSendCompletions: [@MainActor @Sendable (Error?) -> Void] = []

    func open(url: URL) {
        openedURLs.append(url)
    }

    func send(text: String, completion: @escaping @MainActor @Sendable (Error?) -> Void) throws {
        if let sendError { throw sendError }
        sentTexts.append(text)
        if automaticallyCompletesSends {
            completion(nil)
        } else {
            pendingSendCompletions.append(completion)
        }
    }

    func completeNextSend(error: Error?) {
        guard !pendingSendCompletions.isEmpty else { return }
        pendingSendCompletions.removeFirst()(error)
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: String) {
        closes.append((code, reason))
    }

    func emitOpen() { onOpen?() }
    func emitText(_ text: String) { onText?(text) }
    func emitBinary(_ data: Data = Data()) { onBinary?(data) }
    func emitClose(_ error: Error? = nil) { onClose?(.init(code: nil, error: error)) }
    func emitClose(code: Int) {
        onClose?(.init(code: code, error: nil))
    }
}

@MainActor
final class FakePhoneWebSocketFactory: PhoneWebSocketFactory {
    private(set) var sockets: [FakePhoneWebSocket] = []

    func makeSocket() -> any PhoneWebSocket {
        let socket = FakePhoneWebSocket()
        sockets.append(socket)
        return socket
    }
}
