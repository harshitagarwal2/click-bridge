import Foundation

enum WebSocketTransportError: Error, Equatable { case notConnected, binaryFrame }

protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

actor URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    init(session: URLSession = .shared) { self.session = session }

    func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        task.resume()
        self.task = task
    }
    func sendText(_ text: String) async throws {
        guard let task else { throw WebSocketTransportError.notConnected }
        try await task.send(.string(text))
    }
    func receiveText() async throws -> String {
        guard let task else { throw WebSocketTransportError.notConnected }
        switch try await task.receive() {
        case .string(let text): return text
        case .data: throw WebSocketTransportError.binaryFrame
        @unknown default: throw WebSocketTransportError.binaryFrame
        }
    }
    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

enum RelayEndpointError: Error, Equatable { case invalidURL, invalidScheme, invalidPath, forbiddenComponents }

enum RelayEndpoint {
    static func validated(_ value: String, allowLocalSimulator: Bool) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { throw RelayEndpointError.invalidURL }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "wss" || (allowLocalSimulator && local && scheme == "ws") else {
            throw RelayEndpointError.invalidScheme
        }
        guard url.path == "/ws" else { throw RelayEndpointError.invalidPath }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw RelayEndpointError.forbiddenComponents
        }
        return url
    }
}

actor RelayClient {
    enum Status: Equatable, Sendable { case disconnected, connecting, connected }

    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Jitter = @Sendable (TimeInterval) -> TimeInterval

    private let actionSink: any ActionRequestSink
    private let diagnostics: any DiagnosticCounterReading
    private let makeTransport: @Sendable () -> any WebSocketTransport
    private let sleep: Sleep
    private let jitter: Jitter
    private let wallClockMilliseconds: @Sendable () -> Double
    private let decoder = StrictWireDecoder()

    private var endpoint: URL?
    private var token: String?
    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var reconnectAttempt = 0
    private var sequence = 0
    private var pendingHeartbeat: Int?
    private var running = false
    private var status: Status = .disconnected
    private var advertisedState = MacState(remoteEnabled: false, permission: .unknown)
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var resultHandler: (@Sendable (ActionResult) -> Void)?

    init(
        actionSink: any ActionRequestSink,
        diagnostics: any DiagnosticCounterReading,
        makeTransport: @escaping @Sendable () -> any WebSocketTransport = { URLSessionWebSocketTransport() },
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        jitter: @escaping Jitter = { ceiling in Double.random(in: 0...ceiling) },
        wallClockMilliseconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }
    ) {
        self.actionSink = actionSink
        self.diagnostics = diagnostics
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.jitter = jitter
        self.wallClockMilliseconds = wallClockMilliseconds
    }

    func setStatusHandler(_ handler: (@Sendable (Status) -> Void)?) { statusHandler = handler }
    func setResultHandler(_ handler: (@Sendable (ActionResult) -> Void)?) { resultHandler = handler }
    func currentStatus() -> Status { status }

    func configure(urlString: String, token: String, allowLocalSimulator: Bool) async throws {
        let validated = try RelayEndpoint.validated(urlString, allowLocalSimulator: allowLocalSimulator)
        await cancelGeneration()
        endpoint = validated
        self.token = token
    }

    func updateAdvertisedState(_ snapshot: MacState) async {
        advertisedState = snapshot
        if status == .connected { try? await send(snapshot) }
    }

    func start() {
        running = true
        guard receiveTask == nil, reconnectTask == nil else { return }
        openGeneration()
    }

    func stop() async {
        running = false
        await cancelGeneration()
        setStatus(.disconnected)
    }

    func reconnect() async {
        await cancelGeneration()
        guard running else { return }
        openGeneration()
    }

    private func cancelGeneration() async {
        generation += 1
        receiveTask?.cancel(); receiveTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
        pendingHeartbeat = nil
        let old = transport
        transport = nil
        await old?.close()
    }

    private func setStatus(_ value: Status) {
        guard status != value else { return }
        status = value
        statusHandler?(value)
    }

    private func openGeneration() {
        guard running, let endpoint, let token, !token.isEmpty else { setStatus(.disconnected); return }
        generation += 1
        let currentGeneration = generation
        let socket = makeTransport()
        transport = socket
        setStatus(.connecting)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await socket.connect(to: endpoint)
                try await socket.sendText(Wire.encode(Hello(role: "mac", token: token)))
                while !Task.isCancelled {
                    let text = try await socket.receiveText()
                    try await self.handle(text, generation: currentGeneration, socket: socket)
                }
            } catch {
                await self.generationFailed(currentGeneration)
            }
        }
    }

    private func handle(_ text: String, generation expected: Int, socket: any WebSocketTransport) async throws {
        guard expected == generation else { return }
        let message = try decoder.decodeText(text, for: .mac)
        switch message {
        case .helloOK(let hello) where hello.role == "mac":
            reconnectAttempt = 0
            setStatus(.connected)
            try await send(advertisedState)
            startHeartbeat(generation: expected)
        case .heartbeatAck(let ack):
            if ack.sequence == pendingHeartbeat {
                pendingHeartbeat = nil
                heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
            }
        case .heartbeatRequest(let request):
            try await send(HeartbeatAck(sequence: request.sequence))
        case .actionRequest(let request):
            let result = await actionSink.receive(request, via: .oci)
            resultHandler?(result)
            try await send(result)
        case .timeSyncRequest(let request):
            let received = wallClockMilliseconds()
            try await send(TimeSyncResponse(syncId: request.syncId,
                                            phoneSendUnixMs: request.phoneSendUnixMs,
                                            macReceiveUnixMs: received,
                                            macSendUnixMs: wallClockMilliseconds()))
        case .diagnosticsRequest(let request):
            let counts = await diagnostics.diagnosticPostCounts()
            try await send(DiagnosticsCounters(requestId: request.requestId,
                                               mouseDownPostCount: counts.mouseDownPostCount,
                                               mouseUpPostCount: counts.mouseUpPostCount))
        default: break
        }
    }

    private func send<T: Encodable>(_ value: T) async throws {
        guard let transport else { throw WebSocketTransportError.notConnected }
        try await transport.sendText(Wire.encode(value))
    }

    private func startHeartbeat(generation expected: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.sleep(Constants.heartbeatInterval) } catch { return }
                guard await self.isCurrent(expected) else { return }
                await self.originateHeartbeat(generation: expected)
            }
        }
    }

    private func isCurrent(_ expected: Int) -> Bool { running && expected == generation }

    private func originateHeartbeat(generation expected: Int) async {
        sequence += 1
        let sentSequence = sequence
        pendingHeartbeat = sentSequence
        do { try await send(HeartbeatRequest(sequence: sentSequence)) }
        catch { await generationFailed(expected); return }
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(Constants.heartbeatTimeout) } catch { return }
            await self.heartbeatTimedOut(sentSequence, generation: expected)
        }
    }

    private func heartbeatTimedOut(_ expectedSequence: Int, generation expected: Int) async {
        guard expected == generation, pendingHeartbeat == expectedSequence else { return }
        await generationFailed(expected)
    }

    private func generationFailed(_ expected: Int) async {
        guard running, expected == generation else { return }
        receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
        pendingHeartbeat = nil
        let old = transport; transport = nil
        await old?.close()
        setStatus(.disconnected)
        reconnectAttempt += 1
        let ceiling = min(Constants.macReconnectCap, 0.5 * pow(2, Double(reconnectAttempt - 1)))
        let delay = jitter(ceiling)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            await self.resumeAfterBackoff(expected)
        }
    }

    private func resumeAfterBackoff(_ expected: Int) {
        guard running, expected == generation else { return }
        reconnectTask = nil
        openGeneration()
    }
}
