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
    @State private var showingReplacementConfirmation = false

    var body: some View {
        Form {
            Section("Relay") {
                Text("Relay setup is managed automatically for this Mac.")
                    .foregroundStyle(.secondary)
                if app.relaySetupRetryAvailable {
                    Button("Retry Relay Setup") { app.retryRelaySetup() }
                }
                if let error = app.settings.storageError {
                    Text(error).font(.caption)
                }
            }

            Section("Phone") {
                if let pairing = app.pairing {
                    PairingSettingsView(controller: pairing)
                } else {
                    Text("Connect this Mac to the relay before pairing a phone.")
                        .foregroundStyle(.secondary)
                }
                Button(app.pairingAction.title) {
                    if app.pairingAction.requiresReplacementConfirmation {
                        showingReplacementConfirmation = true
                    } else {
                        app.beginPairing()
                    }
                }
                .disabled(app.pairing?.state != .ready)
            }

            Section("Paired Phones") {
                if let phoneManagement = app.phoneManagement {
                    PhoneManagementView(controller: phoneManagement)
                } else {
                    Text("Connect this Mac to the relay to manage paired phones.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "Replace the paired phone?",
            isPresented: $showingReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Phone", role: .destructive) { app.confirmReplacement() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The currently enrolled phone will stop working after the new phone is approved.")
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct PairingSettingsView: View {
    @ObservedObject var controller: PairingController

    var body: some View {
        Group {
            switch controller.state {
            case .unavailable:
                Text("Pairing is unavailable on this connection.")
            case .checkingStatus:
                ProgressView("Checking phone enrollment…")
            case .ready:
                Text("Ready to pair a phone.")
                    .foregroundStyle(.secondary)
            case .replacementConfirmation:
                Text("Confirm phone replacement to continue.")
            case .creating:
                ProgressView("Creating invitation…")
            case .invitation(let invitation):
                PairingInvitationView(invitation: invitation,
                                      copyWebInvitation: {
                                          controller.copyWebInvitation(invitation)
                                      },
                                      cancel: { Task { await controller.cancel() } },
                                      refreshExpiry: { await controller.refreshExpiry() })
            case .approval:
                Text("Review the confirmation code.")
            case .approving:
                ProgressView("Approving phone…")
            case .denying:
                ProgressView("Denying phone…")
            case .cancelling:
                ProgressView("Cancelling invitation…")
            case .cancelFailed:
                PairingRecoveryView(message: "The invitation could not be cancelled safely.",
                                    action: controller.recoveryAction,
                                    recover: { Task { await controller.regenerate() } })
            case .completed:
                Text("Phone paired.")
            case .denied:
                PairingRecoveryView(message: "Phone pairing denied.",
                                    action: controller.recoveryAction,
                                    recover: { Task { await controller.regenerate() } })
            case .expired:
                PairingRecoveryView(message: "The pairing invitation expired.",
                                    action: controller.recoveryAction,
                                    recover: { Task { await controller.regenerate() } })
            case .failed:
                PairingRecoveryView(message: "Pairing failed.",
                                    action: controller.recoveryAction,
                                    recover: { Task { await controller.regenerate() } })
            }
        }
        .onAppear { Task { await controller.refreshExpiry() } }
        .sheet(isPresented: approvalPresented) {
            if let approval {
                PairingApprovalView(approval: approval,
                                    approve: { Task { await controller.approve() } },
                                    deny: { Task { await controller.deny() } },
                                    refreshExpiry: { await controller.refreshExpiry() })
                    .padding(24)
            }
        }
    }

    private var approval: PairingController.Approval? {
        guard case .approval(let approval) = controller.state else { return nil }
        return approval
    }

    private var approvalPresented: Binding<Bool> {
        Binding(
            get: { approval != nil },
            set: { presented in
                if !presented, approval != nil { Task { await controller.deny() } }
            }
        )
    }
}

private struct PairingInvitationView: View {
    let invitation: PairingController.Invitation
    let copyWebInvitation: () -> Void
    let cancel: () -> Void
    let refreshExpiry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan with the phone you want to pair.")
            if let image = QRCodeRenderer.image(for: invitation.url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 208, height: 208)
                    .accessibilityLabel(invitation.accessibilityLabel)
            }
            HStack {
                Button("Copy Invitation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invitation.sharePayload, forType: .string)
                }
                Button("Copy PWA Invitation") {
                    copyWebInvitation()
                }
                .accessibilityIdentifier("copy-pwa-invitation")
                .help("Copy a web invitation for phones without the native app")
                ShareLink(item: invitation.sharePayload) { Text("Share…") }
                Button("Cancel", role: .cancel, action: cancel)
            }
        }
        .task(id: invitation.expiresAt) {
            let remaining = max(0, invitation.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            await refreshExpiry()
        }
    }
}

private struct PairingApprovalView: View {
    let approval: PairingController.Approval
    let approve: () -> Void
    let deny: () -> Void
    let refreshExpiry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm this code matches the phone")
                .font(.headline)
            Text(approval.confirmationCode)
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .accessibilityLabel(approval.accessibilityCode)
            HStack {
                Button("Approve", action: approve)
                    .buttonStyle(.borderedProminent)
                Button("Deny", role: .destructive, action: deny)
            }
        }
        .task(id: approval.expiresAt) {
            let remaining = max(0, approval.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            await refreshExpiry()
        }
    }
}

private struct PhoneManagementView: View {
    @ObservedObject var controller: PhoneManagementController
    @State private var pendingRevokeDeviceId: String?

    var body: some View {
        Group {
            if controller.isLoading && controller.phones.isEmpty {
                ProgressView("Loading paired phones…")
            } else if controller.phones.isEmpty {
                Text("No phones are paired.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.phones) { phone in
                    HStack {
                        Text(phone.label)
                        Spacer()
                        if isRevoking(phone.deviceId) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Remove", role: .destructive) {
                                pendingRevokeDeviceId = phone.deviceId
                            }
                        }
                    }
                }
            }
        }
        .onAppear { Task { await controller.refresh() } }
        .confirmationDialog(
            "Remove this phone?",
            isPresented: Binding(
                get: { pendingRevokeDeviceId != nil },
                set: { presented in if !presented { pendingRevokeDeviceId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let deviceId = pendingRevokeDeviceId {
                    Task { await controller.revoke(deviceId: deviceId) }
                }
                pendingRevokeDeviceId = nil
            }
            Button("Cancel", role: .cancel) { pendingRevokeDeviceId = nil }
        } message: {
            Text("This phone will no longer be able to send clicks to this Mac.")
        }
        .alert(
            "Couldn't remove phone",
            isPresented: Binding(
                get: { revokeFailed },
                set: { presented in if !presented { controller.dismissRevokeFailure() } }
            )
        ) {
            Button("OK") { controller.dismissRevokeFailure() }
        } message: {
            Text(revokeFailureMessage)
        }
    }

    private func isRevoking(_ deviceId: String) -> Bool {
        if case .revoking(let revokingId) = controller.revokeState { return revokingId == deviceId }
        return false
    }

    private var revokeFailed: Bool {
        if case .failed = controller.revokeState { return true }
        return false
    }

    private var revokeFailureMessage: String {
        guard case .failed(_, let reason) = controller.revokeState else { return "" }
        switch reason {
        case .unknownDevice: return "That phone is no longer in the registry."
        case .alreadyRevoked: return "That phone was already removed."
        case .storageFailed: return "The relay couldn't save this change. Try again."
        }
    }
}

private struct PairingRecoveryView: View {
    let message: String
    let action: PairingController.RecoveryAction?
    let recover: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(message)
            if let action {
                Button(action == .startAgain ? "Start Again" : "Retry", action: recover)
            }
        }
    }
}
