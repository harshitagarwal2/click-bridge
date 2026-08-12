import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhoneClockHealthControllerTests: XCTestCase {
    func testClockSampleAndBestSampleMatchPWAFormula() {
        let first = ClockSample(t0: 1_000, t1: 1_020, t2: 1_021, t3: 1_051)
        let second = ClockSample(t0: 2_000, t1: 2_005, t2: 2_006, t3: 2_016)

        XCTAssertEqual(first.offsetMilliseconds, -5)
        XCTAssertEqual(first.roundTripMilliseconds, 50)
        XCTAssertEqual(ClockSample.best([first, second]), second)
    }

    func testFiveSequentialMatchingSamplesChooseMinimumRTTAndPublishHealthy() {
        let clock = FakePhoneClock(unixMilliseconds: 1_000, monotonicMilliseconds: 0)
        let scheduler = FakePhoneScheduler()
        var sent: [PhoneClientMessage] = []
        var health: [ClockHealth] = []
        var ids = (1...5).map { UUID(uuidString: String(format: "018f63f5-6f3d-7d21-88bc-9ef561f030%02x", $0))! }
        let subject = PhoneClockHealthController(
            clock: clock,
            scheduler: scheduler,
            makeSyncID: { ids.removeFirst() },
            isActionPending: { false },
            onHealth: { health.append($0) }
        )

        subject.start(foregroundGeneration: 4, socketGeneration: 9) { message in
            sent.append(message)
            return true
        }
        XCTAssertEqual(sent.count, 1)

        let rtts: [Double] = [50, 40, 10, 30, 20]
        for index in 0..<5 {
            guard case .timeSyncRequest(let request) = sent[index] else {
                return XCTFail("Expected time sync request")
            }
            let t0 = request.phoneSendUnixMilliseconds
            let rtt = rtts[index]
            clock.set(unixMilliseconds: t0 + rtt)
            let response = TimeSyncResponse(
                syncID: request.syncID,
                phoneSendUnixMilliseconds: t0,
                macReceiveUnixMilliseconds: t0 + 5,
                macSendUnixMilliseconds: t0 + 6
            )
            XCTAssertTrue(subject.handle(response, socketGeneration: 9))
        }

        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(health.first?.status, .checking)
        XCTAssertEqual(health.last?.status, .healthy)
        XCTAssertEqual(health.last?.uncertaintyMilliseconds, 4.5)
        XCTAssertEqual(scheduler.entries.map(\.delay), [PhoneProtocolV1.clockRefreshInterval])
    }

    func testMismatchedIDTimestampAndStaleGenerationAreIgnored() {
        let clock = FakePhoneClock(unixMilliseconds: 1_000)
        let scheduler = FakePhoneScheduler()
        var sent: [PhoneClientMessage] = []
        let subject = PhoneClockHealthController(
            clock: clock,
            scheduler: scheduler,
            isActionPending: { false },
            onHealth: { _ in }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 2) { sent.append($0); return true }
        guard case .timeSyncRequest(let request) = sent[0] else { return XCTFail() }

        XCTAssertFalse(subject.handle(
            TimeSyncResponse(syncID: UUID(), phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                             macReceiveUnixMilliseconds: 1_010, macSendUnixMilliseconds: 1_011),
            socketGeneration: 2
        ))
        XCTAssertFalse(subject.handle(
            TimeSyncResponse(syncID: request.syncID, phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds + 1,
                             macReceiveUnixMilliseconds: 1_010, macSendUnixMilliseconds: 1_011),
            socketGeneration: 2
        ))
        XCTAssertFalse(subject.handle(
            TimeSyncResponse(syncID: request.syncID, phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                             macReceiveUnixMilliseconds: 1_010, macSendUnixMilliseconds: 1_011),
            socketGeneration: 3
        ))
        XCTAssertEqual(sent.count, 1)
    }

    func testExchangeTimeoutPublishesUnavailable() {
        let scheduler = FakePhoneScheduler()
        var health: [ClockHealth] = []
        let subject = PhoneClockHealthController(
            clock: FakePhoneClock(),
            scheduler: scheduler,
            isActionPending: { false },
            onHealth: { health.append($0) }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 1) { _ in true }

        scheduler.runFirst(after: PhoneProtocolV1.clockExchangeTimeout)

        XCTAssertEqual(health.last?.status, .unavailable)
        XCTAssertTrue(scheduler.entries.isEmpty)
    }

    func testClockMismatchUsesTolerancePlusHalfRTT() {
        let clock = FakePhoneClock(unixMilliseconds: 1_000)
        let scheduler = FakePhoneScheduler()
        var requests: [PhoneClientMessage] = []
        var health: [ClockHealth] = []
        let subject = PhoneClockHealthController(
            clock: clock,
            scheduler: scheduler,
            isActionPending: { false },
            onHealth: { health.append($0) }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 1) { requests.append($0); return true }

        for index in 0..<5 {
            guard case .timeSyncRequest(let request) = requests[index] else { return XCTFail() }
            clock.set(unixMilliseconds: request.phoneSendUnixMilliseconds + 10)
            XCTAssertTrue(subject.handle(
                TimeSyncResponse(
                    syncID: request.syncID,
                    phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                    macReceiveUnixMilliseconds: request.phoneSendUnixMilliseconds + 1_020,
                    macSendUnixMilliseconds: request.phoneSendUnixMilliseconds + 1_021
                ),
                socketGeneration: 1
            ))
        }

        XCTAssertEqual(health.last?.status, .mismatch)
    }

    func testFiveExchangesWithNoUsableRoundTripPublishUnavailable() {
        let clock = FakePhoneClock(unixMilliseconds: 1_000)
        let scheduler = FakePhoneScheduler()
        var requests: [PhoneClientMessage] = []
        var health: [ClockHealth] = []
        let subject = PhoneClockHealthController(
            clock: clock,
            scheduler: scheduler,
            isActionPending: { false },
            onHealth: { health.append($0) }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 1) { requests.append($0); return true }

        for index in 0..<5 {
            guard case .timeSyncRequest(let request) = requests[index] else { return XCTFail() }
            clock.set(unixMilliseconds: request.phoneSendUnixMilliseconds + 1)
            XCTAssertTrue(subject.handle(
                TimeSyncResponse(
                    syncID: request.syncID,
                    phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                    macReceiveUnixMilliseconds: request.phoneSendUnixMilliseconds + 10,
                    macSendUnixMilliseconds: request.phoneSendUnixMilliseconds + 20
                ),
                socketGeneration: 1
            ))
        }

        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(health.last?.status, .unavailable)
    }

    func testRefreshDefersWhileActionPendingAndStartsWhenActionSettles() {
        let scheduler = FakePhoneScheduler()
        let clock = FakePhoneClock(unixMilliseconds: 1_000)
        var pending = false
        var requests: [PhoneClientMessage] = []
        let subject = PhoneClockHealthController(
            clock: clock,
            scheduler: scheduler,
            isActionPending: { pending },
            onHealth: { _ in }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 1) { requests.append($0); return true }
        completeHealthyBatch(subject: subject, clock: clock, requests: { requests }, socketGeneration: 1)
        XCTAssertEqual(requests.count, 5)

        pending = true
        scheduler.runFirst(after: PhoneProtocolV1.clockRefreshInterval)
        XCTAssertEqual(requests.count, 5)
        subject.actionDidSettle()
        XCTAssertEqual(requests.count, 5)

        pending = false
        subject.actionDidSettle()
        XCTAssertEqual(requests.count, 6)
    }

    func testStopInvalidatesOutstandingBatchAndCancelsTimers() {
        let scheduler = FakePhoneScheduler()
        var requests: [PhoneClientMessage] = []
        let subject = PhoneClockHealthController(
            clock: FakePhoneClock(), scheduler: scheduler,
            isActionPending: { false }, onHealth: { _ in }
        )
        subject.start(foregroundGeneration: 1, socketGeneration: 1) { requests.append($0); return true }
        guard case .timeSyncRequest(let request) = requests[0] else { return XCTFail() }
        subject.stop()

        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertFalse(subject.handle(
            TimeSyncResponse(syncID: request.syncID, phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                             macReceiveUnixMilliseconds: 2, macSendUnixMilliseconds: 3),
            socketGeneration: 1
        ))
    }

    private func completeHealthyBatch(
        subject: PhoneClockHealthController,
        clock: FakePhoneClock,
        requests: () -> [PhoneClientMessage],
        socketGeneration: Int
    ) {
        for index in 0..<5 {
            guard case .timeSyncRequest(let request) = requests()[index] else { return XCTFail() }
            clock.set(unixMilliseconds: request.phoneSendUnixMilliseconds + 10)
            _ = subject.handle(
                TimeSyncResponse(
                    syncID: request.syncID,
                    phoneSendUnixMilliseconds: request.phoneSendUnixMilliseconds,
                    macReceiveUnixMilliseconds: request.phoneSendUnixMilliseconds + 5,
                    macSendUnixMilliseconds: request.phoneSendUnixMilliseconds + 6
                ),
                socketGeneration: socketGeneration
            )
        }
    }
}
