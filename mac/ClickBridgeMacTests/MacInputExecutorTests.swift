import XCTest
@testable import ClickBridgeMac

private final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class MacInputExecutorTests: XCTestCase {
    func testOneLogicalPostConstructsThreePairsBeforeOrderedAttemptedPosts() {
        let trace = TraceRecorder()
        let executor = MacInputExecutor(
            clickGapMs: 7,
            constructEvents: {
                (1...3).map { pairID in
                    trace.append("construct\(pairID)")
                    return ClickEventPair.testing(pairID: pairID)
                }
            },
            postEvent: { trace.append("\($0.phase.rawValue)\($0.pairID)") },
            sleepMicroseconds: { trace.append("sleep-\($0)") },
            wallClockMilliseconds: { trace.append("timestamp"); return 1_234.5 }
        )

        guard case .posted(let timestamp) = executor.postLeftClickAtCurrentCursor() else {
            return XCTFail("expected posted")
        }

        XCTAssertEqual(timestamp, 1_234.5)
        XCTAssertEqual(trace.snapshot(), [
            "construct1", "construct2", "construct3", "timestamp",
            "down1", "sleep-7000", "up1",
            "down2", "sleep-7000", "up2",
            "down3", "sleep-7000", "up3",
        ])
        XCTAssertEqual(executor.diagnosticPostCounts(),
                       InputPostCounts(mouseDownPostCount: 3, mouseUpPostCount: 3))
    }

    func testConstructionFailurePostsNothingAndKeepsCountersZero() {
        let trace = TraceRecorder()
        let executor = MacInputExecutor(
            constructEvents: { nil },
            postEvent: { _ in trace.append("posted") },
            sleepMicroseconds: { _ in }
        )
        XCTAssertEqual(executor.postLeftClickAtCurrentCursor(), .creationFailed)
        XCTAssertTrue(trace.snapshot().isEmpty)
        XCTAssertEqual(executor.diagnosticPostCounts(), .zero)
    }

    func testIncompleteBurstPostsNothingAndKeepsCountersZero() {
        let trace = TraceRecorder()
        let executor = MacInputExecutor(
            constructEvents: { [ClickEventPair.testing(pairID: 1),
                                ClickEventPair.testing(pairID: 2)] },
            postEvent: { _ in trace.append("posted") },
            sleepMicroseconds: { _ in }
        )

        XCTAssertEqual(executor.postLeftClickAtCurrentCursor(), .creationFailed)
        XCTAssertTrue(trace.snapshot().isEmpty)
        XCTAssertEqual(executor.diagnosticPostCounts(), .zero)
    }
}
