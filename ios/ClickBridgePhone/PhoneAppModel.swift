import SwiftUI

@MainActor
final class PhoneAppModel: ObservableObject {
    @Published private(set) var state: PhoneState
    let settings: PhoneSettingsStore

    private let volumeController: VolumeDeltaController
    private let transport: any PhoneActionTransport
    private let clockHealth: PhoneClockHealthController
    private let actions: PhoneActionCoordinator
    private var foregroundGeneration: Int?
    private var generationCounter = 0
    private var sceneIsActive = false

    init(settings: PhoneSettingsStore,
         volumeController: VolumeDeltaController,
         transport: any PhoneActionTransport,
         clockHealth: PhoneClockHealthController,
         actions: PhoneActionCoordinator) {
        self.settings = settings
        self.volumeController = volumeController
        self.transport = transport
        self.clockHealth = clockHealth
        self.actions = actions
        state = PhoneState()
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            if foregroundGeneration == nil { startForegroundSession() }
        case .inactive:
            break
        case .background:
            sceneIsActive = false
            endForegroundSession(reason: "background")
        @unknown default:
            sceneIsActive = false
            endForegroundSession(reason: "unknown_scene_phase")
        }
    }

    func saveSettings(urlString: String, token: String) throws {
        let configuration: RelayConfiguration
        do {
            configuration = try RelayConfiguration.validated(urlString: urlString, token: token)
        } catch {
            endForegroundSession(reason: "settings_invalid")
            state.settingsError = "Relay settings are invalid."
            throw error
        }

        do {
            try settings.savePhoneToken(token)
        } catch {
            state.settingsError = "Secure storage is unavailable. Try again or restart the app."
            throw error
        }

        settings.relayURLString = configuration.url.absoluteString
        state.settingsError = nil
        if foregroundGeneration != nil {
            endForegroundSession(reason: "settings_changed")
            startForegroundSession()
        } else if sceneIsActive {
            startForegroundSession()
        }
    }

    func retryClockCheck() { clockHealth.retry() }

    func applyClockHealth(_ health: ClockHealth) { state.clock = health }
    func applyActionPhase(_ phase: PhoneActionPhase) {
        state.actionPhase = phase
        switch phase {
        case .posted(_, let elapsed): state.lastActionOutcome = "Posted in \(Int(elapsed.rounded())) ms"
        case .rejected(_, let reason, _): state.lastActionOutcome = "Rejected: \(reason.rawValue)"
        case .unknown: state.lastActionOutcome = "Outcome unknown"
        default: break
        }
    }

    private func startForegroundSession() {
        do {
            guard let token = try settings.phoneToken() else { return }
            let configuration = try RelayConfiguration.validated(urlString: settings.relayURLString, token: token)
            generationCounter += 1
            let generation = generationCounter
            foregroundGeneration = generation
            state.foregroundSessionActive = true
            state.clock = .init(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
            transport.connect(configuration: configuration)
            try volumeController.start(foregroundGeneration: generation) { [weak self] event in
                self?.handleVolume(event, foregroundGeneration: generation)
            }
        } catch {
            endForegroundSession(reason: "configuration_invalid")
            state.settingsError = "Relay settings are invalid or unavailable."
        }
    }

    private func endForegroundSession(reason: String) {
        guard foregroundGeneration != nil else { return }
        foregroundGeneration = nil
        state.foregroundSessionActive = false
        volumeController.stop()
        clockHealth.stop()
        actions.abandonPending(reason: reason)
        transport.disconnect(reason: reason)
        state.connection = .disconnected
        state.clock = .init(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
    }

    private func handleVolume(_ event: VolumeDeltaEvent, foregroundGeneration: Int) {
        guard self.foregroundGeneration == foregroundGeneration else { return }
        switch event {
        case .baseline(let reading): state.volume = reading
        case .delta(let delta):
            state.volume = .init(value: delta.current)
            _ = actions.accept(delta, readiness: .init(
                foregroundGeneration: self.foregroundGeneration,
                socketGeneration: transport.generation,
                transportAuthenticated: transport.isAuthenticated,
                mac: state.mac,
                clock: state.clock
            ))
        }
    }

    private func handle(_ event: PhoneTransportEvent) {
        switch event {
        case .connection(let generation, let connection):
            guard foregroundGeneration != nil, generation == transport.generation else { return }
            state.connection = connection
            if connection == .authenticated {
                startClockCheckIfReady(socketGeneration: generation)
            } else {
                actions.abandonPending(reason: "transport_\(connection)")
                stopClockCheck()
            }
        case .message(let generation, let message):
            guard foregroundGeneration != nil, generation == transport.generation else { return }
            switch message {
            case .state(let relayState):
                let wasReady = macIsReady
                state.mac = .init(online: relayState.macOnline,
                                  remoteEnabled: relayState.remoteEnabled,
                                  permission: relayState.permission)
                if macIsReady {
                    if !wasReady { startClockCheckIfReady(socketGeneration: generation) }
                } else if wasReady || state.clock.status != .unchecked {
                    stopClockCheck()
                }
            case .timeSyncResponse(let response):
                _ = clockHealth.handle(response, socketGeneration: generation)
            case .relayAck, .actionResult:
                if actions.handle(message, socketGeneration: generation) { clockHealth.actionDidSettle() }
            default: break
            }
        }
    }

    private var macIsReady: Bool {
        state.mac.online && state.mac.remoteEnabled && state.mac.permission == .ready
    }

    private func startClockCheckIfReady(socketGeneration: Int) {
        guard state.connection == .authenticated,
              transport.isAuthenticated,
              macIsReady,
              let foregroundGeneration else { return }
        clockHealth.start(foregroundGeneration: foregroundGeneration,
                          socketGeneration: socketGeneration,
                          send: { [weak transport] message in transport?.send(message) ?? false })
    }

    private func stopClockCheck() {
        clockHealth.stop()
        state.clock = .init(status: .unchecked,
                            offsetMilliseconds: nil,
                            uncertaintyMilliseconds: nil)
    }
}
