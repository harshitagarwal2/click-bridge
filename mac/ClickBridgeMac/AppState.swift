import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var connection: RelayClient.Status = .disconnected
    @Published private(set) var permission: PermissionState = .unknown
    @Published private(set) var lastResult = "—"
    @Published var notice: String?

    let settings: SettingsStore
    private let client: RelayClient
    private let processor: ActionProcessor
    private let permissionService: PostEventPermissionService
    private let activationNotifications: NotificationCenter
    private var activationObserver: NSObjectProtocol?

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
        Task { [weak self, client, processor, settings] in
            await client.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.connection = status }
            }
            await client.setResultHandler { [weak self] result in
                Task { @MainActor in
                    self?.lastResult = "\(result.status.rawValue): \(result.reason.rawValue)"
                    self?.refreshPermission()
                }
            }
            await processor.setRemoteEnabled(settings.remoteEnabled)
            await self?.publishState()
            self?.reconnect()
        }
    }

    deinit {
        if let activationObserver { activationNotifications.removeObserver(activationObserver) }
    }

    var remoteToggleEnabled: Bool { true }

    func start() { reconnect() }

    func reconnect() {
        Task {
            do {
                guard let token = try settings.macToken(), !token.isEmpty else {
                    notice = "Save MAC_TOKEN in Settings before connecting."
                    return
                }
                try await client.configure(urlString: settings.relayURLString,
                                           token: token,
                                           allowLocalSimulator: false)
                await client.start()
            } catch {
                notice = "Connection settings are invalid: \(error.localizedDescription)"
            }
        }
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

    func saveToken(_ token: String) {
        do { try settings.saveMacToken(token); notice = "Token saved."; reconnect() }
        catch { notice = settings.storageError }
    }

    func clearToken() {
        do { try settings.clearMacToken(); notice = "Token cleared." }
        catch { notice = settings.storageError }
    }
}
