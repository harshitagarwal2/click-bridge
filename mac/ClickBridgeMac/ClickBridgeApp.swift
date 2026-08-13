import AppKit
import SwiftUI

@main
struct ClickBridgeApp: App {
    @StateObject private var app: AppState

    @MainActor
    init() {
        let settings: SettingsStore
        let startupNotice: String?
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let isolation = SecretStoreUnavailable(message: "Keychain access is disabled for tests.")
            settings = SettingsStore(
                unavailableSecrets: UnavailableSecretStore(failure: isolation),
                failure: isolation
            )
            startupNotice = nil
        } else {
            do {
                settings = try SettingsStore()
                startupNotice = nil
            } catch {
                settings = SettingsStore(
                    unavailableSecrets: UnavailableSecretStore(failure: error),
                    failure: error
                )
                startupNotice = "Keychain is unavailable. Open Settings to reconnect."
            }
        }

        let permission = PostEventPermissionService()
        let processor = ActionProcessor(poster: MacInputExecutor(), permission: permission)
        let client = RelayClient(actionSink: processor, diagnostics: processor)
        _app = StateObject(wrappedValue: AppState(
            settings: settings,
            client: client,
            processor: processor,
            permissionService: permission,
            initialNotice: startupNotice
        ))
    }

    var body: some Scene {
        MenuBarExtra("Click Bridge", systemImage: "cursorarrow.click") {
            MenuBarContent(app: app)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(app: app)
        }
        .defaultSize(width: 600, height: 560)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var app: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(SettingsReadinessPresentation.relay(app.connection).value)
        Text("Input permission: \(app.permission == .ready ? "ready" : "required")")
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
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .onAppear { app.refreshPermission() }
    }
}
