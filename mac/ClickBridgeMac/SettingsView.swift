import SwiftUI

enum SettingsAccessibility {
    static let relayStatus = "settings-relay-status"
    static let permissionStatus = "settings-permission-status"
    static let remoteStatus = "settings-remote-status"
    static let remoteToggle = "settings-remote-toggle"
    static let pairPhone = "settings-pair-phone"
    static let relayURLField = "settings-relay-url"
    static let replacementTokenField = "settings-replacement-token"
    static let saveAndReconnect = "settings-save-reconnect"
    static let discardChanges = "settings-discard"
    static let removeCredential = "settings-remove-credential"
    static let inlineFeedback = "settings-inline-feedback"

    static let all = [
        relayStatus, permissionStatus, remoteStatus, remoteToggle, pairPhone,
        relayURLField, replacementTokenField, saveAndReconnect, discardChanges,
        removeCredential, inlineFeedback,
    ]
}

struct ReadinessRowPresentation: Equatable {
    let title: String
    let value: String
    let symbol: String
    let identifier: String
}

enum SettingsReadinessPresentation {
    static func relay(_ status: RelayClient.Status) -> ReadinessRowPresentation {
        switch status {
        case .connected:
            return .init(title: "Relay", value: "Connected", symbol: "checkmark.circle.fill", identifier: SettingsAccessibility.relayStatus)
        case .connecting:
            return .init(title: "Relay", value: "Connecting", symbol: "arrow.triangle.2.circlepath.circle", identifier: SettingsAccessibility.relayStatus)
        case .disconnected:
            return .init(title: "Relay", value: "Not Connected", symbol: "exclamationmark.circle", identifier: SettingsAccessibility.relayStatus)
        }
    }

    static func permission(_ permission: PermissionState) -> ReadinessRowPresentation {
        permission == .ready
            ? .init(title: "Input Permission", value: "Ready", symbol: "checkmark.circle.fill", identifier: SettingsAccessibility.permissionStatus)
            : .init(title: "Input Permission", value: "Required", symbol: "hand.raised.circle", identifier: SettingsAccessibility.permissionStatus)
    }

    static func remote(enabled: Bool) -> ReadinessRowPresentation {
        enabled
            ? .init(title: "Remote Control", value: "Enabled", symbol: "checkmark.circle.fill", identifier: SettingsAccessibility.remoteStatus)
            : .init(title: "Remote Control", value: "Disabled", symbol: "pause.circle", identifier: SettingsAccessibility.remoteStatus)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @State private var draft: ConnectionSettingsDraft
    @State private var showingAdvanced = false
    @State private var showingPairing = false
    @State private var showingPairConfirmation = false
    @State private var showingRemoveConfirmation = false
    @State private var feedback: String?

    init(app: AppState) {
        self.app = app
        _draft = State(initialValue: ConnectionSettingsDraft(
            appliedRelayURLString: app.settings.relayURLString,
            relayURLString: app.settings.relayURLString,
            replacementMacToken: ""
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Click Bridge Settings")
                    .font(.title2.weight(.semibold))

                GroupBox("Ready to control this Mac") {
                    VStack(spacing: 12) {
                        readinessRow(SettingsReadinessPresentation.relay(app.connection))
                        readinessRow(SettingsReadinessPresentation.permission(app.permission))
                        readinessRow(SettingsReadinessPresentation.remote(enabled: app.settings.remoteEnabled))
                        Divider()
                        Toggle("Allow remote control", isOn: Binding(
                            get: { app.settings.remoteEnabled },
                            set: { app.setPersistedRemoteEnabled($0) }
                        ))
                        .accessibilityIdentifier(SettingsAccessibility.remoteToggle)
                        .disabled(!app.remoteToggleEnabled)
                        if app.permission != .ready {
                            Button("Grant Input Permission…") { app.requestPermission() }
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Phone") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No phone token is required. Create a single-use invitation, then approve the matching code on this Mac.")
                            .foregroundStyle(.secondary)
                        if app.connection == .connected, let pairing = app.pairing {
                            Button(app.pairingAction.buttonTitle) {
                                if app.pairingAction.requiresReplacementConfirmation {
                                    showingPairConfirmation = true
                                } else {
                                    showingPairing = true
                                    app.beginPairing()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(SettingsAccessibility.pairPhone)
                            .disabled(pairing.state != .ready)
                        } else {
                            Text("Connect the relay below before pairing a phone.")
                                .foregroundStyle(.secondary)
                            Button("Reconnect") { app.reconnect() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox("Paired Phones") {
                    if let phoneManagement = app.phoneManagement {
                        PhoneManagementView(controller: phoneManagement)
                            .padding(.top, 4)
                    } else {
                        Text("Connect the relay above to manage paired phones.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }

                DisclosureGroup("Advanced Connection", isExpanded: $showingAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Relay URL", text: $draft.relayURLString, prompt: Text("wss://your-host/ws"))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(SettingsAccessibility.relayURLField)
                        SecureField("Optional replacement Mac token", text: $draft.replacementMacToken)
                            .textFieldStyle(.roundedBorder)
                            .privacySensitive()
                            .accessibilityLabel("Replacement Mac token")
                            .accessibilityIdentifier(SettingsAccessibility.replacementTokenField)
                        Text(app.settings.hasToken ? "Stored securely in Keychain. Leave the token blank to reuse it." : "No credential stored. Enter a Mac token to connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Save & Reconnect") { applyDraft() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier(SettingsAccessibility.saveAndReconnect)
                            Button("Discard Changes") {
                                draft.discardChanges()
                                feedback = nil
                            }
                            .disabled(!draft.hasChanges)
                            .accessibilityIdentifier(SettingsAccessibility.discardChanges)
                            Spacer()
                            Button("Remove Saved Credential…", role: .destructive) {
                                showingRemoveConfirmation = true
                            }
                            .accessibilityIdentifier(SettingsAccessibility.removeCredential)
                        }
                        if let feedback {
                            Text(feedback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(SettingsAccessibility.inlineFeedback)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 560)
        .confirmationDialog(
            app.pairingAction.buttonTitle,
            isPresented: $showingPairConfirmation,
            titleVisibility: .visible
        ) {
            Button(app.pairingAction.confirmationActionTitle, role: .destructive) {
                showingPairing = true
                app.confirmReplacement()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(app.pairingAction.warning)
        }
        .alert("Remove saved credential?", isPresented: $showingRemoveConfirmation) {
            Button("Remove Credential", role: .destructive) { removeCredential() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Click Bridge will disconnect until you save a valid connection again.")
        }
        .sheet(isPresented: $showingPairing) {
            if let pairing = app.pairing {
                PairingSheet(controller: pairing, isPresented: $showingPairing)
            }
        }
        .onAppear { app.refreshPermission() }
    }

    @ViewBuilder
    private func readinessRow(_ row: ReadinessRowPresentation) -> some View {
        HStack {
            Label(row.title, systemImage: row.symbol)
            Spacer()
            Text(row.value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.identifier)
    }

    private func applyDraft() {
        let task = app.applyConnectionSettings(
            relayURLString: draft.relayURLString,
            replacementMacToken: draft.replacementMacToken
        )
        Task { @MainActor in
            let outcome = await task.value
            draft.reduce(outcome: outcome, acceptedRelayURLString: app.settings.relayURLString)
            switch outcome {
            case .accepted:
                feedback = "Connection saved. Reconnecting…"
            case .rejected(let issue):
                feedback = issue.localizedDescription
            }
        }
    }

    private func removeCredential() {
        let task = app.clearToken()
        Task { @MainActor in
            let outcome = await task.value
            draft.reduceCredentialRemoval(outcome: outcome)
            switch outcome {
            case .accepted:
                feedback = "Saved credential removed."
            case .rejected(let issue):
                feedback = issue.localizedDescription
            }
        }
    }
}
