import SwiftUI

struct RelaySettingsDraft: Equatable {
    let hasStoredToken: Bool
    var relayURL: String {
        didSet {
            if relayURL != oldValue { errorMessage = nil }
        }
    }
    var token: String {
        didSet {
            if token != oldValue { errorMessage = nil }
        }
    }
    var errorMessage: String?

    init(initialRelayURL: String,
         hasStoredToken: Bool,
         initialError: String? = nil) {
        self.hasStoredToken = hasStoredToken
        relayURL = initialRelayURL
        token = ""
        errorMessage = initialError
    }

    var canSave: Bool {
        do {
            _ = try RelayConfiguration.validatedURL(relayURL)
            if token.isEmpty { return hasStoredToken }
            try RelayConfiguration.validateToken(token)
            return true
        } catch {
            return false
        }
    }
}

struct ContentView: View {
    let model: PhoneAppModel
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            DashboardView(state: model.state,
                          canTriggerClick: model.canTriggerClick,
                          triggerClick: model.triggerClick,
                          retryClockCheck: model.retryClockCheck,
                          reconnectAfterTakeover: model.reconnectAfterTakeover)
                .navigationTitle("Click Bridge")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("settings.open")
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(initialRelayURL: model.settings.relayURLString,
                         hasStoredToken: model.settings.hasToken,
                         initialError: model.state.issue?.settingsMessage,
                         save: model.saveSettings)
        }
    }
}

enum DashboardAccessibilityFocus: Hashable {
    case issue
    case outcome
}

struct DashboardAccessibilityAnnouncement: Equatable {
    let issue: PhoneAppIssue?
    let outcome: String?

    func focusChange(from previous: Self) -> DashboardAccessibilityFocus? {
        if issue != previous.issue, issue != nil { return .issue }
        if outcome != previous.outcome, outcome != nil { return .outcome }
        return nil
    }
}

private struct DashboardView: View {
    let state: PhoneState
    let canTriggerClick: Bool
    let triggerClick: () -> ActionDisposition
    let retryClockCheck: () -> Void
    let reconnectAfterTakeover: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var volumeFontSize = 64.0
    @AccessibilityFocusState private var accessibilityFocus: DashboardAccessibilityFocus?

    private var volumePercentage: Int {
        Int((state.volume.value * 100).rounded())
    }

    private var accessibilityAnnouncement: DashboardAccessibilityAnnouncement {
        DashboardAccessibilityAnnouncement(issue: state.issue,
                                           outcome: state.lastActionOutcome)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusContent

                if let issue = state.issue {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("App issue. \(issue.message)")
                        .accessibilityIdentifier("status.issue")
                        .accessibilityFocused($accessibilityFocus, equals: .issue)
                }

                Text("\(volumePercentage)%")
                    .font(.system(size: volumeFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityLabel("System volume \(volumePercentage) percent")
                    .accessibilityIdentifier("volume.percentage")

                Button {
                    _ = triggerClick()
                } label: {
                    Label("Trigger 3 Clicks", systemImage: "cursorarrow.click")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canTriggerClick)
                .accessibilityLabel("Trigger 3 Clicks")
                .accessibilityHint("Sends three ordinary clicks to the connected Mac")
                .accessibilityIdentifier("trigger.click")

                if let outcome = state.lastActionOutcome {
                    Text(outcome)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Last action result. \(outcome)")
                        .accessibilityIdentifier("action.outcome")
                        .accessibilityFocused($accessibilityFocus, equals: .outcome)
                }

                Text("Any system volume change can trigger, including Control Center, wired or Bluetooth headsets, and AirPods.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: accessibilityAnnouncement) { previous, announcement in
            accessibilityFocus = announcement.focusChange(from: previous)
        }
    }

    private var statusContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text(state.primaryStatus.title)
                    .font(.title2.bold())
                if let detail = state.primaryStatusDetail {
                    Text(detail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([state.primaryStatus.title, state.primaryStatusDetail]
                .compactMap { $0 }
                .joined(separator: ". "))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("status.summary")

            if state.clock.status == .unavailable {
                Button("Retry clock check", action: retryClockCheck)
                    .accessibilityHint("Checks the phone and Mac clocks again")
                    .accessibilityIdentifier("clock.retry")
            }
            if state.phoneTakenOver {
                Button("Reconnect this phone", action: reconnectAfterTakeover)
                    .accessibilityHint("Disconnects the newer phone and reconnects this one")
                    .accessibilityIdentifier("takeover.reconnect")
            }
        }
    }
}

private enum SettingsField: Hashable {
    case relayURL
    case token
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelaySettingsDraft
    @FocusState private var focusedField: SettingsField?
    @AccessibilityFocusState private var errorFocused: Bool

    let save: (_ relayURL: String, _ token: String) throws -> Void

    init(initialRelayURL: String,
         hasStoredToken: Bool,
         initialError: String? = nil,
         save: @escaping (_ relayURL: String, _ token: String) throws -> Void) {
        _draft = State(initialValue: RelaySettingsDraft(initialRelayURL: initialRelayURL,
                                                        hasStoredToken: hasStoredToken,
                                                        initialError: initialError))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Relay WSS URL",
                              text: $draft.relayURL,
                              prompt: Text("wss://relay.example/ws"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .relayURL)
                        .onSubmit { focusedField = .token }
                        .accessibilityLabel("Relay WSS URL")
                        .accessibilityIdentifier("settings.relayURL")

                    SecureField(draft.hasStoredToken ? "Replacement phone token" : "Phone token",
                                text: $draft.token)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .token)
                        .onSubmit {
                            if draft.canSave { saveAndDismiss() }
                        }
                        .privacySensitive()
                        .accessibilityLabel(draft.hasStoredToken
                            ? "Replacement phone token, optional"
                            : "Phone token")
                        .accessibilityIdentifier("settings.token")
                } header: {
                    Text("Relay")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use a wss:// URL ending in /ws. The phone token is 64 lowercase hexadecimal characters.")
                        if draft.hasStoredToken {
                            Text("Leave the token blank to keep the saved token.")
                        }
                    }
                }

                if let errorMessage = draft.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Settings error. \(errorMessage)")
                            .accessibilityIdentifier("settings.error")
                            .accessibilityFocused($errorFocused)
                    }
                }

                Section("Usage") {
                    Text("The native app and PWA are fallback clients. Use only one live phone client at a time.")
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("settings.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveAndDismiss)
                        .disabled(!draft.canSave)
                        .accessibilityIdentifier("settings.save")
                }
            }
            .onChange(of: draft.errorMessage, initial: true) { _, errorMessage in
                errorFocused = errorMessage != nil
            }
        }
    }

    private func saveAndDismiss() {
        guard draft.canSave else { return }
        do {
            try save(draft.relayURL, draft.token)
            draft.token = ""
            dismiss()
        } catch {
            draft.errorMessage = error.localizedDescription
        }
    }
}

private struct DashboardPreview: View {
    let state: PhoneState
    let canTriggerClick: Bool

    var body: some View {
        NavigationStack {
            DashboardView(state: state,
                          canTriggerClick: canTriggerClick,
                          triggerClick: { .ignoredNotReady },
                          retryClockCheck: {},
                          reconnectAfterTakeover: {})
                .navigationTitle("Click Bridge")
        }
    }
}

private extension PhoneState {
    static var previewDisconnected: PhoneState {
        var state = PhoneState()
        state.issue = .invalidSettings
        return state
    }

    static var previewReady: PhoneState {
        var state = PhoneState()
        state.foregroundSessionActive = true
        state.connection = .authenticated
        state.mac = .init(online: true, remoteEnabled: true, permission: .ready)
        state.clock = .init(status: .healthy,
                            offsetMilliseconds: 0,
                            uncertaintyMilliseconds: 1)
        state.volume = .init(value: 0.52)
        state.lastActionOutcome = "Posted in 42 ms"
        return state
    }

    static var previewClockUnavailable: PhoneState {
        var state = previewReady
        state.clock = .init(status: .unavailable,
                            offsetMilliseconds: nil,
                            uncertaintyMilliseconds: nil)
        state.lastActionOutcome = nil
        return state
    }
}

#Preview("Disconnected") {
    DashboardPreview(state: .previewDisconnected, canTriggerClick: false)
}

#Preview("Ready") {
    DashboardPreview(state: .previewReady, canTriggerClick: true)
}

#Preview("Clock retry - Accessibility text") {
    DashboardPreview(state: .previewClockUnavailable, canTriggerClick: false)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Settings - First setup") {
    SettingsView(initialRelayURL: "", hasStoredToken: false) { _, _ in }
}

#Preview("Settings - Stored token error") {
    SettingsView(initialRelayURL: "wss://relay.example/ws",
                 hasStoredToken: true,
                 initialError: PhoneAppIssue.secureStorageUnavailable.message) { _, _ in }
}
