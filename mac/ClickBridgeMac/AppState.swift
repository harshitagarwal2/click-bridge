import Foundation
import AppKit

struct PairingActionPresentation: Equatable {
    let title: String
    let requiresReplacementConfirmation: Bool

    init(status: PairStatus?) {
        let replacing = status?.requiresReplacementConfirmation == true
        title = replacing ? "Replace Phone" : "Pair Phone"
        requiresReplacementConfirmation = replacing
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var connection: RelayClient.Status = .disconnected
    @Published private(set) var permission: PermissionState = .unknown
    @Published private(set) var lastResult = "—"
    @Published var notice: String?
    @Published private(set) var pairing: PairingController?
    @Published private(set) var pairingAction = PairingActionPresentation(status: nil)

    let settings: SettingsStore
    private let client: RelayClient
    private let processor: ActionProcessor
    private let permissionService: PostEventPermissionService
    private let activationNotifications: NotificationCenter
    private var activationObserver: NSObjectProtocol?
    private var credentialRevision: UInt64 = 0
    private var credentialTask: Task<Void, Never>?
    private var credentialEligible = true
    private var lastStatusSequence: UInt64 = 0

    init(settings: SettingsStore, client: RelayClient, processor: ActionProcessor,
         permissionService: PostEventPermissionService,
         activationNotifications: NotificationCenter = .default,
         initialNotice: String? = nil) {
        self.settings = settings
        self.client = client
        self.processor = processor
        self.permissionService = permissionService
        self.activationNotifications = activationNotifications
        notice = initialNotice
        permission = permissionService.isGranted() ? .ready : .required
        activationObserver = activationNotifications.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        let initialCredentialRevision = beginCredentialOperation()
        credentialTask = Task { [weak self, client, processor, settings] in
            await client.setStatusHandler { [weak self] event in
                Task { @MainActor in
                    guard let self,
                          event.credentialRevision == self.credentialRevision,
                          event.sequence > self.lastStatusSequence else { return }
                    self.lastStatusSequence = event.sequence
                    self.connection = event.status
                    guard let pairing = self.pairing else { return }
                    Task { await pairing.refreshStatus(capabilityAvailable: event.status == .connected) }
                }
            }
            await client.setResultHandler { [weak self] result in
                Task { @MainActor in
                    self?.lastResult = "\(result.status.rawValue): \(result.reason.rawValue)"
                    self?.refreshPermission()
                }
            }
            await client.setPairingHandler { [weak self] message in
                await self?.receivePairing(message)
            }
            await processor.setRemoteEnabled(settings.remoteEnabled)
            guard let self, initialCredentialRevision == self.credentialRevision,
                  !Task.isCancelled else { return }
            await self.publishState()
            guard initialCredentialRevision == self.credentialRevision, !Task.isCancelled else { return }
            self.connect(credentialRevision: initialCredentialRevision)
        }
    }

    deinit {
        credentialTask?.cancel()
        if let activationObserver { activationNotifications.removeObserver(activationObserver) }
    }

    var remoteToggleEnabled: Bool { true }

    @discardableResult
    func reconnect() -> Task<Void, Never> {
        let revision = beginCredentialOperation()
        return connect(credentialRevision: revision)
    }

    func publishState() async {
        await client.updateAdvertisedState(MacState(remoteEnabled: settings.remoteEnabled, permission: permission))
    }

    func setPersistedRemoteEnabled(_ enabled: Bool) {
        Task {
            await processor.setRemoteEnabled(enabled)
            settings.remoteEnabled = enabled
            await publishState()
        }
    }

    func refreshPermission() {
        permission = permissionService.isGranted() ? .ready : .required
        Task { await publishState() }
    }

    func requestPermission() {
        _ = permissionService.requestFromUserAction()
        refreshPermission()
    }

    func beginPairing() {
        guard let pairing else { return }
        Task { await pairing.beginPairing() }
    }

    func confirmReplacement() {
        guard let pairing else { return }
        Task {
            await pairing.beginPairing()
            await pairing.confirmReplacement()
        }
    }

    @discardableResult
    func saveToken(_ token: String) -> Task<Void, Never> {
        let revision = beginCredentialOperation()
        do {
            try settings.saveMacToken(token)
            credentialEligible = true
            notice = "Token saved."
            return connect(credentialRevision: revision)
        }
        catch {
            credentialEligible = false
            notice = settings.storageError
            let task = Task { _ = await client.clearConfigurationAndStop(credentialRevision: revision) }
            credentialTask = task
            return task
        }
    }

    @discardableResult
    func clearToken() -> Task<Void, Never> {
        let revision = beginCredentialOperation()
        credentialEligible = false
        var persistenceError: String?
        do { try settings.clearMacToken() }
        catch { persistenceError = settings.storageError }

        let task = Task {
            guard revision == credentialRevision, !Task.isCancelled else { return }
            let cleared = await client.clearConfigurationAndStop(credentialRevision: revision)
            guard cleared else { return }
            guard revision == credentialRevision, !Task.isCancelled else { return }
            notice = persistenceError ?? "Token cleared."
        }
        credentialTask = task
        return task
    }

    private func beginCredentialOperation() -> UInt64 {
        credentialRevision &+= 1
        return credentialRevision
    }

    private func receivePairing(_ message: WireMessage) async {
        guard let pairing else { return }
        let previousState = pairing.state
        await pairing.receive(message)
        if case .pairStatus(let status) = message,
           previousState == .checkingStatus, pairing.state == .ready {
            pairingAction = PairingActionPresentation(status: status)
        }
    }

    @discardableResult
    private func connect(credentialRevision revision: UInt64) -> Task<Void, Never> {
        let task = Task {
            do { try Task.checkCancellation() }
            catch { return }
            guard revision == credentialRevision else { return }
            guard credentialEligible else {
                await client.clearConfigurationAndStop(credentialRevision: revision)
                return
            }
            let token: String
            do {
                guard let storedToken = try settings.macToken(), !storedToken.isEmpty else {
                    guard revision == credentialRevision, credentialEligible else { return }
                    notice = "Save MAC_TOKEN in Settings before connecting."
                    return
                }
                token = storedToken
            } catch {
                guard revision == credentialRevision, !Task.isCancelled else { return }
                credentialEligible = false
                await client.clearConfigurationAndStop(credentialRevision: revision)
                guard revision == credentialRevision, !Task.isCancelled else { return }
                notice = settings.storageError
                return
            }
            guard revision == credentialRevision, credentialEligible else { return }
            do {
                let relayURL = try RelayEndpoint.validated(settings.relayURLString, allowLocalSimulator: false)
                let pairing = PairingController(transport: client, relayURL: relayURL)
                self.pairing = pairing
                self.pairingAction = PairingActionPresentation(status: nil)
                let configured = try await client.configure(urlString: settings.relayURLString,
                                                            token: token,
                                                            allowLocalSimulator: false,
                                                            credentialRevision: revision)
                guard configured else { return }
                try Task.checkCancellation()
                guard revision == credentialRevision, credentialEligible else { return }
                await client.start(credentialRevision: revision)
            } catch {
                guard revision == credentialRevision, !Task.isCancelled else { return }
                notice = "Connection settings are invalid: \(error.localizedDescription)"
            }
        }
        credentialTask = task
        return task
    }
}
