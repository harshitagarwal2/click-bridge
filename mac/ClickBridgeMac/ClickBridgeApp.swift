import SwiftUI

@main
struct ClickBridgeApp: App {
    @StateObject private var app: AppState

    @MainActor
    init() {
        let settings: SettingsStore
        let startupNotice: String?
        do {
            settings = try SettingsStore()
            startupNotice = nil
        } catch {
            settings = SettingsStore(unavailableSecrets: UnavailableSecretStore(failure: error), failure: error)
            startupNotice = "Keychain is unavailable: \(error.localizedDescription)"
        }
        let permission = PostEventPermissionService()
        let processor = ActionProcessor(poster: MacInputExecutor(), permission: permission)
        let client = RelayClient(actionSink: processor, diagnostics: processor)
        _app = StateObject(wrappedValue: AppState(settings: settings,
                                                  client: client,
                                                  processor: processor,
                                                  permissionService: permission,
                                                  initialNotice: startupNotice))
    }

    var body: some Scene {
        MenuBarExtra("Click Bridge", systemImage: "cursorarrow.click") {
            Group {
            Text(connectionLabel)
            Text(app.permission == .ready ? "Input permission: ready" : "Input permission: required")
            Divider()
            Toggle("Remote control enabled", isOn: Binding(
                get: { app.settings.remoteEnabled },
                set: { app.setPersistedRemoteEnabled($0) }
            ))
            .disabled(!app.remoteToggleEnabled)
            Divider()
            Text("Last: \(app.lastResult)")
            if let notice = app.notice { Text(notice).font(.caption) }
            Divider()
            Button("Reconnect") { app.reconnect() }
            if app.permission != .ready {
                Button("Grant Input Permission…") { app.requestPermission() }
            }
            if #available(macOS 14.0, *) {
                SettingsLink { Text("Settings…") }
            } else {
                Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .onAppear { app.refreshPermission() }
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView(app: app) }
    }

    private var connectionLabel: String {
        switch app.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @State private var token = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: Binding(
                    get: { app.settings.relayURLString },
                    set: { app.settings.relayURLString = $0 }
                ),
                          prompt: Text("wss://your-host/ws"))
            }
            Section("Mac token") {
                SecureField("Paste MAC_TOKEN", text: $token)
                HStack {
                    Button("Save") { save() }.disabled(!validToken)
                    Button("Clear") { app.clearToken() }
                }
                Text(app.settings.hasToken ? "A token is stored." : "No token stored.")
                    .font(.caption)
                if let error = app.settings.storageError { Text(error).font(.caption) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var normalizedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var validToken: Bool { normalizedToken.count == 64 && normalizedToken.allSatisfy(\.isHexDigit) }
    private func save() { app.saveToken(normalizedToken); token = "" }
}
