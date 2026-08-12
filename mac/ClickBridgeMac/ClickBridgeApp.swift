import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var connection: RelayClient.Status = .disconnected
    @Published var permission: PermissionState = .unknown
    @Published var lastResult: String = "—"

    let settings: SettingsStore
    let permissionService = PostEventPermissionService()

    /// The bridge between main-actor UI state and the non-isolated actor that
    /// decides whether to click. See SharedMacState for why this is not an
    /// `await` into the main actor.
    private let shared = SharedMacState()

    private let processor: ActionProcessor
    private let client: RelayClient
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings

        let permissionService = PostEventPermissionService()
        self.shared.setRemoteEnabled(settings.remoteEnabled)
        self.shared.setPermission(permissionService.permissionState)

        self.processor = ActionProcessor(
            poster: MacInputExecutor(),
            permission: permissionService,
            toggle: shared                      // synchronous, thread-safe
        )
        self.client = RelayClient(processor: processor, ingress: .oci)

        // Keep the shared snapshot in step with the menu-bar toggle.
        settings.$remoteEnabled
            .dropFirst()
            .sink { [weak self] value in
                guard let self else { return }
                self.shared.setRemoteEnabled(value)
                Task { await self.publish() }
            }
            .store(in: &cancellables)

        refreshPermission()
        Task { await configureClient() }
    }

    private func configureClient() async {
        await client.configure(url: settings.relayURL, token: settings.macToken)

        await client.setOnStatus { [weak self] status in
            Task { @MainActor in self?.connection = status }
        }
        // Captures only the Sendable box — never the main-actor AppState.
        let shared = self.shared
        await client.setStateProvider { shared.snapshot }
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
        shared.setPermission(next)
        guard next != permission else { return }
        permission = next
        Task { await publish() }
    }

    func diagnostics() async -> (down: Int, up: Int) {
        await processor.postCounts()
    }
}

// Small async setters so the actor's closures stay isolated to it.
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
            MenuContent(app: app, settings: app.settings)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(app: app, settings: app.settings)
        }
    }
}

/// Observes the SettingsStore directly. `AppState.settings` is a plain `let`,
/// so `$app.settings.remoteEnabled` is not a writable key path — and even if it
/// were, a change inside the store would not redraw a view observing AppState.
struct MenuContent: View {
    @ObservedObject var app: AppState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Text(connectionLabel)
        Text(permissionLabel)
        Divider()

        Toggle("Remote control enabled", isOn: $settings.remoteEnabled)

        Divider()
        Text("Last: \(app.lastResult)")

        Divider()
        Button("Reconnect") { app.reconnect() }
        if app.permission != .ready {
            Button("Grant Input Permission…") { app.requestPermission() }
        }
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
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
    @ObservedObject var settings: SettingsStore
    @State private var token = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $settings.relayURLString,
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
                        settings.macToken = nil
                        note = "Token cleared."
                    }
                }
                Text(settings.hasToken ? "A token is stored." : "No token stored.")
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
        settings.macToken = value
        token = ""
        note = "Token saved."
        app.reconnect()
    }
}
