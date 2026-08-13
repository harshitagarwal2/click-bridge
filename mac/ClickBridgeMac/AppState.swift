import Foundation
import AppKit

enum ConnectionActionIssue: Error, LocalizedError, Equatable, Sendable {
    case pairingInProgress
    case invalidRelayURL
    case invalidReplacementToken
    case missingToken
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .pairingInProgress:
            return "Finish or cancel phone pairing before changing connection settings."
        case .invalidRelayURL:
            return ConnectionSettingsValidationError.invalidRelayURL.localizedDescription
        case .invalidReplacementToken:
            return ConnectionSettingsValidationError.invalidReplacementToken.localizedDescription
        case .missingToken:
            return "Enter a Mac token before connecting."
        case .keychainUnavailable:
            return "The saved connection is unavailable. Try again."
        }
    }
}

enum ConnectionActionOutcome: Equatable, Sendable {
    case accepted
    case rejected(ConnectionActionIssue)
}

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
    private struct PreparedConnection: Sendable {
        let record: StoredConnection
        let relayURL: URL
    }

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
    private var cancelCredentialTask: (() -> Void)?
    private var lastStatusSequence: UInt64 = 0
#if DEBUG
    private var forcedBlockedConnectionStateForTesting: PairingController.State?
#endif

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
        let bootstrapTask = Task { [weak self, client, processor, settings] in
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
            await processor.setRemoteEnabled(settings.remoteEnabled)
            guard let self, initialCredentialRevision == self.credentialRevision,
                  !Task.isCancelled else { return }
            await self.publishState()
            guard initialCredentialRevision == self.credentialRevision, !Task.isCancelled else { return }
            await self.connectPersistedConfiguration(credentialRevision: initialCredentialRevision)
        }
        cancelCredentialTask = { bootstrapTask.cancel() }
    }

    deinit {
        cancelCredentialTask?()
        if let activationObserver { activationNotifications.removeObserver(activationObserver) }
    }

    var remoteToggleEnabled: Bool { true }

    static func blocksConnectionChanges(in state: PairingController.State) -> Bool {
        switch state {
        case .creating, .invitation, .approval, .approving, .denying, .cancelling, .cancelFailed:
            return true
        default:
            return false
        }
    }

#if DEBUG
    var credentialRevisionForTesting: UInt64 { credentialRevision }
    var lastStatusSequenceForTesting: UInt64 { lastStatusSequence }

    func forceBlockedConnectionStateForTesting(_ state: PairingController.State) {
        precondition(Self.blocksConnectionChanges(in: state))
        forcedBlockedConnectionStateForTesting = state
    }

    func clearBlockedConnectionStateForTesting() {
        forcedBlockedConnectionStateForTesting = nil
    }
#endif

    @discardableResult
    func reconnect() -> Task<ConnectionActionOutcome, Never> {
        if connectionChangesAreBlocked {
            return rejectedTask(.pairingInProgress)
        }
        let prepared: PreparedConnection
        do {
            prepared = try preparedStoredConnection()
        } catch let issue as ConnectionActionIssue {
            return rejectedTask(issue, detail: storageDetail(for: issue))
        } catch {
            return rejectedTask(.keychainUnavailable, detail: settings.storageError)
        }
        let revision = beginCredentialOperation()
        notice = "Reconnecting…"
        return connect(prepared, credentialRevision: revision)
    }

    @discardableResult
    func applyConnectionSettings(
        relayURLString: String,
        replacementMacToken: String
    ) -> Task<ConnectionActionOutcome, Never> {
        if connectionChangesAreBlocked {
            return rejectedTask(.pairingInProgress)
        }

        let validated: ValidatedConnectionSettings
        do {
            validated = try ConnectionSettingsValidator.validate(
                relayURLString: relayURLString,
                replacementMacToken: replacementMacToken
            )
        } catch ConnectionSettingsValidationError.invalidRelayURL {
            return rejectedTask(.invalidRelayURL)
        } catch ConnectionSettingsValidationError.invalidReplacementToken {
            return rejectedTask(.invalidReplacementToken)
        } catch {
            return rejectedTask(.invalidRelayURL)
        }

        let resolvedToken: String
        switch validated.tokenInput {
        case .replacement(let token):
            resolvedToken = token
        case .reuseStored:
            let stored: StoredConnection
            do {
                guard let connection = try settings.connection() else {
                    return rejectedTask(.missingToken)
                }
                stored = connection
            } catch {
                return rejectedTask(.keychainUnavailable, detail: settings.storageError)
            }
            do {
                let resolved = try ConnectionSettingsValidator.validate(
                    relayURLString: validated.relayURLString,
                    replacementMacToken: stored.macToken
                )
                guard case .replacement(let token) = resolved.tokenInput else {
                    return rejectedTask(.missingToken)
                }
                resolvedToken = token
            } catch ConnectionSettingsValidationError.invalidReplacementToken {
                return rejectedTask(.invalidReplacementToken)
            } catch {
                return rejectedTask(.invalidRelayURL)
            }
        }

        let record = StoredConnection(
            version: StoredConnection.currentVersion,
            relayURLString: validated.relayURLString,
            macToken: resolvedToken
        )
        do {
            try settings.saveConnection(record)
        } catch {
            return rejectedTask(.keychainUnavailable, detail: settings.storageError)
        }

        let revision = beginCredentialOperation()
        notice = "Settings saved. Reconnecting…"
        return connect(
            PreparedConnection(record: record, relayURL: validated.relayURL),
            credentialRevision: revision
        )
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
    func saveToken(_ token: String) -> Task<ConnectionActionOutcome, Never> {
        applyConnectionSettings(
            relayURLString: settings.relayURLString,
            replacementMacToken: token
        )
    }

    @discardableResult
    func clearToken() -> Task<Void, Never> {
        let revision = beginCredentialOperation()
        var persistenceError: String?
        do { try settings.clearConnection() }
        catch { persistenceError = settings.storageError }

        let task = Task {
            guard revision == credentialRevision, !Task.isCancelled else { return }
            let cleared = await client.clearConfigurationAndStop(credentialRevision: revision)
            guard cleared else { return }
            guard revision == credentialRevision, !Task.isCancelled else { return }
            notice = persistenceError ?? "Token cleared."
        }
        return track(task)
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
        guard let pairing else { return }
        await pairing.refreshStatus(capabilityAvailable: event.status == .connected)
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

    private var connectionChangesAreBlocked: Bool {
#if DEBUG
        if let forcedBlockedConnectionStateForTesting {
            return Self.blocksConnectionChanges(in: forcedBlockedConnectionStateForTesting)
        }
#endif
        guard let pairing else { return false }
        return Self.blocksConnectionChanges(in: pairing.state)
    }

    private func preparedStoredConnection() throws -> PreparedConnection {
        guard let stored = try settings.connection() else {
            throw ConnectionActionIssue.missingToken
        }
        let validated: ValidatedConnectionSettings
        do {
            validated = try ConnectionSettingsValidator.validate(
                relayURLString: stored.relayURLString,
                replacementMacToken: stored.macToken
            )
        } catch ConnectionSettingsValidationError.invalidRelayURL {
            throw ConnectionActionIssue.invalidRelayURL
        } catch ConnectionSettingsValidationError.invalidReplacementToken {
            throw ConnectionActionIssue.invalidReplacementToken
        }
        guard case .replacement(let token) = validated.tokenInput else {
            throw ConnectionActionIssue.missingToken
        }
        return PreparedConnection(
            record: StoredConnection(
                version: StoredConnection.currentVersion,
                relayURLString: validated.relayURLString,
                macToken: token
            ),
            relayURL: validated.relayURL
        )
    }

    private func connectPersistedConfiguration(credentialRevision revision: UInt64) async {
        let prepared: PreparedConnection
        do {
            prepared = try preparedStoredConnection()
        } catch let issue as ConnectionActionIssue {
            if notice == nil { notice = storageDetail(for: issue) ?? issue.localizedDescription }
            return
        } catch {
            if notice == nil { notice = settings.storageError ?? ConnectionActionIssue.keychainUnavailable.localizedDescription }
            return
        }
        _ = await configure(prepared, credentialRevision: revision)
    }

    @discardableResult
    private func connect(
        _ prepared: PreparedConnection,
        credentialRevision revision: UInt64
    ) -> Task<ConnectionActionOutcome, Never> {
        let task = Task { [weak self] in
            guard let self else { return ConnectionActionOutcome.accepted }
            return await self.configure(prepared, credentialRevision: revision)
        }
        return track(task)
    }

    private func configure(
        _ prepared: PreparedConnection,
        credentialRevision revision: UInt64
    ) async -> ConnectionActionOutcome {
        guard revision == credentialRevision, !Task.isCancelled else { return .accepted }
        do {
            let configured = try await client.configure(
                urlString: prepared.record.relayURLString,
                token: prepared.record.macToken,
                allowLocalSimulator: false,
                credentialRevision: revision
            )
            guard configured, revision == credentialRevision, !Task.isCancelled else { return .accepted }
            pairing = PairingController(transport: client, relayURL: prepared.relayURL)
            pairingAction = PairingActionPresentation(status: nil)
            await client.start(credentialRevision: revision)
        } catch {
            // The pair was validated before this task and, for Apply, is already
            // authoritative. A later transport failure must not roll it back or
            // report a false successful connection.
        }
        return .accepted
    }

    private func rejectedTask(
        _ issue: ConnectionActionIssue,
        detail: String? = nil
    ) -> Task<ConnectionActionOutcome, Never> {
        notice = detail ?? issue.localizedDescription
        return Task { .rejected(issue) }
    }

    private func storageDetail(for issue: ConnectionActionIssue) -> String? {
        issue == .keychainUnavailable ? settings.storageError : nil
    }

    @discardableResult
    private func track<Success>(_ task: Task<Success, Never>) -> Task<Success, Never> {
        cancelCredentialTask = { task.cancel() }
        return task
    }
}
