import Foundation

struct RelayConfiguration: Equatable, Sendable {
    let url: URL
    let token: String
}

enum PhoneConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case authenticated
    case backoff
    case takenOver
    case authenticationRejected
}

enum PhoneTransportEvent: Equatable, Sendable {
    case connection(generation: Int, state: PhoneConnectionState)
    case message(generation: Int, value: PhoneServerMessage)
}

@MainActor
final class PhoneRelayClient: PhoneActionTransport {
    private let socketFactory: any PhoneWebSocketFactory
    private let clock: any PhoneClock
    private let scheduler: any PhoneScheduler
    private let randomUnit: @MainActor () -> Double
    private let decoder = StrictPhoneWireDecoder()

    private(set) var generation = 0
    private(set) var isAuthenticated = false
    var onEvent: (@MainActor (PhoneTransportEvent) -> Void)?

    private var configuration: RelayConfiguration?
    private var socket: (any PhoneWebSocket)?
    private var reconnectAttempt = 0
    private var reconnectToken: ScheduledToken?
    private var heartbeatToken: ScheduledToken?
    private var heartbeatTimeoutToken: ScheduledToken?
    private var nextHeartbeatSequence = 1
    private var pendingHeartbeatSequence: Int?

    init(
        socketFactory: any PhoneWebSocketFactory,
        clock: any PhoneClock,
        scheduler: any PhoneScheduler,
        randomUnit: @escaping @MainActor () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.socketFactory = socketFactory
        self.clock = clock
        self.scheduler = scheduler
        self.randomUnit = randomUnit
    }

    func connect(configuration: RelayConfiguration) {
        invalidateCurrentSocket(reason: "reconfigure", scheduleReconnect: false)
        self.configuration = configuration
        reconnectAttempt = 0
        beginConnection()
    }

    func disconnect(reason: String) {
        configuration = nil
        reconnectAttempt = 0
        invalidateCurrentSocket(reason: reason, scheduleReconnect: false)
        publishConnection(.disconnected)
    }

    func send(_ message: PhoneClientMessage) -> Bool {
        guard isAuthenticated, let socket else { return false }
        let expectedGeneration = generation
        do {
            try socket.send(text: message.encodedText()) { [weak self, weak socket] error in
                guard let self, let socket, error != nil else { return }
                self.fail(generation: expectedGeneration, socket: socket, reason: "send_failed")
            }
            return true
        } catch {
            fail(generation: expectedGeneration, socket: socket, reason: "send_failed")
            return false
        }
    }

    private func beginConnection() {
        guard let configuration else { return }
        cancelTimers()
        generation += 1
        let expectedGeneration = generation
        isAuthenticated = false
        pendingHeartbeatSequence = nil
        let socket = socketFactory.makeSocket()
        self.socket = socket
        publishConnection(.connecting)

        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket else { return }
            self.opened(socket: socket, generation: expectedGeneration, configuration: configuration)
        }
        socket.onText = { [weak self, weak socket] text in
            guard let self, let socket else { return }
            self.received(text: text, socket: socket, generation: expectedGeneration)
        }
        socket.onBinary = { [weak self, weak socket] data in
            guard let self, let socket else { return }
            do { _ = try self.decoder.rejectBinary(data) }
            catch { self.fail(generation: expectedGeneration, socket: socket, reason: "binary_frame") }
        }
        socket.onClose = { [weak self, weak socket] closure in
            guard let self, let socket else { return }
            if closure.code == PhoneProtocolV1.phoneTakenOverCloseCode {
                self.phoneWasTakenOver(generation: expectedGeneration, socket: socket)
            } else if closure.code == PhoneProtocolV1.authenticationRejectedCloseCode {
                self.authenticationWasRejected(generation: expectedGeneration, socket: socket)
            } else {
                self.fail(generation: expectedGeneration, socket: socket, reason: "socket_closed")
            }
        }
        socket.open(url: configuration.url)
    }

    private func opened(socket: any PhoneWebSocket, generation expectedGeneration: Int,
                        configuration: RelayConfiguration) {
        guard owns(socket: socket, generation: expectedGeneration) else { return }
        publishConnection(.authenticating)
        do {
            try socket.send(text: PhoneClientMessage.hello(
                Hello(role: "phone", token: configuration.token)
            ).encodedText()) { [weak self, weak socket] error in
                guard let self, let socket, error != nil else { return }
                self.fail(generation: expectedGeneration, socket: socket, reason: "hello_send_failed")
            }
        } catch {
            fail(generation: expectedGeneration, socket: socket, reason: "hello_send_failed")
        }
    }

    private func received(text: String, socket: any PhoneWebSocket, generation expectedGeneration: Int) {
        guard owns(socket: socket, generation: expectedGeneration) else { return }
        let message: PhoneServerMessage
        do {
            message = try decoder.decodeText(text)
        } catch {
            fail(generation: expectedGeneration, socket: socket, reason: "invalid_frame")
            return
        }

        if !isAuthenticated {
            guard case .helloOK = message else {
                fail(generation: expectedGeneration, socket: socket, reason: "pre_auth_message")
                return
            }
            isAuthenticated = true
            reconnectAttempt = 0
            nextHeartbeatSequence = 1
            publishConnection(.authenticated)
            scheduleHeartbeat(generation: expectedGeneration, socket: socket)
            return
        }

        if case .helloOK = message {
            fail(generation: expectedGeneration, socket: socket, reason: "duplicate_hello")
            return
        }
        if case .heartbeatAck(let ack) = message {
            guard ack.sequence == pendingHeartbeatSequence else {
                fail(generation: expectedGeneration, socket: socket, reason: "heartbeat_mismatch")
                return
            }
            pendingHeartbeatSequence = nil
            cancel(&heartbeatTimeoutToken)
            scheduleHeartbeat(generation: expectedGeneration, socket: socket)
            return
        }
        onEvent?(.message(generation: expectedGeneration, value: message))
    }

    private func scheduleHeartbeat(generation expectedGeneration: Int, socket: any PhoneWebSocket) {
        cancel(&heartbeatToken)
        heartbeatToken = scheduler.schedule(after: PhoneProtocolV1.heartbeatInterval) { [weak self, weak socket] in
            guard let self, let socket, self.owns(socket: socket, generation: expectedGeneration),
                  self.isAuthenticated else { return }
            self.heartbeatToken = nil
            let sequence = self.nextHeartbeatSequence
            self.nextHeartbeatSequence += 1
            self.pendingHeartbeatSequence = sequence
            do {
                try socket.send(text: PhoneClientMessage.heartbeatRequest(
                    HeartbeatRequest(sequence: sequence)
                ).encodedText()) { [weak self, weak socket] error in
                    guard let self, let socket, error != nil else { return }
                    self.fail(
                        generation: expectedGeneration,
                        socket: socket,
                        reason: "heartbeat_send_failed"
                    )
                }
            } catch {
                self.fail(generation: expectedGeneration, socket: socket, reason: "heartbeat_send_failed")
                return
            }
            self.heartbeatTimeoutToken = self.scheduler.schedule(after: PhoneProtocolV1.heartbeatTimeout) {
                [weak self, weak socket] in
                guard let self, let socket, self.owns(socket: socket, generation: expectedGeneration),
                      self.pendingHeartbeatSequence == sequence else { return }
                self.heartbeatTimeoutToken = nil
                self.fail(generation: expectedGeneration, socket: socket, reason: "heartbeat_timeout")
            }
        }
    }

    private func fail(generation expectedGeneration: Int, socket: any PhoneWebSocket, reason: String) {
        guard owns(socket: socket, generation: expectedGeneration) else { return }
        invalidateCurrentSocket(reason: reason, scheduleReconnect: true)
    }

    private func phoneWasTakenOver(generation expectedGeneration: Int, socket: any PhoneWebSocket) {
        guard owns(socket: socket, generation: expectedGeneration) else { return }
        invalidateCurrentSocket(reason: "phone_taken_over", scheduleReconnect: false)
        publishConnection(.takenOver)
    }

    private func authenticationWasRejected(generation expectedGeneration: Int,
                                           socket: any PhoneWebSocket) {
        guard owns(socket: socket, generation: expectedGeneration) else { return }
        configuration = nil
        reconnectAttempt = 0
        invalidateCurrentSocket(reason: "authentication_rejected", scheduleReconnect: false)
        publishConnection(.authenticationRejected)
    }

    private func invalidateCurrentSocket(reason: String, scheduleReconnect: Bool) {
        let oldSocket = socket
        socket = nil
        generation += 1
        isAuthenticated = false
        pendingHeartbeatSequence = nil
        cancelTimers()
        oldSocket?.onOpen = nil
        oldSocket?.onText = nil
        oldSocket?.onBinary = nil
        oldSocket?.onClose = nil
        oldSocket?.close(code: .goingAway, reason: reason)

        if scheduleReconnect, configuration != nil {
            scheduleReconnectTimer()
        } else if configuration != nil {
            publishConnection(.disconnected)
        }
    }

    private func scheduleReconnectTimer() {
        reconnectAttempt += 1
        let exponent = min(reconnectAttempt - 1, 30)
        let ceiling = min(
            PhoneProtocolV1.reconnectCap,
            PhoneProtocolV1.reconnectBase * pow(2, Double(exponent))
        )
        let delay = max(0, min(1, randomUnit())) * ceiling
        publishConnection(.backoff)
        reconnectToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.configuration != nil else { return }
            self.reconnectToken = nil
            self.beginConnection()
        }
    }

    private func owns(socket candidate: any PhoneWebSocket, generation expectedGeneration: Int) -> Bool {
        generation == expectedGeneration && candidate === socket
    }

    private func publishConnection(_ state: PhoneConnectionState) {
        onEvent?(.connection(generation: generation, state: state))
    }

    private func cancelTimers() {
        cancel(&reconnectToken)
        cancel(&heartbeatToken)
        cancel(&heartbeatTimeoutToken)
    }

    private func cancel(_ token: inout ScheduledToken?) {
        if let token { scheduler.cancel(token) }
        token = nil
    }
}

@MainActor
final class URLSessionPhoneWebSocketFactory: PhoneWebSocketFactory {
    func makeSocket() -> any PhoneWebSocket { URLSessionPhoneWebSocket() }
}

struct URLSessionPhoneWebSocketCloseArbiter {
    private var delivered = false

    mutating func receiveFailure(_ error: Error) -> PhoneWebSocketClosure? {
        _ = error
        // A receive callback can fail before URLSession delivers the peer's close code.
        // The delegate callbacks below exclusively own terminal close delivery.
        return nil
    }

    mutating func delegateClose(code: Int) -> PhoneWebSocketClosure? {
        claim(.init(code: code, error: nil))
    }

    mutating func taskCompletion(error: Error?, closeCode: Int) -> PhoneWebSocketClosure? {
        guard let error else { return nil }
        return claim(.init(code: Self.applicationCloseCode(closeCode), error: error))
    }

    private static func applicationCloseCode(_ code: Int) -> Int? {
        code >= 3_000 ? code : nil
    }

    private mutating func claim(_ closure: PhoneWebSocketClosure) -> PhoneWebSocketClosure? {
        guard !delivered else { return nil }
        delivered = true
        return closure
    }
}

@MainActor
final class URLSessionPhoneWebSocket: NSObject, PhoneWebSocket, URLSessionWebSocketDelegate {
    var onOpen: (@MainActor () -> Void)?
    var onText: (@MainActor (String) -> Void)?
    var onBinary: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor (PhoneWebSocketClosure) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closeDelivered = false
    private var closeArbiter = URLSessionPhoneWebSocketCloseArbiter()

    func open(url: URL) {
        close(code: .goingAway, reason: "replace")
        closeDelivered = false
        closeArbiter = URLSessionPhoneWebSocketCloseArbiter()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveNext(from: task)
    }

    func send(text: String, completion: @escaping @MainActor @Sendable (Error?) -> Void) throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: String) {
        task?.cancel(with: code, reason: Data(reason.utf8))
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard self?.task === webSocketTask else { return }
            self?.onOpen?()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self, let closure = self.closeArbiter.delegateClose(code: closeCode.rawValue) else { return }
            self.deliverClose(closure)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        Task { @MainActor [weak self] in
            guard let self, self.task === webSocketTask,
                  let closure = self.closeArbiter.taskCompletion(
                    error: error,
                    closeCode: webSocketTask.closeCode.rawValue
                  ) else { return }
            self.deliverClose(closure)
        }
    }

    private func receiveNext(from expectedTask: URLSessionWebSocketTask) {
        expectedTask.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === expectedTask else { return }
                switch result {
                case .success(.string(let text)): self.onText?(text)
                case .success(.data(let data)): self.onBinary?(data)
                case .failure(let error):
                    _ = self.closeArbiter.receiveFailure(error)
                    return
                @unknown default:
                    self.deliverClose(.init(code: nil, error: URLError(.cannotDecodeContentData)))
                    return
                }
                self.receiveNext(from: expectedTask)
            }
        }
    }

    private func deliverClose(_ closure: PhoneWebSocketClosure) {
        guard !closeDelivered else { return }
        closeDelivered = true
        onClose?(closure)
    }
}
