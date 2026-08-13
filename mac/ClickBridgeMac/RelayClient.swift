import Foundation

enum WebSocketTransportError: Error, Equatable { case notConnected, binaryFrame, authenticationRejected }

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
        do {
            try await task.send(.string(text))
        } catch {
            if task.closeCode.rawValue == 4_005 {
                throw WebSocketTransportError.authenticationRejected
            }
            throw error
        }
    }
    func receiveText() async throws -> String {
        guard let task else { throw WebSocketTransportError.notConnected }
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: throw WebSocketTransportError.binaryFrame
            @unknown default: throw WebSocketTransportError.binaryFrame
            }
        } catch {
            if task.closeCode.rawValue == 4_005 {
                throw WebSocketTransportError.authenticationRejected
            }
            throw error
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
        guard url.path == "/ws" || url.path.range(of: "^/ws/[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil else {
            throw RelayEndpointError.invalidPath
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw RelayEndpointError.forbiddenComponents
        }
        return url
    }
}

actor RelayClient {
    enum Status: Equatable, Sendable { case disconnected, connecting, connected }
    struct StatusEvent: Sendable {
        enum Cause: Equatable, Sendable { case authenticationRejected }

        let status: Status
        let credentialRevision: UInt64
        let sequence: UInt64
        let cause: Cause?

        init(status: Status, credentialRevision: UInt64, sequence: UInt64, cause: Cause? = nil) {
            self.status = status
            self.credentialRevision = credentialRevision
            self.sequence = sequence
            self.cause = cause
        }
    }
    private struct CredentialMutation: Sendable {
        let revision: UInt64
        let epoch: UInt64
    }
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
    private var authenticatedGeneration: Int?
    private var authenticatedActionAuthorization: ActionAuthorizationLease?
    private var authorizationActivationTask: Task<ActionAuthorizationLease, Never>?
    private var reconnectAttempt = 0
    private var sequence = 0
    private var pendingHeartbeat: Int?
    private var running = false
    private var highestCredentialOperation: UInt64 = 0
    private var credentialMutationEpoch: UInt64 = 0
    private var configuredMutationEpoch: UInt64?
    private var status: Status = .disconnected
    private var advertisedState = MacState(remoteEnabled: false, permission: .unknown)
    private var statusSequence: UInt64 = 0
    private var statusCredentialRevision: UInt64 = 0
    private var statusHandler: (@Sendable (StatusEvent) -> Void)?
    private var resultHandler: (@Sendable (ActionResult) -> Void)?
    private var pairingHandler: (@Sendable (WireMessage) async -> Void)?
    private var phoneManagementHandler: (@Sendable (WireMessage) async -> Void)?

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

    func setStatusHandler(_ handler: (@Sendable (StatusEvent) -> Void)?) { statusHandler = handler }
    func setResultHandler(_ handler: (@Sendable (ActionResult) -> Void)?) { resultHandler = handler }
    func setPairingHandler(_ handler: (@Sendable (WireMessage) async -> Void)?) { pairingHandler = handler }
    func setPhoneManagementHandler(_ handler: (@Sendable (WireMessage) async -> Void)?) { phoneManagementHandler = handler }
    func currentStatus() -> Status { status }

    func sendPairing(_ message: WireMessage) async throws {
        try await sendMacRequest(message, allowed: isPairingRequest)
    }

    func sendPhoneManagement(_ message: WireMessage) async throws {
        try await sendMacRequest(message, allowed: isPhoneManagementRequest)
    }

    private func sendMacRequest(
        _ message: WireMessage,
        allowed: (WireMessage) -> Bool
    ) async throws {
        guard allowed(message), status == .connected,
              authenticatedGeneration == generation, let socket = transport else {
            throw WebSocketTransportError.notConnected
        }
        let expected = generation
        do {
            try await send(message, socket: socket, generation: expected, requireAuthentication: true)
        } catch {
            if isCurrent(expected) {
                await generationFailed(expected, socket: socket)
            }
            throw error
        }
    }

    @discardableResult
    func configure(
        urlString: String,
        token: String,
        allowLocalSimulator: Bool,
        credentialRevision requestedRevision: UInt64? = nil
    ) async throws -> Bool {
        guard let mutation = claimCredentialMutation(requestedRevision) else { return false }
        let validated: URL
        do {
            validated = try RelayEndpoint.validated(urlString, allowLocalSimulator: allowLocalSimulator)
        } catch {
            running = false
            endpoint = nil
            self.token = nil
            await cancelGeneration()
            if isCurrentCredentialMutation(mutation) { setStatus(.disconnected) }
            throw error
        }
        await cancelGeneration()
        guard isCurrentCredentialMutation(mutation) else { return false }
        endpoint = validated
        self.token = token
        configuredMutationEpoch = mutation.epoch
        return true
    }

    func updateAdvertisedState(_ snapshot: MacState) async {
        advertisedState = snapshot
        guard status == .connected, authenticatedGeneration == generation, let socket = transport else { return }
        let expected = generation
        do { try await send(snapshot, socket: socket, generation: expected, requireAuthentication: true) }
        catch { await generationFailed(expected, socket: socket) }
    }

    func start(credentialRevision requestedRevision: UInt64? = nil) {
        if let requestedRevision, requestedRevision != highestCredentialOperation { return }
        guard configuredMutationEpoch == credentialMutationEpoch else { return }
        running = true
        guard receiveTask == nil, reconnectTask == nil else { return }
        openGeneration()
    }

    @discardableResult
    func stop(credentialRevision requestedRevision: UInt64? = nil) async -> Bool {
        guard let mutation = claimCredentialMutation(requestedRevision) else { return false }
        running = false
        await cancelGeneration()
        guard isCurrentCredentialMutation(mutation) else { return false }
        setStatus(.disconnected)
        return true
    }

    @discardableResult
    func clearConfigurationAndStop(credentialRevision requestedRevision: UInt64? = nil) async -> Bool {
        guard let mutation = claimCredentialMutation(requestedRevision) else { return false }
        running = false
        endpoint = nil
        token = nil
        await cancelGeneration()
        guard isCurrentCredentialMutation(mutation) else { return false }
        setStatus(.disconnected)
        return true
    }

    @discardableResult
    func reconnect(credentialRevision requestedRevision: UInt64? = nil) async -> Bool {
        guard let mutation = claimCredentialMutation(requestedRevision) else { return false }
        await cancelGeneration()
        guard isCurrentCredentialMutation(mutation), running else { return false }
        configuredMutationEpoch = mutation.epoch
        openGeneration()
        return true
    }

    private func cancelGeneration() async {
        let authorization = authenticatedActionAuthorization
        let activatingAuthorization = authorizationActivationTask
        generation += 1
        authenticatedGeneration = nil
        authenticatedActionAuthorization = nil
        authorizationActivationTask = nil
        receiveTask?.cancel(); receiveTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
        pendingHeartbeat = nil
        let old = transport
        transport = nil
        if let authorization { await actionSink.revokeAuthorizationLease(authorization) }
        if let activatingAuthorization {
            let activatingLease = await activatingAuthorization.value
            if activatingLease != authorization {
                await actionSink.revokeAuthorizationLease(activatingLease)
            }
        }
        await old?.close()
    }

    private func claimCredentialMutation(_ requestedRevision: UInt64?) -> CredentialMutation? {
        if let requestedRevision {
            guard requestedRevision >= highestCredentialOperation else { return nil }
            highestCredentialOperation = requestedRevision
        } else {
            highestCredentialOperation &+= 1
        }
        credentialMutationEpoch &+= 1
        configuredMutationEpoch = nil
        return CredentialMutation(revision: highestCredentialOperation, epoch: credentialMutationEpoch)
    }

    private func isCurrentCredentialMutation(_ mutation: CredentialMutation) -> Bool {
        mutation.revision == highestCredentialOperation && mutation.epoch == credentialMutationEpoch
    }

    private func setStatus(_ value: Status, cause: StatusEvent.Cause? = nil) {
        guard cause != nil || status != value || statusCredentialRevision != highestCredentialOperation else { return }
        status = value
        statusCredentialRevision = highestCredentialOperation
        statusSequence &+= 1
        statusHandler?(StatusEvent(status: value,
                                   credentialRevision: highestCredentialOperation,
                                   sequence: statusSequence,
                                   cause: cause))
    }

    private func openGeneration() {
        guard running, let endpoint, let token, !token.isEmpty else { setStatus(.disconnected); return }
        generation += 1
        authenticatedGeneration = nil
        let expected = generation
        let socket = makeTransport()
        transport = socket
        setStatus(.connecting)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await socket.connect(to: endpoint)
                guard await self.isCurrent(expected) else { return }
                try await socket.sendText(Wire.encode(Hello(role: "mac", token: token)))
                guard await self.isCurrent(expected) else { return }
                while !Task.isCancelled {
                    let text = try await socket.receiveText()
                    guard await self.isCurrent(expected) else { return }
                    try await self.handle(text, generation: expected, socket: socket)
                }
            } catch {
                if error as? WebSocketTransportError == .authenticationRejected {
                    await self.authenticationRejected(expected, socket: socket)
                } else {
                    await self.generationFailed(expected, socket: socket)
                }
            }
        }
    }

    private func handle(_ text: String, generation expected: Int, socket: any WebSocketTransport) async throws {
        guard isCurrent(expected) else { throw CancellationError() }
        let message = try decoder.decodeText(text, for: .mac)

        if authenticatedGeneration != expected {
            guard case .helloOK(let hello) = message, hello.role == "mac" else {
                throw WireError.messageNotAllowed
            }
            authenticatedGeneration = expected
            let authorizationGeneration = ActionAuthorizationGeneration(
                credentialMutationEpoch: credentialMutationEpoch,
                connectionGeneration: expected
            )
            let activationTask = Task { await actionSink.activateAuthorizationLease(for: authorizationGeneration) }
            authorizationActivationTask = activationTask
            let authorization = await activationTask.value
            guard isAuthenticated(expected) else {
                await actionSink.revokeAuthorizationLease(authorization)
                throw CancellationError()
            }
            authorizationActivationTask = nil
            authenticatedActionAuthorization = authorization
            reconnectAttempt = 0
            setStatus(.connected)
            try await send(advertisedState, socket: socket, generation: expected, requireAuthentication: true)
            guard isAuthenticated(expected) else { throw CancellationError() }
            startHeartbeat(generation: expected, socket: socket)
            return
        }

        guard !message.isHelloOK else { throw WireError.messageNotAllowed }
        switch message {
        case .heartbeatAck(let ack):
            if ack.sequence == pendingHeartbeat {
                pendingHeartbeat = nil
                heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
            }
        case .actionRequest(let request):
            guard isAuthenticated(expected), let authorization = authenticatedActionAuthorization else {
                throw CancellationError()
            }
            let result = await actionSink.receive(request, via: .oci, authorization: authorization)
            guard isAuthenticated(expected) else { throw CancellationError() }
            resultHandler?(result)
            try await send(result, socket: socket, generation: expected, requireAuthentication: true)
        case .timeSyncRequest(let request):
            let received = wallClockMilliseconds()
            try await send(TimeSyncResponse(syncId: request.syncId,
                                            phoneSendUnixMs: request.phoneSendUnixMs,
                                            macReceiveUnixMs: received,
                                            macSendUnixMs: wallClockMilliseconds()),
                           socket: socket, generation: expected, requireAuthentication: true)
        case .diagnosticsRequest(let request):
            let counts = await diagnostics.diagnosticPostCounts()
            guard isAuthenticated(expected) else { throw CancellationError() }
            try await send(DiagnosticsCounters(requestId: request.requestId,
                                               mouseDownPostCount: counts.mouseDownPostCount,
                                               mouseUpPostCount: counts.mouseUpPostCount),
                           socket: socket, generation: expected, requireAuthentication: true)
        case .pairStatus, .pairCreated, .pairClaimedMac, .pairCompleted, .pairFailed:
            guard let pairingHandler else { return }
            await pairingHandler(message)
        case .phoneList, .phoneRevoked, .phoneRevokeFailed:
            guard let phoneManagementHandler else { return }
            await phoneManagementHandler(message)
        default:
            throw WireError.messageNotAllowed
        }
    }

    private func send<T: Encodable>(
        _ value: T,
        socket: any WebSocketTransport,
        generation expected: Int,
        requireAuthentication: Bool
    ) async throws {
        guard isCurrent(expected), !requireAuthentication || isAuthenticated(expected) else {
            throw CancellationError()
        }
        try await socket.sendText(Wire.encode(value))
        guard isCurrent(expected), !requireAuthentication || isAuthenticated(expected) else {
            throw CancellationError()
        }
    }

    private func startHeartbeat(generation expected: Int, socket: any WebSocketTransport) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.sleep(Constants.heartbeatInterval) } catch { return }
                guard await self.isAuthenticated(expected) else { return }
                await self.originateHeartbeat(generation: expected, socket: socket)
            }
        }
    }

    private func isCurrent(_ expected: Int) -> Bool { running && expected == generation }
    private func isAuthenticated(_ expected: Int) -> Bool {
        isCurrent(expected) && authenticatedGeneration == expected
    }

    private func originateHeartbeat(generation expected: Int, socket: any WebSocketTransport) async {
        guard isAuthenticated(expected) else { return }
        sequence += 1
        let sentSequence = sequence
        pendingHeartbeat = sentSequence
        do {
            try await send(HeartbeatRequest(sequence: sentSequence), socket: socket,
                           generation: expected, requireAuthentication: true)
        } catch {
            await generationFailed(expected, socket: socket)
            return
        }
        guard isAuthenticated(expected) else { return }
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(Constants.heartbeatTimeout) } catch { return }
            await self.heartbeatTimedOut(sentSequence, generation: expected, socket: socket)
        }
    }

    private func heartbeatTimedOut(
        _ expectedSequence: Int,
        generation expected: Int,
        socket: any WebSocketTransport
    ) async {
        guard isAuthenticated(expected), pendingHeartbeat == expectedSequence else { return }
        await generationFailed(expected, socket: socket)
    }

    private func authenticationRejected(_ expected: Int, socket: any WebSocketTransport) async {
        guard running, expected == generation, authenticatedGeneration != expected else { return }

        running = false
        generation += 1
        authenticatedGeneration = nil
        receiveTask?.cancel(); receiveTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
        pendingHeartbeat = nil
        transport = nil
        await socket.close()
        setStatus(.disconnected, cause: .authenticationRejected)
    }

    private func generationFailed(_ expected: Int, socket: any WebSocketTransport) async {
        guard running, expected == generation else { return }

        generation += 1
        let reconnectGeneration = generation
        let authorization = authenticatedActionAuthorization
        let activatingAuthorization = authorizationActivationTask
        authenticatedGeneration = nil
        authenticatedActionAuthorization = nil
        authorizationActivationTask = nil
        receiveTask?.cancel(); receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        heartbeatTimeoutTask?.cancel(); heartbeatTimeoutTask = nil
        pendingHeartbeat = nil
        transport = nil
        if let authorization { await actionSink.revokeAuthorizationLease(authorization) }
        if let activatingAuthorization {
            let activatingLease = await activatingAuthorization.value
            if activatingLease != authorization {
                await actionSink.revokeAuthorizationLease(activatingLease)
            }
        }
        await socket.close()

        guard running, generation == reconnectGeneration else { return }
        setStatus(.disconnected)
        reconnectAttempt += 1
        let ceiling = min(Constants.macReconnectCap, 0.5 * pow(2, Double(reconnectAttempt - 1)))
        let delay = jitter(ceiling)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            await self.resumeAfterBackoff(reconnectGeneration)
        }
    }

    private func resumeAfterBackoff(_ expected: Int) {
        guard running, expected == generation else { return }
        reconnectTask = nil
        openGeneration()
    }
}

extension RelayClient: PairingTransport {}
extension RelayClient: PhoneManagementTransport {}

private extension WireMessage {
    var isHelloOK: Bool { if case .helloOK = self { return true }; return false }
}

private func isPairingRequest(_ message: WireMessage) -> Bool {
    switch message {
    case .pairStatusRequest, .pairCreate, .pairCancel, .pairApprove, .pairDeny:
        true
    default:
        false
    }
}

private func isPhoneManagementRequest(_ message: WireMessage) -> Bool {
    switch message {
    case .phoneListRequest, .phoneRevokeRequest:
        true
    default:
        false
    }
}
