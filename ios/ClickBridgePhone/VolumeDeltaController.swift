import Foundation

enum VolumeBoundary: Equatable, Sendable { case minimum, maximum }

struct VolumeReading: Equatable, Sendable {
    let value: Float
    var boundary: VolumeBoundary? {
        if value <= 0 { return .minimum }
        if value >= 1 { return .maximum }
        return nil
    }
}

struct ObservedVolumeDelta: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case up, down }
    let previous: Float
    let current: Float
    let direction: Direction
    let foregroundGeneration: Int
}

enum VolumeDeltaEvent: Equatable, Sendable {
    case baseline(VolumeReading)
    case delta(ObservedVolumeDelta)
}

@MainActor
final class VolumeDeltaController {
    private let source: any VolumeChangeSource
    private var observationGeneration = 0
    private var lastObservedVolume: Float?

    init(source: any VolumeChangeSource) { self.source = source }

    func start(foregroundGeneration: Int,
               onEvent: @escaping @MainActor @Sendable (VolumeDeltaEvent) -> Void) throws {
        stop()
        observationGeneration += 1
        let capturedObservationGeneration = observationGeneration
        try source.start { [weak self] value in
            guard let self, capturedObservationGeneration == self.observationGeneration else { return }
            self.receive(value, foregroundGeneration: foregroundGeneration, onEvent: onEvent)
        }
    }

    func stop() {
        observationGeneration += 1
        lastObservedVolume = nil
        source.stop()
    }

    private func receive(_ value: Float,
                         foregroundGeneration: Int,
                         onEvent: @escaping @MainActor (VolumeDeltaEvent) -> Void) {
        guard value.isFinite, (0...1).contains(value) else { return }
        guard let previous = lastObservedVolume else {
            lastObservedVolume = value
            onEvent(.baseline(.init(value: value)))
            return
        }
        guard value != previous else { return }
        lastObservedVolume = value
        onEvent(.delta(.init(previous: previous,
                            current: value,
                            direction: value > previous ? .up : .down,
                            foregroundGeneration: foregroundGeneration)))
    }
}
