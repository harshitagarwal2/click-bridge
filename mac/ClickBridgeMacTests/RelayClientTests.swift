import XCTest
@testable import ClickBridgeMac

private enum FakeTransportError: Error { case closed }

private actor FakeWebSocketTransport: WebSocketTransport {
    private var inbound: [Result<String, Error>] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private(set) var sent: [String] = []
    private(set) var connectCount = 0
    private(set) var closeCount = 0

    func connect(to url: URL) async throws { connectCount += 1 }
    func sendText(_ text: String) async throws { sent.append(text) }
    func receiveText() async throws -> String {
        if !inbound.isEmpty { return try inbound.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func close() async {
        closeCount += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: FakeTransportError.closed) }
    }
    func push(_ text: String) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: text)
        } else {
            inbound.append(.success(text))
        }
    }
    func pushFailure(_ error: Error) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(throwing: error)
        } else {
            inbound.append(.failure(error))
        }
    }
    func sentMessages() -> [String] { sent }
    func connections() -> Int { connectCount }
    func closes() -> Int { closeCount }
}

private actor GatedCloseTransport: WebSocketTransport {
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var receiveContinuation: CheckedContinuation<String, Error>?
    private var pendingReceiveFailure = false
    private(set) var receiveStarted = false
    private(set) var closeStarted = false
    private(set) var sent: [String] = []

    func connect(to url: URL) async throws {}
    func sendText(_ text: String) async throws { sent.append(text) }
    func receiveText() async throws -> String {
        receiveStarted = true
        if pendingReceiveFailure {
            pendingReceiveFailure = false
            throw FakeTransportError.closed
        }
        return try await withCheckedThrowingContinuation { receiveContinuation = $0 }
    }
    func close() async {
        closeStarted = true
        await withCheckedContinuation { closeContinuation = $0 }
        receiveContinuation?.resume(throwing: FakeTransportError.closed)
        receiveContinuation = nil
    }
    func releaseClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }
    func failReceive() {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(throwing: FakeTransportError.closed)
        } else {
            pendingReceiveFailure = true
        }
    }
    func didStartClose() -> Bool { closeStarted }
    func didStartReceive() -> Bool { receiveStarted }
    func sentMessages() -> [String] { sent }
}

private final class TransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any WebSocketTransport]
    private var makeCount = 0
    init(_ transports: [any WebSocketTransport]) { self.transports = transports }
    func make() -> any WebSocketTransport {
        lock.lock(); defer { lock.unlock() }
        makeCount += 1
        return transports.removeFirst()
    }
    func count() -> Int { lock.withLock { makeCount } }
}

private actor GatedSink: ActionRequestSink {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var activeLease: ActionAuthorizationLease?
    func activateAuthorizationLease(for generation: ActionAuthorizationGeneration) -> ActionAuthorizationLease {
        let lease = ActionAuthorizationLease(generation: generation)
        activeLease = lease
        return lease
    }
    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) {
        if activeLease == lease { activeLease = nil }
    }
    func receive(_ request: ActionRequest, via ingress: ActionIngress,
                 authorization: ActionAuthorizationLease) async -> ActionResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ActionResult(actionId: request.actionId, status: .rejected, reason: .remoteDisabled,
                            acceptedVia: ingress, macProcessingUs: 1, mouseDownPostedUnixMs: nil)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class CountingPoster: InputPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        lock.withLock { count += 1 }
        return .posted(mouseDownUnixMs: 1_786_497_600_010)
    }

    func diagnosticPostCounts() -> InputPostCounts {
        lock.withLock { InputPostCounts(mouseDownPostCount: count, mouseUpPostCount: count) }
    }

    func postCount() -> Int { lock.withLock { count } }
}

private final class RelayBlockingPoster: InputPosting, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        started.signal()
        release.wait()
        lock.withLock { count += 1 }
        return .posted(mouseDownUnixMs: 1_786_497_600_010)
    }

    func diagnosticPostCounts() -> InputPostCounts {
        lock.withLock { InputPostCounts(mouseDownPostCount: count, mouseUpPostCount: count) }
    }

    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 1) == .success }
    func unblock() { release.signal() }
    func postCount() -> Int { lock.withLock { count } }
}

private struct GrantedPermission: PostEventPermissionChecking {
    func isGranted() -> Bool { true }
}

private actor ForwardingGatedSink: ActionRequestSink {
    private let processor: ActionProcessor
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private(set) var results: [ActionResult] = []

    init(processor: ActionProcessor) { self.processor = processor }

    func activateAuthorizationLease(
        for generation: ActionAuthorizationGeneration
    ) async -> ActionAuthorizationLease {
        await processor.activateAuthorizationLease(for: generation)
    }

    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) async {
        await processor.revokeAuthorizationLease(lease)
    }

    func receive(_ request: ActionRequest, via ingress: ActionIngress,
                 authorization: ActionAuthorizationLease) async -> ActionResult {
        started = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        let result = await processor.receive(request, via: ingress, authorization: authorization)
        results.append(result)
        return result
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ManualSleeper {
    private struct Waiter { let seconds: TimeInterval; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [UUID: Waiter] = [:]

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(seconds: seconds, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeOne(_ seconds: TimeInterval) {
        guard let match = waiters.first(where: { $0.value.seconds == seconds }) else { return }
        waiters.removeValue(forKey: match.key)?.continuation.resume()
    }

    func count(_ seconds: TimeInterval) -> Int { waiters.values.filter { $0.seconds == seconds }.count }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor RecordingSink: ActionRequestSink {
    private(set) var requests: [(ActionRequest, ActionIngress)] = []
    private var activeLease: ActionAuthorizationLease?
    func activateAuthorizationLease(for generation: ActionAuthorizationGeneration) -> ActionAuthorizationLease {
        let lease = ActionAuthorizationLease(generation: generation)
        activeLease = lease
        return lease
    }
    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) {
        if activeLease == lease { activeLease = nil }
    }
    func receive(_ request: ActionRequest, via ingress: ActionIngress,
                 authorization: ActionAuthorizationLease) async -> ActionResult {
        requests.append((request, ingress))
        return ActionResult(actionId: request.actionId, status: .rejected, reason: .remoteDisabled,
                            acceptedVia: ingress, macProcessingUs: 1, mouseDownPostedUnixMs: nil)
    }
    func count() -> Int { requests.count }
}

private struct FixedCounters: DiagnosticCounterReading {
    let value: InputPostCounts
    func diagnosticPostCounts() async -> InputPostCounts { value }
}

final class RelayClientTests: XCTestCase {
    private let actionID = "018f63f5-6f3d-7d21-88bc-9ef561f030de"
    private let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030ab"
    private func eventually(
        timeout: TimeInterval = 1,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testRelayURLValidationRejectsPublicPlaintextAndAllowsExplicitLoopback() throws {
        XCTAssertThrowsError(try RelayEndpoint.validated("ws://example.com/ws", allowLocalSimulator: true))
        XCTAssertThrowsError(try RelayEndpoint.validated("wss://example.com/other", allowLocalSimulator: false))
        XCTAssertThrowsError(try RelayEndpoint.validated("wss://u:p@example.com/ws", allowLocalSimulator: false))
        XCTAssertEqual(try RelayEndpoint.validated("wss://example.com/ws", allowLocalSimulator: false).absoluteString,
                       "wss://example.com/ws")
        XCTAssertEqual(try RelayEndpoint.validated("ws://127.0.0.1/ws", allowLocalSimulator: true).absoluteString,
                       "ws://127.0.0.1/ws")
        XCTAssertThrowsError(try RelayEndpoint.validated("ws://127.0.0.1/ws", allowLocalSimulator: false))
    }

    func testIncomingActionReachesInjectedSinkAndResultIsSent() async throws {
        let transport = FakeWebSocketTransport()
        let sink = RecordingSink()
        let client = RelayClient(
            actionSink: sink,
            diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 },
            wallClockMilliseconds: { 1_786_497_600_031 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let request = ActionRequest(actionId: actionID, action: "click",
                                    issuedAtUnixMs: 1_786_497_600_000,
                                    expiresAtUnixMs: 1_786_497_602_000)
        await transport.push(try Wire.encode(request))

        let delivered = await eventually { await sink.count() == 1 }
        XCTAssertTrue(delivered)
        let resultSent = await eventually {
            await transport.sentMessages().contains { text in
                guard case .actionResult(let result) = try? StrictWireDecoder().decodeText(text) else { return false }
                return result.actionId == self.actionID && result.reason == .remoteDisabled
            }
        }
        XCTAssertTrue(resultSent)
        await client.stop()
    }

    func testConnectedOnlyAfterHelloOKAndPublishesCachedSnapshot() async throws {
        let transport = FakeWebSocketTransport()
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        await client.updateAdvertisedState(MacState(remoteEnabled: false, permission: .required))
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        let beforeHello = await client.currentStatus()
        XCTAssertNotEqual(beforeHello, .connected)
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let connected = await eventually { await client.currentStatus() == .connected }
        XCTAssertTrue(connected)
        let stateSent = await eventually {
            await transport.sentMessages().contains { text in
                guard case .macState(let state) = try? StrictWireDecoder().decodeText(text) else { return false }
                return state == MacState(remoteEnabled: false, permission: .required)
            }
        }
        XCTAssertTrue(stateSent)
        await client.stop()
    }

    func testDiagnosticsRequestReturnsInjectedSnapshot() async throws {
        let transport = FakeWebSocketTransport()
        let client = RelayClient(
            actionSink: RecordingSink(),
            diagnostics: FixedCounters(value: InputPostCounts(mouseDownPostCount: 4, mouseUpPostCount: 3)),
            makeTransport: { transport }, sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        await transport.push(try Wire.encode(DiagnosticsRequest(requestId: requestID)))
        let countersSent = await eventually {
            await transport.sentMessages().contains { text in
                guard case .diagnosticsCounters(let counters) = try? StrictWireDecoder().decodeText(text) else { return false }
                return counters.requestId == self.requestID && counters.mouseDownPostCount == 4 && counters.mouseUpPostCount == 3
            }
        }
        XCTAssertTrue(countersSent)
        await client.stop()
    }

    func testDisconnectedClientDoesNotOriginateHeartbeat() async throws {
        let transport = FakeWebSocketTransport()
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { _ in }, jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try? await Task.sleep(for: .milliseconds(30))
        let sent = await transport.sentMessages()
        let status = await client.currentStatus()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(status, .disconnected)
    }

    func testOneHeartbeatOwnerAckCancelsTimeoutAndMissReconnects() async throws {
        let transport = FakeWebSocketTransport()
        let sleeper = ManualSleeper()
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { try await sleeper.sleep($0) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let initialOwner = await eventually { await sleeper.count(Constants.heartbeatInterval) == 1 }
        XCTAssertTrue(initialOwner)

        await sleeper.resumeOne(Constants.heartbeatInterval)
        let heartbeatSent = await eventually {
            await transport.sentMessages().contains {
                guard case .heartbeatRequest(let heartbeat) = try? StrictWireDecoder().decodeText($0) else { return false }
                return heartbeat.sequence == 1
            }
        }
        XCTAssertTrue(heartbeatSent)
        await transport.push(try Wire.encode(HeartbeatAck(sequence: 1)))
        let timeoutCancelled = await eventually { await sleeper.count(Constants.heartbeatTimeout) == 0 }
        XCTAssertTrue(timeoutCancelled)

        await sleeper.resumeOne(Constants.heartbeatInterval)
        let timeoutScheduled = await eventually { await sleeper.count(Constants.heartbeatTimeout) == 1 }
        XCTAssertTrue(timeoutScheduled)
        await sleeper.resumeOne(Constants.heartbeatTimeout)
        let reconnectScheduled = await eventually { await sleeper.count(0) == 1 }
        XCTAssertTrue(reconnectScheduled)
        await sleeper.resumeOne(0)
        let reconnected = await eventually { await transport.connections() == 2 }
        XCTAssertTrue(reconnected)
        await client.stop()
    }

    func testPreAuthenticationActionClosesGenerationWithoutDelivery() async throws {
        let transport = FakeWebSocketTransport()
        let sink = RecordingSink()
        let sleeper = ManualSleeper()
        let client = RelayClient(
            actionSink: sink, diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { try await sleeper.sleep($0) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(ActionRequest(actionId: actionID, action: "click",
                                                           issuedAtUnixMs: 1_786_497_600_000,
                                                           expiresAtUnixMs: 1_786_497_602_000)))
        let closed = await eventually { await transport.closes() == 1 }
        XCTAssertTrue(closed)
        let delivered = await sink.count()
        let status = await client.currentStatus()
        XCTAssertEqual(delivered, 0)
        XCTAssertNotEqual(status, .connected)
        await client.stop()
    }

    func testOversizedAuthenticatedFrameClosesAndSchedulesReconnect() async throws {
        let transport = FakeWebSocketTransport()
        let sleeper = ManualSleeper()
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { try await sleeper.sleep($0) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        await transport.push(String(repeating: "x", count: 4_097))
        let closed = await eventually { await transport.closes() == 1 }
        let scheduled = await eventually { await sleeper.count(0) == 1 }
        XCTAssertTrue(closed)
        XCTAssertTrue(scheduled)
        await client.stop()
    }

    func testBinaryTransportFailureClosesAndSchedulesReconnect() async throws {
        let transport = FakeWebSocketTransport()
        let sleeper = ManualSleeper()
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { try await sleeper.sleep($0) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        await transport.pushFailure(WebSocketTransportError.binaryFrame)
        let closed = await eventually { await transport.closes() == 1 }
        let scheduled = await eventually { await sleeper.count(0) == 1 }
        XCTAssertTrue(closed)
        XCTAssertTrue(scheduled)
        await client.stop()
    }

    func testReconnectPublishesCachedSnapshotOnlyOnReplacementSocket() async throws {
        let first = FakeWebSocketTransport()
        let second = FakeWebSocketTransport()
        let factory = TransportFactory([first, second])
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { factory.make() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        let snapshot = MacState(remoteEnabled: true, permission: .ready)
        await client.updateAdvertisedState(snapshot)
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await first.push(try Wire.encode(HelloOK(role: "mac")))
        let firstPublished = await eventually { await first.contains(snapshot) }
        XCTAssertTrue(firstPublished)

        await client.reconnect()
        await second.push(try Wire.encode(HelloOK(role: "mac")))
        let secondPublished = await eventually { await second.contains(snapshot) }
        XCTAssertTrue(secondPublished)
        let firstCount = await first.count(of: snapshot)
        XCTAssertEqual(firstCount, 1)
        await client.stop()
    }

    func testStaleActionCompletionCannotSendThroughOldOrReplacementSocket() async throws {
        let first = FakeWebSocketTransport()
        let second = FakeWebSocketTransport()
        let factory = TransportFactory([first, second])
        let sink = GatedSink()
        let client = RelayClient(
            actionSink: sink, diagnostics: FixedCounters(value: .zero),
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await first.push(try Wire.encode(HelloOK(role: "mac")))
        await first.push(try Wire.encode(ActionRequest(actionId: actionID, action: "click",
                                                       issuedAtUnixMs: 1_786_497_600_000,
                                                       expiresAtUnixMs: 1_786_497_602_000)))
        let started = await eventually { await sink.started }
        XCTAssertTrue(started)

        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await second.push(try Wire.encode(HelloOK(role: "mac")))
        await sink.release()
        try? await Task.sleep(for: .milliseconds(50))

        let firstResults = await first.sentMessages().filter { (try? StrictWireDecoder().decodeText($0))?.isActionResult == true }
        let secondResults = await second.sentMessages().filter { (try? StrictWireDecoder().decodeText($0))?.isActionResult == true }
        XCTAssertTrue(firstResults.isEmpty)
        XCTAssertTrue(secondResults.isEmpty)
        await client.stop()
    }

    func testClearConfigurationStopsAuthenticatedConnectionAndRequiresReconfiguration() async throws {
        let first = FakeWebSocketTransport()
        let second = FakeWebSocketTransport()
        let factory = TransportFactory([first, second])
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await first.push(try Wire.encode(HelloOK(role: "mac")))
        let connected = await eventually { await client.currentStatus() == .connected }
        XCTAssertTrue(connected)

        await client.clearConfigurationAndStop()

        let closeCount = await first.closes()
        let clearedStatus = await client.currentStatus()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(clearedStatus, .disconnected)
        await client.reconnect()
        await client.start()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(factory.count(), 1)

        try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                   allowLocalSimulator: false)
        await client.start()
        let reconfigured = await eventually { await second.connections() == 1 }
        XCTAssertTrue(reconfigured)
        await client.stop()
    }

    func testClearConfigurationPreventsStaleActionCompletionFromSending() async throws {
        let transport = FakeWebSocketTransport()
        let sink = GatedSink()
        let client = RelayClient(
            actionSink: sink, diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        await transport.push(try Wire.encode(ActionRequest(actionId: actionID, action: "click",
                                                           issuedAtUnixMs: 1_786_497_600_000,
                                                           expiresAtUnixMs: 1_786_497_602_000)))
        let started = await eventually { await sink.started }
        XCTAssertTrue(started)

        await client.clearConfigurationAndStop()
        await sink.release()
        try? await Task.sleep(for: .milliseconds(50))

        let results = await transport.sentMessages().filter {
            (try? StrictWireDecoder().decodeText($0))?.isActionResult == true
        }
        let closeCount = await transport.closes()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(closeCount, 1)
    }

    func testClearRevokesForwardedActionBeforePostAndNewGenerationCanPost() async throws {
        let oldTransport = FakeWebSocketTransport()
        let newTransport = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, newTransport])
        let poster = CountingPoster()
        let processor = ActionProcessor(
            poster: poster,
            permission: GrantedPermission(),
            nowMilliseconds: { 1_786_497_600_031 }
        )
        await processor.setRemoteEnabled(true)
        let sink = ForwardingGatedSink(processor: processor)
        let client = RelayClient(
            actionSink: sink,
            diagnostics: processor,
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 },
            wallClockMilliseconds: { 1_786_497_600_031 }
        )
        let oldRequest = ActionRequest(actionId: actionID, action: "click",
                                       issuedAtUnixMs: 1_786_497_600_000,
                                       expiresAtUnixMs: 1_786_497_602_000)

        try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)
        await oldTransport.push(try Wire.encode(HelloOK(role: "mac")))
        await oldTransport.push(try Wire.encode(oldRequest))
        guard await eventually({ await sink.started }) else {
            await sink.release()
            return XCTFail("old-generation action was not forwarded to the sink")
        }

        let cleared = await client.clearConfigurationAndStop(credentialRevision: 2)
        XCTAssertTrue(cleared)
        await sink.release()
        guard await eventually({ await sink.results.count == 1 }) else {
            return XCTFail("forwarded action did not complete after the gate opened")
        }
        let staleResult = await sink.results[0]
        XCTAssertEqual(staleResult.status, .rejected)
        XCTAssertEqual(poster.postCount(), 0)

        try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                   allowLocalSimulator: false, credentialRevision: 3)
        await client.start(credentialRevision: 3)
        await newTransport.push(try Wire.encode(HelloOK(role: "mac")))
        let newRequest = ActionRequest(actionId: requestID, action: "click",
                                       issuedAtUnixMs: 1_786_497_600_000,
                                       expiresAtUnixMs: 1_786_497_602_000)
        await newTransport.push(try Wire.encode(newRequest))
        let newGenerationPosted = await eventually { poster.postCount() == 1 }
        XCTAssertTrue(newGenerationPosted)
        await client.stop(credentialRevision: 4)
    }

    func testClearWaitsForAdmittedPostAndNoPostOccursAfterClearReturns() async throws {
        let transport = FakeWebSocketTransport()
        let poster = RelayBlockingPoster()
        let processor = ActionProcessor(
            poster: poster,
            permission: GrantedPermission(),
            nowMilliseconds: { 1_786_497_600_031 }
        )
        await processor.setRemoteEnabled(true)
        let client = RelayClient(
            actionSink: processor,
            diagnostics: processor,
            makeTransport: { transport },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 },
            wallClockMilliseconds: { 1_786_497_600_031 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        let connected = await eventually { await client.currentStatus() == .connected }
        XCTAssertTrue(connected)
        await transport.push(try Wire.encode(ActionRequest(actionId: actionID, action: "click",
                                                           issuedAtUnixMs: 1_786_497_600_000,
                                                           expiresAtUnixMs: 1_786_497_602_000)))
        XCTAssertTrue(poster.waitUntilStarted())

        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let clearing = Task {
            clearStarted.signal()
            let result = await client.clearConfigurationAndStop(credentialRevision: 2)
            clearFinished.signal()
            return result
        }
        XCTAssertEqual(clearStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.1), .timedOut)
        poster.unblock()

        let cleared = await clearing.value
        XCTAssertTrue(cleared)
        XCTAssertEqual(poster.postCount(), 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(poster.postCount(), 1)
    }

    func testClearSupersedesConfigureSuspendedWhileClosingOldTransport() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "initial-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let configuring = Task {
            try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                       allowLocalSimulator: false, credentialRevision: 2)
            await client.start(credentialRevision: 2)
        }
        let closeSuspended = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeSuspended)
        await client.clearConfigurationAndStop(credentialRevision: 3)
        await oldTransport.releaseClose()
        _ = try? await configuring.value

        XCTAssertEqual(factory.count(), 1)
        let clearedStatus = await client.currentStatus()
        XCTAssertEqual(clearedStatus, .disconnected)
        let replacementMessages = await replacement.sentMessages()
        XCTAssertTrue(replacementMessages.isEmpty)
        await client.start(credentialRevision: 2)
        XCTAssertEqual(factory.count(), 1)

        try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                   allowLocalSimulator: false, credentialRevision: 4)
        await client.start(credentialRevision: 4)
        let explicitlyRestarted = await eventually { await replacement.connections() == 1 }
        XCTAssertTrue(explicitlyRestarted)
        await client.stop()
    }

    func testEqualRevisionClearSupersedesConfigureSuspendedWhileClosing() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "initial-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let configuring = Task {
            let configured = try await client.configure(urlString: "wss://example.com/ws", token: "stale-token",
                                                        allowLocalSimulator: false, credentialRevision: 2)
            if configured { await client.start(credentialRevision: 2) }
            return configured
        }
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let cleared = await client.clearConfigurationAndStop(credentialRevision: 2)
        await oldTransport.releaseClose()
        let configured = try await configuring.value

        let replacementMessages = await replacement.sentMessages()
        let status = await client.currentStatus()
        XCTAssertTrue(cleared)
        XCTAssertFalse(configured)
        XCTAssertEqual(factory.count(), 1)
        XCTAssertTrue(replacementMessages.isEmpty)
        XCTAssertEqual(status, .disconnected)
        await client.start(credentialRevision: 2)
        XCTAssertEqual(factory.count(), 1)
    }

    func testEqualRevisionConfigureSupersedesStopSuspendedWhileClosing() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let stopping = Task { await client.stop(credentialRevision: 2) }
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let configured = try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                                    allowLocalSimulator: false, credentialRevision: 2)
        XCTAssertTrue(configured)
        await client.start(credentialRevision: 2)
        await oldTransport.releaseClose()
        let stopped = await stopping.value

        let helloSent = await eventually { await replacement.containsHello(token: "new-token") }
        let status = await client.currentStatus()
        XCTAssertFalse(stopped)
        XCTAssertTrue(helloSent)
        XCTAssertEqual(factory.count(), 2)
        XCTAssertEqual(status, .connecting)
        await client.stop()
    }

    func testNewerConfigureSupersedesStopSuspendedWhileClosingOldTransport() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { factory.make() },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { 0 }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let stopping = Task { await client.stop(credentialRevision: 2) }
        let closeSuspended = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeSuspended)
        let configured = try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                                    allowLocalSimulator: false, credentialRevision: 3)
        XCTAssertTrue(configured)
        await client.start(credentialRevision: 3)
        await oldTransport.releaseClose()
        _ = await stopping.value

        let status = await client.currentStatus()
        XCTAssertEqual(status, .connecting)
        XCTAssertEqual(factory.count(), 2)
        let newHelloSent = await eventually { await replacement.containsHello(token: "new-token") }
        XCTAssertTrue(newHelloSent)
        await client.stop()
    }

    func testNewerConfigureSupersedesReconnectSuspendedWhileClosingOldTransport() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let reconnecting = Task { await client.reconnect(credentialRevision: 2) }
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let configured = try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                                    allowLocalSimulator: false, credentialRevision: 3)
        XCTAssertTrue(configured)
        await client.start(credentialRevision: 3)
        await oldTransport.releaseClose()
        let reconnected = await reconnecting.value
        XCTAssertFalse(reconnected)

        XCTAssertEqual(factory.count(), 2)
        let helloSent = await eventually { await replacement.containsHello(token: "new-token") }
        let status = await client.currentStatus()
        XCTAssertTrue(helloSent)
        XCTAssertEqual(status, .connecting)
        await client.stop()
    }

    func testNewerConfigureSupersedesConfigureSuspendedWhileClosingOldTransport() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "initial-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let older = Task {
            try await client.configure(urlString: "wss://example.com/ws", token: "stale-token",
                                       allowLocalSimulator: false, credentialRevision: 2)
        }
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)
        let configured = try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                                    allowLocalSimulator: false, credentialRevision: 3)
        XCTAssertTrue(configured)
        await client.start(credentialRevision: 3)
        await oldTransport.releaseClose()
        let olderConfigured = try await older.value
        XCTAssertFalse(olderConfigured)

        XCTAssertEqual(factory.count(), 2)
        let helloSent = await eventually { await replacement.containsHello(token: "new-token") }
        XCTAssertTrue(helloSent)
        await client.stop()
    }

    func testNewerInvalidConfigureRevokesAndSupersedesSuspendedConfigure() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "initial-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)

        let older = Task {
            try await client.configure(urlString: "wss://example.com/ws", token: "stale-token",
                                       allowLocalSimulator: false, credentialRevision: 2)
        }
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)
        do {
            _ = try await client.configure(urlString: "https://example.com/ws", token: "invalid-token",
                                           allowLocalSimulator: false, credentialRevision: 3)
            XCTFail("Expected invalid relay URL")
        } catch RelayEndpointError.invalidScheme {}
        await oldTransport.releaseClose()
        let olderConfigured = try await older.value
        XCTAssertFalse(olderConfigured)

        XCTAssertEqual(factory.count(), 1)
        let replacementMessages = await replacement.sentMessages()
        let status = await client.currentStatus()
        XCTAssertTrue(replacementMessages.isEmpty)
        XCTAssertEqual(status, .disconnected)
    }

    func testNewConfigurationSupersedesGenerationFailureSuspendedWhileClosing() async throws {
        let oldTransport = GatedCloseTransport()
        let replacement = FakeWebSocketTransport()
        let factory = TransportFactory([oldTransport, replacement])
        let client = RelayClient(actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
                                 makeTransport: { factory.make() })
        try await client.configure(urlString: "wss://example.com/ws", token: "old-token",
                                   allowLocalSimulator: false, credentialRevision: 1)
        await client.start(credentialRevision: 1)
        let receiveStarted = await eventually { await oldTransport.didStartReceive() }
        XCTAssertTrue(receiveStarted)
        await oldTransport.failReceive()
        let closeStarted = await eventually { await oldTransport.didStartClose() }
        XCTAssertTrue(closeStarted)

        let configured = try await client.configure(urlString: "wss://example.com/ws", token: "new-token",
                                                    allowLocalSimulator: false, credentialRevision: 2)
        XCTAssertTrue(configured)
        await client.start(credentialRevision: 2)
        await oldTransport.releaseClose()

        XCTAssertEqual(factory.count(), 2)
        let helloSent = await eventually { await replacement.containsHello(token: "new-token") }
        let status = await client.currentStatus()
        XCTAssertTrue(helloSent)
        XCTAssertEqual(status, .connecting)
        await client.stop()
    }

    func testTimeSyncUsesReceiptAndSendSamples() async throws {
        let transport = FakeWebSocketTransport()
        let values = LockedMilliseconds([100, 125])
        let client = RelayClient(
            actionSink: RecordingSink(), diagnostics: FixedCounters(value: .zero),
            makeTransport: { transport }, sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { _ in 0 }, wallClockMilliseconds: { values.next() }
        )
        try await client.configure(urlString: "wss://example.com/ws", token: "token", allowLocalSimulator: false)
        await client.start()
        await transport.push(try Wire.encode(HelloOK(role: "mac")))
        await transport.push(try Wire.encode(TimeSyncRequest(syncId: requestID, phoneSendUnixMs: 50)))
        let response = await eventually {
            await transport.sentMessages().contains {
                guard case .timeSyncResponse(let sync) = try? StrictWireDecoder().decodeText($0) else { return false }
                return sync.macReceiveUnixMs == 100 && sync.macSendUnixMs == 125
            }
        }
        XCTAssertTrue(response)
        await client.stop()
    }
}

private final class LockedMilliseconds: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    init(_ values: [Double]) { self.values = values }
    func next() -> Double { lock.withLock { values.removeFirst() } }
}

private extension WireMessage {
    var isActionResult: Bool { if case .actionResult = self { return true }; return false }
}

private extension FakeWebSocketTransport {
    func containsHello(token: String) -> Bool {
        sent.contains { (try? JSONDecoder().decode(Hello.self, from: Data($0.utf8)))?.token == token }
    }
    func contains(_ snapshot: MacState) -> Bool { count(of: snapshot) > 0 }
    func count(of snapshot: MacState) -> Int {
        sent.compactMap { text -> MacState? in
            guard case .macState(let state) = try? StrictWireDecoder().decodeText(text) else { return nil }
            return state
        }.filter { $0 == snapshot }.count
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
