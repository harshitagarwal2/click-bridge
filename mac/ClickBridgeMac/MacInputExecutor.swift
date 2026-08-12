import Foundation
import CoreGraphics

enum ClickEventPhase: String, Sendable { case down, up }

struct ClickEvent: @unchecked Sendable {
    let phase: ClickEventPhase
    fileprivate let native: CGEvent?
    init(phase: ClickEventPhase, native: CGEvent? = nil) { self.phase = phase; self.native = native }
}

struct ClickEventPair: @unchecked Sendable {
    let down: ClickEvent
    let up: ClickEvent
    static let testing = ClickEventPair(down: ClickEvent(phase: .down), up: ClickEvent(phase: .up))
}

final class MacInputExecutor: InputPosting, @unchecked Sendable {
    typealias EventConstruction = @Sendable () -> ClickEventPair?
    typealias EventPosting = @Sendable (ClickEvent) -> Void
    typealias GapSleeping = @Sendable (UInt32) -> Void

    private let clickGapMs: UInt32
    private let constructEvents: EventConstruction
    private let postEvent: EventPosting
    private let sleepMicroseconds: GapSleeping
    private let lock = NSLock()
    private var counts = InputPostCounts.zero

    init(
        clickGapMs: UInt32 = UInt32(Constants.clickGapMs),
        constructEvents: @escaping EventConstruction = { MacInputExecutor.makeNativeEvents() },
        postEvent: @escaping EventPosting = { MacInputExecutor.postNativeEvent($0) },
        sleepMicroseconds: @escaping GapSleeping = { usleep($0) }
    ) {
        self.clickGapMs = clickGapMs
        self.constructEvents = constructEvents
        self.postEvent = postEvent
        self.sleepMicroseconds = sleepMicroseconds
    }

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        guard let events = constructEvents() else { return .creationFailed }
        let mouseDownUnixMs = Date().timeIntervalSince1970 * 1_000
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
        return .posted(mouseDownUnixMs: mouseDownUnixMs)
    }

    func diagnosticPostCounts() -> InputPostCounts { lock.withLock { counts } }

    private static func makeNativeEvents() -> ClickEventPair? {
        guard let probe = CGEvent(source: nil) else { return nil }
        let point = probe.location
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        return ClickEventPair(down: ClickEvent(phase: .down, native: down),
                              up: ClickEvent(phase: .up, native: up))
    }

    private static func postNativeEvent(_ event: ClickEvent) {
        event.native?.post(tap: .cghidEventTap)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
