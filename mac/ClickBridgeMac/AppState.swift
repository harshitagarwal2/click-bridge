import Foundation

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

    init(settings: SettingsStore, client: RelayClient, processor: ActionProcessor,
         permissionService: PostEventPermissionService, initialNotice: String? = nil) {
        self.settings = settings
        self.client = client
        self.processor = processor
        self.permissionService = permissionService
        notice = initialNotice
        permission = permissionService.isGranted() ? .ready : .required
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
