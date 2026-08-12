import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhoneRelayClientTests: XCTestCase {
    private let configuration = RelayConfiguration(
        url: URL(string: "wss://relay.example/ws")!,
        token: String(repeating: "a", count: 64)
    )

    private func makeSubject(
        factory: FakePhoneWebSocketFactory,
        scheduler: FakePhoneScheduler,
        randomUnit: @escaping @MainActor () -> Double = { 0.5 }
    ) -> PhoneRelayClient {
        PhoneRelayClient(
            socketFactory: factory,
            clock: FakePhoneClock(),
            scheduler: scheduler,
            randomUnit: randomUnit
        )
    }

    func testOpenSendsExactlyOnePhoneHelloAndAuthenticatesOnlyAfterHelloOK() throws {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)

        subject.connect(configuration: configuration)
        let socket = try XCTUnwrap(factory.sockets.first)
        XCTAssertFalse(subject.isAuthenticated)
        socket.emitOpen()

        XCTAssertEqual(socket.sentTexts.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(socket.sentTexts[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["role"] as? String, "phone")
        XCTAssertEqual(object["token"] as? String, configuration.token)
        XCTAssertFalse(subject.isAuthenticated)

        socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        XCTAssertTrue(subject.isAuthenticated)
        XCTAssertEqual(socket.sentTexts.count, 1)
    }

    func testPreauthenticationMessageDuplicateHelloAndInvalidFramesInvalidateGeneration() {
        let invalidFrames: [(FakePhoneWebSocket) -> Void] = [
            { $0.emitText(#"{"type":"state","v":1,"macOnline":true,"remoteEnabled":true,"permission":"ready"}"#) },
            { socket in
                socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
                socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
            },
            { $0.emitBinary(Data([1])) },
            { $0.emitText(#"{"type":"heartbeat.ack","v":1,"sequence":-1}"#) },
        ]

        for emit in invalidFrames {
            let factory = FakePhoneWebSocketFactory()
            let scheduler = FakePhoneScheduler()
            let subject = makeSubject(factory: factory, scheduler: scheduler)
            subject.connect(configuration: configuration)
            let generation = subject.generation
            let socket = factory.sockets[0]
            socket.emitOpen()
            emit(socket)
            XCTAssertGreaterThan(subject.generation, generation)
            XCTAssertFalse(subject.isAuthenticated)
            XCTAssertFalse(socket.closes.isEmpty)
        }
    }

    func testHeartbeatAckCancelsTimeoutAndSchedulesNextHeartbeat() throws {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)
        subject.connect(configuration: configuration)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)

        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.heartbeatInterval])
        scheduler.runFirst(after: PhoneProtocolV1.heartbeatInterval)
        let heartbeat = try XCTUnwrap(socket.sentTexts.last)
        XCTAssertTrue(heartbeat.contains(#""sequence":1"#))
        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.heartbeatTimeout])

        socket.emitText(#"{"type":"heartbeat.ack","v":1,"sequence":1}"#)
        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.heartbeatInterval])
    }

    func testHeartbeatTimeoutSchedulesFullJitterReconnectAtCalculatedCeiling() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 0.5 })
        subject.connect(configuration: configuration)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)

        scheduler.runFirst(after: PhoneProtocolV1.heartbeatInterval)
        scheduler.runFirst(after: PhoneProtocolV1.heartbeatTimeout)

        XCTAssertEqual(scheduler.entries.map(\.delay), [0.125])
        scheduler.runFirst(after: 0.125)
        XCTAssertEqual(factory.sockets.count, 2)
    }

    func testReconnectCeilingGrowsExponentiallyAndCapsAtEightSeconds() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 1 })
        subject.connect(configuration: configuration)

        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            let socket = factory.sockets.last!
            socket.emitOpen()
            socket.emitClose(FakePhoneWebSocketError.closed)
            let delay = scheduler.entries.last!.delay
            delays.append(delay)
            scheduler.runFirst(after: delay)
        }

        XCTAssertEqual(delays, [0.25, 0.5, 1, 2, 4, 8, 8])
    }

    func testPhoneTakenOverCloseDoesNotReconnectUntilExplicitConnect() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 0.5 })
        var events: [PhoneTransportEvent] = []
        subject.onEvent = { events.append($0) }
        subject.connect(configuration: configuration)

        factory.sockets[0].emitClose(code: PhoneProtocolV1.phoneTakenOverCloseCode)

        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(events.last, .connection(generation: subject.generation, state: .takenOver))

        subject.connect(configuration: configuration)

        XCTAssertEqual(factory.sockets.count, 2)
    }

    /// A takeover is reclaimable; a replaced credential is not. While both used
    /// close code 4004 the UI could not tell them apart, and offered the
    /// displaced-phone reclaim button to a phone whose credential was dead —
    /// a button that could only ever fail authentication.
    func testCredentialReplacedCloseIsTerminalAndDistinctFromTakeover() {
        XCTAssertNotEqual(PhoneProtocolV1.credentialReplacedCloseCode,
                          PhoneProtocolV1.phoneTakenOverCloseCode,
                          "the two terminal causes must be distinguishable on the wire")

        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 0.5 })
        var events: [PhoneTransportEvent] = []
        subject.onEvent = { events.append($0) }
        subject.connect(configuration: configuration)

        factory.sockets[0].emitClose(code: PhoneProtocolV1.credentialReplacedCloseCode)

        XCTAssertTrue(scheduler.entries.isEmpty, "a dead credential must not schedule a reconnect")
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(events.last,
                       .connection(generation: subject.generation, state: .credentialReplaced))
    }

    /// The reclaim affordance is gated on `phoneTakenOver`, so a replaced
    /// credential must not satisfy it.
    func testReplacedCredentialDoesNotOfferTheTakeoverReclaim() {
        var state = PhoneState()

        state.connection = .takenOver
        XCTAssertTrue(state.phoneTakenOver)
        XCTAssertEqual(state.primaryStatus, .anotherPhoneTookOver)

        state.connection = .credentialReplaced
        XCTAssertFalse(state.phoneTakenOver, "would render an impossible reclaim button")
        XCTAssertTrue(state.credentialReplaced)
        XCTAssertEqual(state.primaryStatus, .credentialReplaced)
    }

    func testAuthenticationRejectedCloseIsTerminalAndDistinctFromInternalBackoff() {
        let rejectedFactory = FakePhoneWebSocketFactory()
        let rejectedScheduler = FakePhoneScheduler()
        let rejected = makeSubject(factory: rejectedFactory, scheduler: rejectedScheduler)
        var rejectedEvents: [PhoneTransportEvent] = []
        rejected.onEvent = { rejectedEvents.append($0) }
        rejected.connect(configuration: configuration)

        rejectedFactory.sockets[0].emitClose(code: PhoneProtocolV1.authenticationRejectedCloseCode)

        XCTAssertTrue(rejectedScheduler.entries.isEmpty)
        XCTAssertEqual(rejectedEvents.last, .connection(
            generation: rejected.generation,
            state: .authenticationRejected
        ))

        let internalFactory = FakePhoneWebSocketFactory()
        let internalScheduler = FakePhoneScheduler()
        let internalError = makeSubject(factory: internalFactory, scheduler: internalScheduler)
        var internalEvents: [PhoneTransportEvent] = []
        internalError.onEvent = { internalEvents.append($0) }
        internalError.connect(configuration: configuration)

        internalFactory.sockets[0].emitClose(code: 1_011)

        XCTAssertFalse(internalScheduler.entries.isEmpty)
        XCTAssertEqual(internalEvents.last, .connection(
            generation: internalError.generation,
            state: .backoff
        ))
    }

    func testOrdinaryCloseStillSchedulesReconnect() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 0.5 })
        subject.connect(configuration: configuration)

        factory.sockets[0].emitClose(code: 1_006)

        XCTAssertEqual(scheduler.entries.map(\.delay), [0.125])
    }

    func testURLSessionReceiveFailureWaitsForDelegateSemanticClose() {
        let error = URLError(.networkConnectionLost)
        var arbiter = URLSessionPhoneWebSocketCloseArbiter()

        XCTAssertNil(arbiter.receiveFailure(error))
        XCTAssertEqual(
            arbiter.delegateClose(code: PhoneProtocolV1.phoneTakenOverCloseCode)?.code,
            PhoneProtocolV1.phoneTakenOverCloseCode
        )
        XCTAssertNil(arbiter.taskCompletion(error: error, closeCode: 0))
    }

    func testURLSessionTaskCompletionOwnsOrdinaryTransportFailure() throws {
        let error = URLError(.networkConnectionLost)
        var arbiter = URLSessionPhoneWebSocketCloseArbiter()

        let closure = try XCTUnwrap(
            arbiter.taskCompletion(error: error, closeCode: 0)
        )

        XCTAssertNil(closure.code)
        XCTAssertEqual((closure.error as? URLError)?.code, .networkConnectionLost)
    }

    func testOldSocketCallbacksCannotAffectNewGeneration() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)

        subject.connect(configuration: configuration)
        let old = factory.sockets[0]
        subject.connect(configuration: configuration)
        let currentGeneration = subject.generation
        let current = factory.sockets[1]

        old.emitOpen()
        old.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        old.emitClose()

        XCTAssertEqual(subject.generation, currentGeneration)
        XCTAssertFalse(subject.isAuthenticated)
        XCTAssertTrue(current.sentTexts.isEmpty)
        XCTAssertTrue(scheduler.entries.isEmpty)
    }

    func testSendUsesCurrentAuthenticatedSocketExactlyOnce() throws {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)
        let message = PhoneClientMessage.heartbeatRequest(HeartbeatRequest(sequence: 9))

        subject.connect(configuration: configuration)
        XCTAssertFalse(subject.send(message))
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        XCTAssertTrue(subject.send(message))
        XCTAssertEqual(socket.sentTexts.filter { $0.contains(#""sequence":9"#) }.count, 1)
    }

    func testDelayedSendFailureInvalidatesExactlyOneGenerationWithoutResendingAction() throws {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler, randomUnit: { 0.5 })
        let actionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let message = PhoneClientMessage.actionRequest(ActionRequest(
            actionID: actionID,
            action: "click",
            issuedAtUnixMilliseconds: 1_000,
            expiresAtUnixMilliseconds: 2_000
        ))

        subject.connect(configuration: configuration)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        socket.automaticallyCompletesSends = false
        let sendingGeneration = subject.generation

        XCTAssertTrue(subject.send(message))
        socket.completeNextSend(error: FakePhoneWebSocketError.sendFailed)

        XCTAssertEqual(subject.generation, sendingGeneration + 1)
        XCTAssertEqual(socket.closes.filter { $0.1 == "send_failed" }.count, 1)
        XCTAssertEqual(scheduler.entries.map(\.delay), [0.125])
        XCTAssertEqual(
            factory.sockets.flatMap(\.sentTexts).filter {
                $0.lowercased().contains(actionID.uuidString.lowercased())
            }.count,
            1
        )

        scheduler.runFirst(after: 0.125)
        XCTAssertEqual(factory.sockets.count, 2)
        XCTAssertEqual(
            factory.sockets.flatMap(\.sentTexts).filter {
                $0.lowercased().contains(actionID.uuidString.lowercased())
            }.count,
            1
        )
    }

    func testStaleSendFailureCannotAffectReplacementGeneration() throws {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)
        let message = PhoneClientMessage.heartbeatRequest(HeartbeatRequest(sequence: 9))

        subject.connect(configuration: configuration)
        let oldSocket = factory.sockets[0]
        oldSocket.emitOpen()
        oldSocket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        oldSocket.automaticallyCompletesSends = false
        XCTAssertTrue(subject.send(message))

        subject.connect(configuration: configuration)
        let currentSocket = factory.sockets[1]
        currentSocket.emitOpen()
        currentSocket.emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        let currentGeneration = subject.generation

        oldSocket.completeNextSend(error: FakePhoneWebSocketError.sendFailed)

        XCTAssertEqual(subject.generation, currentGeneration)
        XCTAssertTrue(subject.isAuthenticated)
        XCTAssertTrue(currentSocket.closes.isEmpty)
        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.heartbeatInterval])
    }

    func testConnectAndDisconnectCancelOldTimersAndAdvanceGeneration() {
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(factory: factory, scheduler: scheduler)
        subject.connect(configuration: configuration)
        let firstGeneration = subject.generation
        factory.sockets[0].emitOpen()
        factory.sockets[0].emitText(#"{"type":"hello.ok","v":1,"role":"phone"}"#)
        XCTAssertFalse(scheduler.entries.isEmpty)

        subject.disconnect(reason: "background")
        XCTAssertGreaterThan(subject.generation, firstGeneration)
        XCTAssertFalse(subject.isAuthenticated)
        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertEqual(factory.sockets[0].closes.last?.1, "background")
    }
}
