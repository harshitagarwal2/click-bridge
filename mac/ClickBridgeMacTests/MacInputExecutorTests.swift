import XCTest
@testable import ClickBridgeMac

private final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class MacInputExecutorTests: XCTestCase {
    func testBothEventsAreConstructedBeforeDownUpPostsWithOneGap() {
        let trace = TraceRecorder()
        let executor = MacInputExecutor(
            clickGapMs: 7,
            constructEvents: { trace.append("construct-both"); return ClickEventPair.testing },
            postEvent: { trace.append("post-\($0.phase.rawValue)") },
            sleepMicroseconds: { trace.append("sleep-\($0)") }
        )
        guard case .posted(let timestamp) = executor.postLeftClickAtCurrentCursor() else {
            return XCTFail("expected posted")
        }
        XCTAssertGreaterThan(timestamp, 0)
        XCTAssertEqual(trace.snapshot(), ["construct-both", "post-down", "sleep-7000", "post-up"])
        XCTAssertEqual(executor.diagnosticPostCounts(), InputPostCounts(mouseDownPostCount: 1, mouseUpPostCount: 1))
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
}
