import XCTest
@testable import ClickBridgePhone

@MainActor
final class VolumeDeltaControllerTests: XCTestCase {
    func testUpDownDuplicatesAndRapidDistinctValuesProduceOnlyDistinctDeltas() throws {
        let source = TestVolumeSource(volume: 0.50)
        let subject = VolumeDeltaController(source: source)
        var events: [VolumeDeltaEvent] = []

        try subject.start(foregroundGeneration: 7) { events.append($0) }
        source.emit(0.50)
        source.emit(0.5625)
        source.emit(0.5625)
        source.emit(0.50)
        source.emit(0.625)

        XCTAssertEqual(events, [
            .baseline(VolumeReading(value: 0.50)),
            .delta(.init(previous: 0.50, current: 0.5625,
                         direction: .up, foregroundGeneration: 7)),
            .delta(.init(previous: 0.5625, current: 0.50,
                         direction: .down, foregroundGeneration: 7)),
            .delta(.init(previous: 0.50, current: 0.625,
                         direction: .up, foregroundGeneration: 7))
        ])
    }

    func testJumpIsOneDeltaAndBoundariesAreDerived() throws {
        let source = TestVolumeSource(volume: 0.25)
        let subject = VolumeDeltaController(source: source)
        var events: [VolumeDeltaEvent] = []
        try subject.start(foregroundGeneration: 1) { events.append($0) }

        source.emit(0.75)
        source.emit(1)
        source.emit(0)

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .baseline(VolumeReading(value: 0.25)))
        XCTAssertEqual(events[1], .delta(.init(previous: 0.25, current: 0.75, direction: .up, foregroundGeneration: 1)))
        XCTAssertEqual(VolumeReading(value: 1).boundary, .maximum)
        XCTAssertEqual(VolumeReading(value: 0).boundary, .minimum)
    }

    func testStopAndRestartIgnoreCapturedStaleObserver() throws {
        let source = TestVolumeSource(volume: 0.4)
        let subject = VolumeDeltaController(source: source)
        var events: [VolumeDeltaEvent] = []
        try subject.start(foregroundGeneration: 7) { events.append($0) }
        let stale = try XCTUnwrap(source.handlers.last)
        subject.stop()
        stale(0.5)
        source.currentVolume = 0.7
        try subject.start(foregroundGeneration: 8) { events.append($0) }
        stale(0.6)
        source.emit(0.7)

        XCTAssertEqual(events, [.baseline(.init(value: 0.4)), .baseline(.init(value: 0.7))])
    }

    func testInvalidValuesDoNotMoveBaseline() throws {
        let source = TestVolumeSource(volume: 0.5)
        let subject = VolumeDeltaController(source: source)
        var events: [VolumeDeltaEvent] = []
        try subject.start(foregroundGeneration: 3) { events.append($0) }
        source.emit(.nan)
        source.emit(-0.1)
        source.emit(1.1)
        source.emit(0.6)
        XCTAssertEqual(events.last, .delta(.init(previous: 0.5, current: 0.6, direction: .up, foregroundGeneration: 3)))
    }
}

@MainActor
private final class TestVolumeSource: VolumeChangeSource {
    var currentVolume: Float
    private(set) var handlers: [(@MainActor @Sendable (Float) -> Void)] = []
    init(volume: Float) { currentVolume = volume }
    func start(observing handler: @escaping @MainActor @Sendable (Float) -> Void) throws {
        handlers.append(handler)
        handler(currentVolume)
    }
    func stop() {}
    func emit(_ value: Float) { currentVolume = value; handlers.last?(value) }
}
