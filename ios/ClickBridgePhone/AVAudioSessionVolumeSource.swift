import AVFAudio

@MainActor
final class AVAudioSessionVolumeSource: VolumeChangeSource {
    private let session: AVAudioSession
    private var observation: NSKeyValueObservation?

    init(session: AVAudioSession = .sharedInstance()) { self.session = session }
    var currentVolume: Float { session.outputVolume }

    func start(observing handler: @escaping @MainActor @Sendable (Float) -> Void) throws {
        stop()
        try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        observation = session.observe(\.outputVolume, options: [.initial, .new]) { _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in handler(value) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
