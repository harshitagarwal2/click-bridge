import Foundation

protocol WebSocketTransport: AnyObject, Sendable {
    func connect(to url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

/// Production transport. No third-party socket dependency.
final class URLSessionTransport: WebSocketTransport, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func connect(to url: URL) async throws {
        let t = session.webSocketTask(with: url)
        t.resume()
        task = t
    }

    func send(_ text: String) async throws {
        guard let task else { throw URLError(.badServerResponse) }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw URLError(.badServerResponse) }
        switch try await task.receive() {
        case .string(let s): return s
        case .data: return ""            // binary frames carry no meaning here
        @unknown default: return ""
        }
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

/// Owns exactly one socket generation, one receive loop, and one reconnect
/// task. Never resends an action.
actor RelayClient {

    enum Status: Equatable { case disconnected, connecting, connected }

    private let makeTransport: @Sendable () -> WebSocketTransport
    private let processor: ActionProcessor
    private let ingress: ActionIngress

    private var transport: WebSocketTransport?
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pendingHeartbeat: Int?
    private var sequence = 0
    private var attempt = 0
    private var suspended = false

    private(set) var status: Status = .disconnected

    var url: URL?
    var token: String?
    var onStatus: (@Sendable (Status) -> Void)?

    /// Read at publish time so the menu toggle and permission are never stale.
    var stateProvider: (@Sendable () -> (remoteEnabled: Bool, permission: PermissionState))?

    init(
        processor: ActionProcessor,
        ingress: ActionIngress = .oci,
        makeTransport: @escaping @Sendable () -> WebSocketTransport = { URLSessionTransport() }
    ) {
        self.processor = processor
        self.ingress = ingress
        self.makeTransport = makeTransport
    }

    func configure(url: URL?, token: String?) {
        self.url = url
        self.token = token
    }

    func start() {
        suspended = false
        openSocket()
    }

    /// Sets the gate BEFORE tearing down, so no in-flight callback can revive it.
    func stop() async {
        suspended = true
        generation += 1
        loop?.cancel(); loop = nil
        heartbeat?.cancel(); heartbeat = nil
        await transport?.close()
        transport = nil
        setStatus(.disconnected)
    }

    func reconnect() async {
        await stop()
        start()
    }

    private func setStatus(_ s: Status) {
        status = s
        onStatus?(s)
    }

    private func openSocket() {
        guard !suspended, let url, let token, !token.isEmpty else { return }
        generation += 1
        let myGeneration = generation
        setStatus(.connecting)

        let transport = makeTransport()
        self.transport = transport

        loop = Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.connect(to: url)
                let hello = try Wire.encode(Hello(role: "mac", token: token))
                try await transport.send(hello)

                while !Task.isCancelled {
                    let text = try await transport.receive()
                    if await self.isStale(myGeneration) { return }
                    if text.isEmpty { continue }
                    await self.handle(text, generation: myGeneration)
                }
            } catch {
                if await self.isStale(myGeneration) { return }
                await self.scheduleReconnect(myGeneration)
            }
        }
    }

    private func isStale(_ g: Int) -> Bool { g != generation }

    private func handle(_ text: String, generation g: Int) async {
        guard let message = try? Wire.decode(text) else { return }   // invalid: no side effect

        switch message {
        case .helloOK:
            attempt = 0
            setStatus(.connected)
            await publishState()
            startHeartbeat(g)

        case .heartbeatAck(let ack):
            if pendingHeartbeat == ack.sequence { pendingHeartbeat = nil }

        case .heartbeatRequest(let req):
            try? await transport?.send(Wire.encode(HeartbeatAck(sequence: req.sequence)))

        case .actionRequest(let request):
            let result = await processor.receive(request, via: ingress)
            if let payload = try? Wire.encode(result) {
                try? await transport?.send(payload)
            }

        case .timeSyncRequest(let req):
            // Answered immediately, off the action actor, with wall-clock samples.
            let receive = Date().timeIntervalSince1970 * 1000
            let response = TimeSyncResponse(
                syncId: req.syncId,
                phoneSendUnixMs: req.phoneSendUnixMs,
                macReceiveUnixMs: receive,
                macSendUnixMs: Date().timeIntervalSince1970 * 1000
            )
            try? await transport?.send(Wire.encode(response))

        default:
            break
        }
    }

    func publishState() async {
        guard status == .connected, let provider = stateProvider else { return }
        let s = provider()
        let payload = MacState(remoteEnabled: s.remoteEnabled, permission: s.permission)
        if let text = try? Wire.encode(payload) {
            try? await transport?.send(text)
        }
    }

    private func startHeartbeat(_ g: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.heartbeatInterval))
                if await self.isStale(g) { return }
                await self.beat(g)
            }
        }
    }

    private func beat(_ g: Int) async {
        sequence += 1
        let seq = sequence
        pendingHeartbeat = seq
        try? await transport?.send(Wire.encode(HeartbeatRequest(sequence: seq)))

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.heartbeatTimeout))
            guard let self else { return }
            if await self.heartbeatMissed(seq, generation: g) {
                await self.reconnect()
            }
        }
    }

    private func heartbeatMissed(_ seq: Int, generation g: Int) -> Bool {
        !isStale(g) && pendingHeartbeat == seq
    }

    private func scheduleReconnect(_ g: Int) async {
        guard !suspended, !isStale(g) else { return }
        setStatus(.disconnected)
        attempt += 1
        let ceiling = min(Constants.macReconnectCap, 0.5 * pow(2, Double(attempt - 1)))
        let delay = Double.random(in: 0...ceiling)      // full jitter
        try? await Task.sleep(for: .seconds(delay))
        guard !suspended, !isStale(g) else { return }
        openSocket()
    }
}
