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
    func sentMessages() -> [String] { sent }
    func connections() -> Int { connectCount }
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
    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult {
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
        let request = ActionRequest(actionId: "id", action: "click",
                                    issuedAtUnixMs: 1_786_497_600_000,
                                    expiresAtUnixMs: 1_786_497_602_000)
        await transport.push(try Wire.encode(request))

        let delivered = await eventually { await sink.count() == 1 }
        XCTAssertTrue(delivered)
        let resultSent = await eventually {
            await transport.sentMessages().contains { text in
                guard case .actionResult(let result) = try? StrictWireDecoder().decodeText(text) else { return false }
                return result.actionId == "id" && result.reason == .remoteDisabled
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
        await transport.push(try Wire.encode(DiagnosticsRequest(requestId: "r")))
        let countersSent = await eventually {
            await transport.sentMessages().contains { text in
                guard case .diagnosticsCounters(let counters) = try? StrictWireDecoder().decodeText(text) else { return false }
                return counters.requestId == "r" && counters.mouseDownPostCount == 4 && counters.mouseUpPostCount == 3
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
}
