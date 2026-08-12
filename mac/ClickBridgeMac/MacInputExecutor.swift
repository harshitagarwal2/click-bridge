import Foundation
import CoreGraphics

enum ClickEventPhase: String, Sendable { case down, up }

struct ClickEvent: @unchecked Sendable {
    let phase: ClickEventPhase
    let pairID: Int
    fileprivate let native: CGEvent?
    init(phase: ClickEventPhase, pairID: Int, native: CGEvent? = nil) {
        self.phase = phase
        self.pairID = pairID
        self.native = native
    }
}

struct ClickEventPair: @unchecked Sendable {
    let down: ClickEvent
    let up: ClickEvent
    static func testing(pairID: Int) -> ClickEventPair {
        ClickEventPair(down: ClickEvent(phase: .down, pairID: pairID),
                       up: ClickEvent(phase: .up, pairID: pairID))
    }
}

final class MacInputExecutor: InputPosting, @unchecked Sendable {
    typealias EventConstruction = @Sendable () -> [ClickEventPair]?
    typealias EventPosting = @Sendable (ClickEvent) -> Void
    typealias GapSleeping = @Sendable (UInt32) -> Void
    typealias WallClockMilliseconds = @Sendable () -> Double

    private let clickGapMs: UInt32
    private let constructEvents: EventConstruction
    private let postEvent: EventPosting
    private let sleepMicroseconds: GapSleeping
    private let wallClockMilliseconds: WallClockMilliseconds
    private let lock = NSLock()
    private var counts = InputPostCounts.zero

    init(
        clickGapMs: UInt32 = UInt32(Constants.clickGapMs),
        constructEvents: @escaping EventConstruction = { MacInputExecutor.makeNativeEvents() },
        postEvent: @escaping EventPosting = { MacInputExecutor.postNativeEvent($0) },
        sleepMicroseconds: @escaping GapSleeping = { usleep($0) },
        wallClockMilliseconds: @escaping WallClockMilliseconds = {
            Date().timeIntervalSince1970 * 1_000
        }
    ) {
        self.clickGapMs = clickGapMs
        self.constructEvents = constructEvents
        self.postEvent = postEvent
        self.sleepMicroseconds = sleepMicroseconds
        self.wallClockMilliseconds = wallClockMilliseconds
    }

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        guard let eventPairs = constructEvents(),
              eventPairs.count == Constants.clickRepetitions else {
            return .creationFailed
        }
        let mouseDownUnixMs = wallClockMilliseconds()
        for events in eventPairs {
            postEvent(events.down)
            lock.withLock {
                counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount + 1,
                                         mouseUpPostCount: counts.mouseUpPostCount)
            }
            if clickGapMs > 0 { sleepMicroseconds(clickGapMs * 1_000) }
            postEvent(events.up)
            lock.withLock {
                counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount,
                                         mouseUpPostCount: counts.mouseUpPostCount + 1)
            }
        }
        return .posted(mouseDownUnixMs: mouseDownUnixMs)
    }

    func diagnosticPostCounts() -> InputPostCounts { lock.withLock { counts } }

    private static func makeNativeEvents() -> [ClickEventPair]? {
        guard let probe = CGEvent(source: nil) else { return nil }
        let point = probe.location
        let source = CGEventSource(stateID: .hidSystemState)
        var pairs: [ClickEventPair] = []
        pairs.reserveCapacity(Constants.clickRepetitions)

        for pairID in 1...Constants.clickRepetitions {
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) else {
                return nil
            }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            pairs.append(ClickEventPair(
                down: ClickEvent(phase: .down, pairID: pairID, native: down),
                up: ClickEvent(phase: .up, pairID: pairID, native: up)
            ))
        }
        return pairs
    }

    private static func postNativeEvent(_ event: ClickEvent) {
        event.native?.post(tap: .cghidEventTap)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
