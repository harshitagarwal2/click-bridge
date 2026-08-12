import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var connection: RelayClient.Status = .disconnected
    @Published var permission: PermissionState = .unknown
    @Published var lastResult: String = "—"
    @Published var lastIngress: ActionIngress?

    let settings: SettingsStore
    let permissionService = PostEventPermissionService()
    private let processor: ActionProcessor
    private let client: RelayClient
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings

        let permissionService = PostEventPermissionService()
        let toggle = ToggleReader(settings: settings)
        self.processor = ActionProcessor(
            poster: MacInputExecutor(),
            permission: permissionService,
            toggle: toggle
        )
        self.client = RelayClient(processor: processor, ingress: .oci)

        settings.$remoteEnabled
            .dropFirst()
            .sink { [weak self] _ in Task { await self?.publish() } }
            .store(in: &cancellables)

        Task { await configureClient() }
        refreshPermission()
    }

    private func configureClient() async {
        await client.configure(url: settings.relayURL, token: settings.macToken)

        await client.setOnStatus { [weak self] status in
            Task { @MainActor in self?.connection = status }
        }
        await client.setStateProvider { [weak self] in
            guard let self else { return (false, .unknown) }
            return (self.settings.remoteEnabled, self.permissionService.permissionState)
        }
    }

    func start() {
        Task {
            await configureClient()
            await client.start()
        }
    }

    func reconnect() {
        Task {
            await configureClient()
            await client.reconnect()
        }
    }

    func publish() async {
        await client.publishState()
    }

    /// Prompts. Only ever called from the explicit menu action.
    func requestPermission() {
        _ = permissionService.requestFromUserAction()
        refreshPermission()
    }

    func refreshPermission() {
        let next = permissionService.permissionState
        if next != permission {
            permission = next
            Task { await publish() }
        }
    }

    func diagnostics() async -> (down: Int, up: Int) {
        await processor.postCounts()
    }
}

private struct ToggleReader: RemoteToggleReading {
    let settings: SettingsStore
    func isRemoteEnabled() -> Bool {
        MainActor.assumeIsolated { settings.remoteEnabled }
    }
}

// Small async setters so the actor's closures stay isolated.
extension RelayClient {
    func setOnStatus(_ fn: @escaping @Sendable (Status) -> Void) { onStatus = fn }
    func setStateProvider(
        _ fn: @escaping @Sendable () -> (remoteEnabled: Bool, permission: PermissionState)
    ) { stateProvider = fn }
}

@main
struct ClickBridgeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        MenuBarExtra("Click Bridge", systemImage: "cursorarrow.click") {
            Text(connectionLabel)
            Text(permissionLabel)
            Divider()

            Toggle("Remote control enabled", isOn: $app.settings.remoteEnabled)

            Divider()
            Text("Last: \(app.lastResult)")

            Divider()
            Button("Reconnect") { app.reconnect() }
            if app.permission != .ready {
                Button("Grant Input Permission…") { app.requestPermission() }
            }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(app: app)
        }
    }

    private var connectionLabel: String {
        switch app.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        }
    }

    private var permissionLabel: String {
        app.permission == .ready ? "Input permission: ready" : "Input permission: required"
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @State private var token = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $app.settings.relayURLString,
                          prompt: Text("wss://your-host/ws"))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Mac token") {
                // Never echoes the stored token back into the field.
                SecureField("Paste MAC_TOKEN", text: $token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { save() }
                        .disabled(token.count != 64)
                    Button("Clear") {
                        app.settings.macToken = nil
                        note = "Token cleared."
                    }
                }
                Text(app.settings.hasToken ? "A token is stored." : "No token stored.")
                    .font(.caption).foregroundStyle(.secondary)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Input permission is granted under System Settings → Privacy & Security → Accessibility. Click Bridge requests only PostEvent, not full Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { app.refreshPermission() }
    }

    private func save() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            note = "Token must be 64 lowercase hex characters."
            return
        }
        app.settings.macToken = value
        token = ""
        note = "Token saved."
        app.reconnect()
    }
}
