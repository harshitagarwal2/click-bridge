import Observation
import SwiftUI

@MainActor
final class PhoneClickIntentRouter {
    static let shared = PhoneClickIntentRouter()

    private var handler: (@MainActor () -> ActionDisposition)?
    private var appIsActive = false
    private var isDelivering = false
    private(set) var hasPendingRequest = false

    func installHandler(_ handler: @escaping @MainActor () -> ActionDisposition) {
        self.handler = handler
        deliverIfPossible()
    }

    func setAppActive(_ isActive: Bool) {
        appIsActive = isActive
        deliverIfPossible()
    }

    func requestClick() {
        hasPendingRequest = true
        deliverIfPossible()
    }

    func discardPendingRequest() {
        hasPendingRequest = false
    }

    private func deliverIfPossible() {
        guard appIsActive, hasPendingRequest, !isDelivering, let handler else { return }
        isDelivering = true
        _ = handler()
        // An App Shortcut gets one immediate delivery attempt after launch-to-active.
        // Every disposition, including not-ready and send failure, consumes it so an old
        // shortcut can never turn into a delayed remote click.
        hasPendingRequest = false
        isDelivering = false
    }
}

@MainActor
@Observable
final class PhoneAppModel {
    static let pairingHost = "clickbridge-sjc.duckdns.org"

    private(set) var state: PhoneState
    private(set) var pairingState = PhonePairingState()
    var pairingSheetPresented = false
    var replacementConfirmationPresented = false
    let settings: PhoneSettingsStore

    private let volumeController: VolumeDeltaController
    private let transport: any PhoneActionTransport
    private let clockHealth: PhoneClockHealthController
    private let actions: PhoneActionCoordinator
    private let intentRouter: PhoneClickIntentRouter
    @ObservationIgnored private var foregroundGeneration: Int?
    @ObservationIgnored private var generationCounter = 0
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private var pairingClient: (any PhonePairingCoordinating)?
    @ObservationIgnored private var pendingReplacementLink: PhonePairingLink?
    @ObservationIgnored private var pairingRecoveryTask: Task<Void, Never>?

    convenience init(settings: PhoneSettingsStore,
                     volumeController: VolumeDeltaController,
                     transport: any PhoneActionTransport,
                     clockHealth: PhoneClockHealthController,
                     actions: PhoneActionCoordinator) {
        self.init(settings: settings,
                  volumeController: volumeController,
                  transport: transport,
                  clockHealth: clockHealth,
                  actions: actions,
                  intentRouter: .shared)
    }

    init(settings: PhoneSettingsStore,
         volumeController: VolumeDeltaController,
         transport: any PhoneActionTransport,
         clockHealth: PhoneClockHealthController,
         actions: PhoneActionCoordinator,
         intentRouter: PhoneClickIntentRouter) {
        self.settings = settings
        self.volumeController = volumeController
        self.transport = transport
        self.clockHealth = clockHealth
        self.actions = actions
        self.intentRouter = intentRouter
        state = PhoneState()
        transport.onEvent = { [weak self] event in self?.handle(event) }
        intentRouter.installHandler { [weak self] in
            self?.triggerClick() ?? .ignoredNotReady
        }
    }

    var canTriggerClick: Bool {
        actions.canAccept(readiness: actionReadiness)
    }

    @discardableResult
    func triggerClick() -> ActionDisposition {
        actions.accept(readiness: actionReadiness)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            if foregroundGeneration == nil { startActiveSession() }
            intentRouter.setAppActive(true)
        case .inactive:
            intentRouter.setAppActive(false)
        case .background:
            sceneIsActive = false
            intentRouter.setAppActive(false)
            intentRouter.discardPendingRequest()
            endForegroundSession(reason: "background")
            cancelPairingForBackgroundIfNeeded()
        @unknown default:
            sceneIsActive = false
            intentRouter.setAppActive(false)
            intentRouter.discardPendingRequest()
            endForegroundSession(reason: "unknown_scene_phase")
            cancelPairingForBackgroundIfNeeded()
        }
    }

    func installPairingClient(_ client: any PhonePairingCoordinating) {
        pairingClient = client
        pairingState = client.state
        client.onState = { [weak self] state in self?.pairingDidChange(state) }
    }

    func showPairingClaimant() {
        pairingState = .init()
        pairingSheetPresented = true
    }

    func submitPairingInvitation(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pairingState = .init(phase: .failed, failure: "invalid_link")
            return
        }
        handlePairingInvitation(url)
    }

    func handlePairingInvitation(_ url: URL) {
        pairingSheetPresented = true
        let link: PhonePairingLink
        do { link = try PhonePairingLink.parse(url, expectedHost: Self.pairingHost) }
        catch {
            pairingState = .init(phase: .failed, failure: "invalid_link")
            return
        }
        if settings.hasToken {
            pendingReplacementLink = link
            replacementConfirmationPresented = true
        } else {
            startPairing(link)
        }
    }

    func confirmPairAgain() {
        replacementConfirmationPresented = false
        guard let link = pendingReplacementLink else { return }
        pendingReplacementLink = nil
        startPairing(link)
    }

    func rejectPairAgain() {
        replacementConfirmationPresented = false
        pendingReplacementLink = nil
    }

    func cancelPairing() {
        pairingClient?.cancel()
    }

    func forgetMac() throws {
        cancelPairing()
        endForegroundSession(reason: "forgot_mac")
        try settings.clearPhoneToken()
        state = PhoneState()
        pairingState = .init()
        pairingSheetPresented = false
    }

    func saveSettings(urlString: String, token: String) throws {
        let resolvedToken: String
        if token.isEmpty {
            do {
                resolvedToken = try settings.phoneToken() ?? ""
            } catch {
                state.issue = .secureStorageUnavailable
                throw PhoneAppIssue.secureStorageUnavailable
            }
        } else {
            resolvedToken = token
        }

        let configuration: RelayConfiguration
        do {
            configuration = try RelayConfiguration.validated(urlString: urlString,
                                                              token: resolvedToken)
        } catch {
            throw PhoneAppIssue.invalidSettings
        }

        if !token.isEmpty {
            do {
                try settings.savePhoneToken(token)
            } catch {
                state.issue = .secureStorageUnavailable
                throw PhoneAppIssue.secureStorageUnavailable
            }
        }

        settings.relayURLString = configuration.url.absoluteString
        state.issue = nil
        if state.phoneTakenOver { state.connection = .disconnected }
        if foregroundGeneration != nil {
            endForegroundSession(reason: "settings_changed")
            startForegroundSession()
        } else if sceneIsActive {
            startForegroundSession()
        }
    }

    func retryClockCheck() { clockHealth.retry() }

    func reconnectAfterTakeover() {
        guard state.phoneTakenOver else { return }
        endForegroundSession(reason: "takeover_reconnect")
        state.connection = .disconnected
        if sceneIsActive { startForegroundSession() }
    }

    func applyClockHealth(_ health: ClockHealth) {
        state.clock = health
    }
    func applyActionPhase(_ phase: PhoneActionPhase) {
        state.actionPhase = phase
        switch phase {
        case .posted(_, let elapsed): state.lastActionOutcome = "Posted in \(Int(elapsed.rounded())) ms"
        case .rejected(_, let reason, _): state.lastActionOutcome = reason.userFacingDescription
        case .unknown: state.lastActionOutcome = "Outcome unknown"
        default: break
        }
    }

    private func startForegroundSession(connectTransport: Bool = true) {
        guard !state.phoneTakenOver else { return }
        let token: String
        do {
            guard let storedToken = try settings.phoneToken() else { return }
            token = storedToken
        } catch {
            state.issue = .secureStorageUnavailable
            return
        }

        let configuration: RelayConfiguration
        do {
            configuration = try RelayConfiguration.validated(urlString: settings.relayURLString,
                                                              token: token)
        } catch {
            state.issue = .invalidSettings
            return
        }

        generationCounter += 1
        let generation = generationCounter
        foregroundGeneration = generation
        state.foregroundSessionActive = true
        state.clock = .init(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
        if connectTransport { transport.connect(configuration: configuration) }
        do {
            try volumeController.start(foregroundGeneration: generation) { [weak self] event in
                self?.handleVolume(event, foregroundGeneration: generation)
            }
            state.issue = nil
        } catch {
            endForegroundSession(reason: "volume_monitoring_unavailable")
            state.issue = .volumeMonitoringUnavailable
        }
    }

    private func startPairing(_ link: PhonePairingLink) {
        guard let pairingClient else {
            pairingState = .init(phase: .failed, failure: "pairing_unavailable")
            return
        }
        endForegroundSession(reason: "pairing_started")
        pairingRecoveryTask?.cancel()
        pairingRecoveryTask = nil
        do {
            pairingClient.start(link, replacementAuthorization: try settings.replacementAuthorization())
        } catch {
            pairingState = .init(phase: .failed, failure: "secure_storage_unavailable")
        }
    }

    private func pairingDidChange(_ newState: PhonePairingState) {
        pairingState = newState
        guard newState.phase == .active, sceneIsActive else { return }
        startForegroundSession(connectTransport: false)
    }

    private func cancelPairingForBackgroundIfNeeded() {
        let recovering = pairingRecoveryTask != nil
        pairingRecoveryTask?.cancel()
        pairingRecoveryTask = nil
        if recovering || PhonePairingPresentation.shouldCancelOnBackground(pairingState.phase) {
            pairingClient?.cancel()
        }
    }

    private func startActiveSession() {
        guard pairingRecoveryTask == nil else { return }
        let pending: PhonePairingPendingCredential?
        do { pending = try settings.pendingPairingRecoveryDescriptor() }
        catch {
            state.issue = .secureStorageUnavailable
            return
        }
        guard let pending, let pairingClient else {
            startForegroundSession()
            return
        }
        pairingRecoveryTask = Task { [weak self] in
            let result = await pairingClient.recoverPending(relayWebSocketURL: pending.relayWebSocketURL)
            guard let self else { return }
            pairingRecoveryTask = nil
            guard sceneIsActive, !Task.isCancelled else { return }
            if result == .recovered {
                startForegroundSession(connectTransport: false)
            } else if result == .noPending || result == .superseded {
                startForegroundSession()
            } else {
                pairingState = .init(phase: .failed, failure: "pending_recovery_failed")
            }
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
        if state.connection != .takenOver { state.connection = .disconnected }
        state.clock = .init(status: .unchecked, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
    }

    private func handleVolume(_ event: VolumeDeltaEvent, foregroundGeneration: Int) {
        guard self.foregroundGeneration == foregroundGeneration else { return }
        switch event {
        case .baseline(let reading): state.volume = reading
        case .delta(let delta):
            state.volume = .init(value: delta.current)
            _ = actions.accept(delta, readiness: actionReadiness)
        }
    }

    private var actionReadiness: ActionGateSnapshot {
        ActionGateSnapshot(
            foregroundGeneration: foregroundGeneration,
            socketGeneration: transport.generation,
            transportAuthenticated: transport.isAuthenticated,
            mac: state.mac,
            clock: state.clock
        )
    }

    private func handle(_ event: PhoneTransportEvent) {
        switch event {
        case .connection(let generation, let connection):
            guard foregroundGeneration != nil, generation == transport.generation else { return }
            guard !state.phoneTakenOver else { return }
            state.connection = connection
            if connection == .authenticated {
                startClockCheckIfReady(socketGeneration: generation)
            } else {
                actions.abandonPending(reason: "transport_\(connection)")
                stopClockCheck()
            }
        case .message(let generation, let message):
            guard foregroundGeneration != nil, generation == transport.generation else { return }
            guard !state.phoneTakenOver else { return }
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
