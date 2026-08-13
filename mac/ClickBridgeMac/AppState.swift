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
    @Published private(set) var phoneManagement: PhoneManagementController?
    @Published private(set) var pairingAction = PairingActionPresentation(status: nil)
    @Published private(set) var relaySetupRetryAvailable = false

    let settings: SettingsStore
    private let client: RelayClient
    private let processor: ActionProcessor
    private let permissionService: PostEventPermissionService
    private let activationNotifications: NotificationCenter
    private let enroll: @Sendable () async throws -> DesktopEnrollment
    private var activationObserver: NSObjectProtocol?
    private var credentialRevision: UInt64 = 0
    private var credentialTask: Task<Void, Never>?
    private var credentialEligible = true
    private var automaticEnrollmentAttempted = false
    private var lastStatusSequence: UInt64 = 0

    init(settings: SettingsStore, client: RelayClient, processor: ActionProcessor,
         permissionService: PostEventPermissionService,
         activationNotifications: NotificationCenter = .default,
         initialNotice: String? = nil,
         enroll: @escaping @Sendable () async throws -> DesktopEnrollment = {
             try await SessionEnrollmentService.enroll()
         }) {
        self.settings = settings
        self.client = client
        self.processor = processor
        self.permissionService = permissionService
        self.activationNotifications = activationNotifications
        self.enroll = enroll
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
                    await self?.handleStatusEvent(event)
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
            await client.setPhoneManagementHandler { [weak self] message in
                await self?.phoneManagement?.receive(message)
            }
            await processor.setRemoteEnabled(settings.remoteEnabled)
            guard let self, initialCredentialRevision == self.credentialRevision,
                  !Task.isCancelled else { return }
            await self.publishState()
            guard initialCredentialRevision == self.credentialRevision, !Task.isCancelled else { return }
            self.connect(credentialRevision: initialCredentialRevision, allowAutomaticEnrollment: true)
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

    @discardableResult
    func retryRelaySetup() -> Task<Void, Never> {
        let revision = beginCredentialOperation()
        credentialEligible = true
        relaySetupRetryAvailable = false
        return enrollAndConnect(credentialRevision: revision, automaticRecoveryUsed: true)
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
            notice = "Relay enrollment saved."
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
            notice = persistenceError ?? "Relay enrollment cleared."
        }
        credentialTask = task
        return task
    }

    private func beginCredentialOperation() -> UInt64 {
        credentialRevision &+= 1
        return credentialRevision
    }

    func handleStatusEvent(_ event: RelayClient.StatusEvent) async {
        guard event.credentialRevision == credentialRevision,
              event.sequence > lastStatusSequence else { return }
        lastStatusSequence = event.sequence
        connection = event.status
        if event.cause == .authenticationRejected {
            recoverAfterAuthenticationRejection()
            return
        }
        if event.status == .connected {
            relaySetupRetryAvailable = false
            do {
                try settings.clearAutomaticRecoveryMarker()
            } catch {
                notice = settings.storageError
            }
        }
        if let pairing {
            await pairing.refreshStatus(capabilityAvailable: event.status == .connected)
        }
        guard event.credentialRevision == credentialRevision,
              event.sequence == lastStatusSequence else { return }
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
    private func connect(
        credentialRevision revision: UInt64,
        allowAutomaticEnrollment: Bool = false
    ) -> Task<Void, Never> {
        let task = Task {
            do { try Task.checkCancellation() }
            catch { return }
            guard revision == credentialRevision else { return }
            guard credentialEligible else {
                await client.clearConfigurationAndStop(credentialRevision: revision)
                return
            }
            let record: DesktopEnrollmentRecord?
            do {
                record = try settings.enrollment()
            } catch {
                guard revision == credentialRevision, !Task.isCancelled else { return }
                credentialEligible = false
                await client.clearConfigurationAndStop(credentialRevision: revision)
                guard revision == credentialRevision, !Task.isCancelled else { return }
                notice = settings.storageError
                return
            }
            if let record {
                await configureAndStart(record, credentialRevision: revision)
                return
            }

            guard allowAutomaticEnrollment, !automaticEnrollmentAttempted else {
                relaySetupRetryAvailable = true
                notice = "Relay setup needs attention. Retry setup to create a new private session."
                await client.clearConfigurationAndStop(credentialRevision: revision)
                return
            }
            automaticEnrollmentAttempted = true
            await performEnrollment(
                credentialRevision: revision,
                automaticRecoveryUsed: settings.hasPartialLegacyEnrollment
            )
        }
        credentialTask = task
        return task
    }

    private func enrollAndConnect(
        credentialRevision revision: UInt64,
        automaticRecoveryUsed: Bool
    ) -> Task<Void, Never> {
        let task = Task {
            await performEnrollment(
                credentialRevision: revision,
                automaticRecoveryUsed: automaticRecoveryUsed
            )
        }
        credentialTask = task
        return task
    }

    private func performEnrollment(
        credentialRevision revision: UInt64,
        automaticRecoveryUsed: Bool
    ) async {
        notice = automaticRecoveryUsed
            ? "Replacing the private relay session…"
            : "Creating your private relay session…"
        do {
            let enrollment = try await enroll()
            guard revision == credentialRevision, credentialEligible, !Task.isCancelled else { return }
            let record = try settings.saveEnrollment(
                enrollment,
                automaticRecoveryUsed: automaticRecoveryUsed
            )
            guard revision == credentialRevision, credentialEligible, !Task.isCancelled else { return }
            notice = automaticRecoveryUsed
                ? "Private relay session replaced."
                : "Private relay session created."
            relaySetupRetryAvailable = false
            await configureAndStart(record, credentialRevision: revision)
        } catch {
            guard revision == credentialRevision, !Task.isCancelled else { return }
            if settings.storageError != nil {
                credentialEligible = false
            }
            await client.clearConfigurationAndStop(credentialRevision: revision)
            guard revision == credentialRevision, !Task.isCancelled else { return }
            relaySetupRetryAvailable = true
            notice = settings.storageError ?? error.localizedDescription
        }
    }

    private func configureAndStart(
        _ record: DesktopEnrollmentRecord,
        credentialRevision revision: UInt64
    ) async {
        guard revision == credentialRevision, credentialEligible else { return }
        do {
            let relayURL = try RelayEndpoint.validated(record.relayURL, allowLocalSimulator: false)
            let pairing = PairingController(transport: client, relayURL: relayURL)
            self.pairing = pairing
            phoneManagement = PhoneManagementController(transport: client)
            pairingAction = PairingActionPresentation(status: nil)
            let configured = try await client.configure(
                urlString: record.relayURL,
                token: record.macToken,
                allowLocalSimulator: false,
                credentialRevision: revision
            )
            guard configured else { return }
            try Task.checkCancellation()
            guard revision == credentialRevision, credentialEligible else { return }
            await client.start(credentialRevision: revision)
        } catch {
            guard revision == credentialRevision, !Task.isCancelled else { return }
            notice = "Saved relay enrollment is invalid: \(error.localizedDescription)"
            relaySetupRetryAvailable = true
        }
    }

    private func recoverAfterAuthenticationRejection() {
        let record: DesktopEnrollmentRecord
        do {
            guard let stored = try settings.enrollment() else {
                relaySetupRetryAvailable = true
                notice = "Relay authentication failed. Retry setup to create a new private session."
                return
            }
            record = stored
        } catch {
            credentialEligible = false
            relaySetupRetryAvailable = false
            notice = settings.storageError
            return
        }

        guard !record.automaticRecoveryUsed else {
            relaySetupRetryAvailable = true
            notice = "Automatic relay recovery was rejected. Retry setup when you are ready."
            return
        }

        let revision = beginCredentialOperation()
        relaySetupRetryAvailable = false
        _ = enrollAndConnect(credentialRevision: revision, automaticRecoveryUsed: true)
    }
}
