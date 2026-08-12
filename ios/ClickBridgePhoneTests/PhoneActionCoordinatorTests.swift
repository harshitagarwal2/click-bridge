import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhoneActionCoordinatorTests: XCTestCase {
    private let firstID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!
    private let secondID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030df")!
    private var transport: FakePhoneActionTransport!
    private var clock: FakePhoneClock!
    private var scheduler: FakePhoneScheduler!
    private var haptics: FakePhoneHaptics!
    private var phases: [PhoneActionPhase]!

    override func setUp() {
        transport = FakePhoneActionTransport()
        transport.generation = 9
        transport.isAuthenticated = true
        clock = FakePhoneClock(unixMilliseconds: 1_786_579_200_000, monotonicMilliseconds: 500)
        scheduler = FakePhoneScheduler()
        haptics = FakePhoneHaptics()
        phases = []
    }

    private var ready: ActionGateSnapshot {
        ActionGateSnapshot(
            foregroundGeneration: 4,
            socketGeneration: 9,
            transportAuthenticated: true,
            mac: MacReadiness(online: true, remoteEnabled: true, permission: .ready),
            clock: ClockHealth(status: .healthy, offsetMilliseconds: 0, uncertaintyMilliseconds: 5)
        )
    }

    private func delta(_ previous: Float = 0.5, _ current: Float = 0.56, generation: Int = 4) -> ObservedVolumeDelta {
        ObservedVolumeDelta(
            previous: previous,
            current: current,
            direction: current > previous ? .up : .down,
            foregroundGeneration: generation
        )
    }

    private func makeSubject(ids: [UUID]? = nil) -> PhoneActionCoordinator {
        var actionIDs = ids ?? [firstID]
        return PhoneActionCoordinator(
            transport: transport,
            clock: clock,
            scheduler: scheduler,
            haptics: haptics,
            makeActionID: { actionIDs.removeFirst() },
            onPhase: { [weak self] in self?.phases.append($0) }
        )
    }

    func testExactlyOneActionIDPerAcceptedDeltaAndNoQueueWhilePending() {
        let subject = makeSubject(ids: [firstID, secondID])

        XCTAssertEqual(subject.accept(delta(), readiness: ready), .sent(actionID: firstID))
        XCTAssertEqual(subject.accept(delta(0.56, 0.62), readiness: ready), .ignoredPending)
        XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), [firstID])

        XCTAssertTrue(subject.handle(.actionResult(posted(firstID)), socketGeneration: 9))
        XCTAssertEqual(subject.accept(delta(0.62, 0.56), readiness: ready), .sent(actionID: secondID))
        XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), [firstID, secondID])
    }

    func testGenericClickUsesSameReadinessAndPendingGateAsVolumeClick() {
        let subject = makeSubject(ids: [firstID, secondID])

        XCTAssertEqual(subject.accept(readiness: ready), .sent(actionID: firstID))
        XCTAssertEqual(subject.accept(readiness: ready), .ignoredPending)
        XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), [firstID])

        XCTAssertTrue(subject.handle(.actionResult(posted(firstID)), socketGeneration: 9))
        XCTAssertEqual(subject.accept(delta(), readiness: ready), .sent(actionID: secondID))
        XCTAssertEqual(transport.sentMessages.compactMap(\.actionID), [firstID, secondID])
    }

    func testGenericClickRejectsClosedReadinessWithoutSending() {
        let subject = makeSubject()
        let notAuthenticated = ActionGateSnapshot(
            foregroundGeneration: 4,
            socketGeneration: 9,
            transportAuthenticated: false,
            mac: ready.mac,
            clock: ready.clock
        )

        XCTAssertFalse(subject.canAccept(readiness: notAuthenticated))
        XCTAssertEqual(subject.accept(readiness: notAuthenticated), .ignoredNotReady)
        XCTAssertTrue(transport.sentMessages.isEmpty)
    }

    func testRequestUsesInjectedWallClockAndExactTwoSecondExpiry() {
        let subject = makeSubject()
        XCTAssertEqual(subject.accept(delta(), readiness: ready), .sent(actionID: firstID))
        guard case .actionRequest(let request) = transport.sentMessages.first else { return XCTFail() }

        XCTAssertEqual(request.actionID, firstID)
        XCTAssertEqual(request.issuedAtUnixMilliseconds, 1_786_579_200_000)
        XCTAssertEqual(request.expiresAtUnixMilliseconds, 1_786_579_202_000)
        XCTAssertEqual(transport.sentMessages.count, 1)
    }

    func testEveryReadinessGateIsClosedIndependently() {
        let subject = makeSubject(ids: Array(repeating: firstID, count: 8))
        let closed: [ActionGateSnapshot] = [
            .init(foregroundGeneration: nil, socketGeneration: 9, transportAuthenticated: true,
                  mac: ready.mac, clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 8, transportAuthenticated: true,
                  mac: ready.mac, clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 9, transportAuthenticated: false,
                  mac: ready.mac, clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 9, transportAuthenticated: true,
                  mac: MacReadiness(online: false, remoteEnabled: true, permission: .ready), clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 9, transportAuthenticated: true,
                  mac: MacReadiness(online: true, remoteEnabled: false, permission: .ready), clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 9, transportAuthenticated: true,
                  mac: MacReadiness(online: true, remoteEnabled: true, permission: .required), clock: ready.clock),
            .init(foregroundGeneration: 4, socketGeneration: 9, transportAuthenticated: true,
                  mac: ready.mac, clock: ClockHealth(status: .mismatch, offsetMilliseconds: 2_000,
                                                     uncertaintyMilliseconds: 1)),
        ]

        for snapshot in closed {
            XCTAssertEqual(subject.accept(delta(), readiness: snapshot), .ignoredNotReady)
        }
        XCTAssertEqual(subject.accept(delta(generation: 3), readiness: ready), .ignoredNotReady)
        XCTAssertTrue(transport.sentMessages.isEmpty)
    }

    func testSendFailureSettlesWithoutReplacementID() {
        transport.sendResult = false
        let subject = makeSubject(ids: [firstID, secondID])

        XCTAssertEqual(subject.accept(delta(), readiness: ready), .sendFailed)
        XCTAssertFalse(subject.hasPendingAction)
        XCTAssertEqual(transport.sendAttempts.compactMap(\.actionID), [firstID])
        XCTAssertTrue(transport.sentMessages.isEmpty)
        XCTAssertTrue(haptics.terminalResults.isEmpty)
    }

    func testForwardedAckIsNonterminalAndDoesNotHaptic() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)
        let ack = RelayAck(actionID: firstID, status: .forwarded, reason: .ok, relayProcessingMicroseconds: 1)

        XCTAssertTrue(subject.handle(.relayAck(ack), socketGeneration: 9))
        XCTAssertTrue(subject.hasPendingAction)
        XCTAssertEqual(phases.last, .forwarded(actionID: firstID))
        XCTAssertTrue(haptics.terminalResults.isEmpty)
    }

    func testMacOfflineRelayAckPreservesDistinctPresentationWithoutHaptic() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)
        clock.set(monotonicMilliseconds: 512)
        let ack = RelayAck(actionID: firstID, status: .macOffline, reason: .macOffline,
                           relayProcessingMicroseconds: 1)

        XCTAssertTrue(subject.handle(.relayAck(ack), socketGeneration: 9))
        XCTAssertFalse(subject.hasPendingAction)
        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertTrue(haptics.terminalResults.isEmpty)
        XCTAssertEqual(
            phases.last,
            .rejected(actionID: firstID, reason: .macOffline, elapsedMilliseconds: 12)
        )
        XCTAssertEqual(PhoneActionRejectionReason.macOffline.userFacingDescription,
                       "The Mac went offline.")
    }

    func testMatchingCurrentGenerationMacResultHapticsExactlyOnce() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)
        clock.set(monotonicMilliseconds: 515)
        let result = posted(firstID)

        XCTAssertTrue(subject.handle(.actionResult(result), socketGeneration: 9))
        XCTAssertFalse(subject.handle(.actionResult(result), socketGeneration: 9))
        XCTAssertEqual(haptics.terminalResults, [result])
        XCTAssertEqual(phases.last, .posted(actionID: firstID, elapsedMilliseconds: 15))
    }

    func testRejectedMacResultAlsoHapticsOnlyAfterTerminalResult() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)
        clock.set(monotonicMilliseconds: 520)
        let result = rejected(firstID)

        XCTAssertTrue(subject.handle(.actionResult(result), socketGeneration: 9))
        XCTAssertEqual(haptics.terminalResults, [result])
        XCTAssertEqual(phases.last, .rejected(actionID: firstID, reason: .expired, elapsedMilliseconds: 20))
        XCTAssertEqual(PhoneActionRejectionReason.expired.userFacingDescription,
                       "The click request expired before it could be posted.")
    }

    func testWireResultReasonsMapToInternalPresentationReasons() {
        let mappings: [(ResultReason, PhoneActionRejectionReason)] = [
            (.ok, .invalidRequest),
            (.permissionRequired, .permissionRequired),
            (.remoteDisabled, .remoteDisabled),
            (.idConflict, .idConflict),
            (.expired, .expired),
            (.capacityExceeded, .capacityExceeded),
            (.eventCreationFailed, .eventCreationFailed),
            (.invalidRequest, .invalidRequest),
        ]

        for (wireReason, presentationReason) in mappings {
            XCTAssertEqual(PhoneActionRejectionReason(wireReason), presentationReason)
        }
    }

    func testMismatchedIDAndStaleGenerationAreIgnoredWithoutHaptic() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)

        XCTAssertFalse(subject.handle(.actionResult(posted(secondID)), socketGeneration: 9))
        XCTAssertFalse(subject.handle(.actionResult(posted(firstID)), socketGeneration: 8))
        XCTAssertTrue(subject.hasPendingAction)
        XCTAssertTrue(haptics.terminalResults.isEmpty)
    }

    func testFourSecondTimeoutBecomesUnknownWithNoRetry() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)
        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.resultTimeout])

        scheduler.runFirst(after: PhoneProtocolV1.resultTimeout)

        XCTAssertFalse(subject.hasPendingAction)
        XCTAssertEqual(phases.last, .unknown(actionID: firstID))
        XCTAssertEqual(transport.sentMessages.count, 1)
        XCTAssertTrue(haptics.terminalResults.isEmpty)
    }

    func testBackgroundAbandonmentBecomesUnknownWithoutRetryOrHaptic() {
        let subject = makeSubject()
        _ = subject.accept(delta(), readiness: ready)

        subject.abandonPending(reason: "background")

        XCTAssertFalse(subject.hasPendingAction)
        XCTAssertEqual(phases.last, .unknown(actionID: firstID))
        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertEqual(transport.sentMessages.count, 1)
        XCTAssertTrue(haptics.terminalResults.isEmpty)
    }

    private func posted(_ id: UUID) -> ActionResult {
        ActionResult(actionID: id, status: .posted, reason: .ok, acceptedVia: .oci,
                     macProcessingMicroseconds: 100, mouseDownPostedUnixMilliseconds: 1_786_579_200_010)
    }

    private func rejected(_ id: UUID) -> ActionResult {
        ActionResult(actionID: id, status: .rejected, reason: .expired, acceptedVia: .oci,
                     macProcessingMicroseconds: 100, mouseDownPostedUnixMilliseconds: nil)
    }
}
