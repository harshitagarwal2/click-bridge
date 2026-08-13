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

enum AdvancedLegacySettingsPresentation {
    static func showsSaveButton(isExpanded: Bool) -> Bool { isExpanded }
}

struct ContentView: View {
    let model: PhoneAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.hasToken {
                    DashboardView(state: model.state,
                                  canTriggerClick: model.canTriggerClick,
                                  triggerClick: model.triggerClick,
                                  retryClockCheck: model.retryClockCheck,
                                  reconnectAfterTakeover: model.reconnectAfterTakeover)
                } else {
                    UnpairedView(connect: model.showPairingClaimant)
                }
            }
                .navigationTitle("Click Bridge")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.showSettings()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("settings.open")
                    }
                }
        }
        .sheet(isPresented: Binding(
            get: { model.presentedFlow == .settings || model.presentedFlow == .pairing },
            set: { if !$0 { model.dismissPresentedFlow() } }
        )) {
            switch model.presentedFlow {
            case .settings:
                SettingsView(initialRelayURL: model.settings.relayURLString,
                             hasStoredToken: model.settings.hasToken,
                             initialError: model.state.issue?.settingsMessage,
                             pairAgain: model.showPairingClaimant,
                             forget: model.forgetMac,
                             save: model.saveSettings)
            case .pairing:
                PairingClaimantView(model: model)
            default:
                EmptyView()
            }
        }
        .confirmationDialog("Replace this phone’s saved connection?",
                            isPresented: Binding(get: { model.replacementConfirmationPresented },
                                                 set: { if !$0 { model.rejectPairAgain() } }),
                            titleVisibility: .visible) {
            Button("Replace Connection", role: .destructive, action: model.confirmPairAgain)
            Button("Cancel", role: .cancel, action: model.rejectPairAgain)
        } message: {
            Text("The current connection remains saved unless the new pairing is approved and activated.")
        }
    }
}

private struct UnpairedView: View {
    let connect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Connect to your Mac", systemImage: "macbook.and.iphone")
        } description: {
            Text(PhoneDeployment.pairingAvailabilityCopy)
        } actions: {
            Button("Connect to your Mac", action: connect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityHint("Opens the pairing code scanner")
                .accessibilityIdentifier("pairing.connect")
        }
    }
}

private struct PairingClaimantView: View {
    @Environment(\.dismiss) private var dismiss
    let model: PhoneAppModel

    private var presentation: PhonePairingPresentation {
        PhonePairingPresentation(state: model.pairingState)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if model.pairingState.phase == .idle {
                        PairingScannerView(receive: model.submitPairingInvitation)
                        PasteButton(payloadType: String.self) { values in
                            guard let value = values.first else { return }
                            model.submitPairingInvitation(value)
                        }
                        .buttonBorderShape(.roundedRectangle)
                        .accessibilityLabel("Paste pairing link")
                        .accessibilityHint("Uses a Click Bridge invitation copied from your Mac")
                        .accessibilityIdentifier("pairing.paste")
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: 52))
                            .foregroundStyle(iconColor)
                            .accessibilityHidden(true)
                        Text(presentation.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        if let code = presentation.confirmationCode {
                            Text(code)
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .monospacedDigit()
                                .accessibilityLabel(presentation.confirmationAccessibilityLabel ?? "Confirmation code")
                                .accessibilityIdentifier("pairing.confirmationCode")
                        }
                        Text(presentation.detail)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if presentation.showsProgress { ProgressView() }
                        if presentation.canTryAgain {
                            if model.hasPendingPairing {
                                Button("Resolve Saved Pairing", action: model.retrySavedPairing)
                                    .buttonStyle(.borderedProminent)
                                    .frame(minHeight: 44)
                                Button("Start Over", role: .destructive, action: model.startOverSavedPairing)
                                    .frame(minHeight: 44)
                            } else {
                                Button("Scan a New Code") { model.showPairingClaimant() }
                                    .buttonStyle(.borderedProminent)
                                    .frame(minHeight: 44)
                            }
                        }
                        if model.pairingState.phase == .active {
                            Button("Done") {
                                model.dismissPresentedFlow()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if PhonePairingPresentation.allowsCancellation(model.pairingState.phase) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            model.cancelPairing()
                            model.dismissPresentedFlow()
                            dismiss()
                        }
                        .accessibilityIdentifier("pairing.cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(PhonePairingPresentation.preventsInteractiveDismiss(model.pairingState.phase))
    }

    private var iconName: String {
        switch model.pairingState.phase {
        case .active: "checkmark.circle.fill"
        case .failed, .replaced: "exclamationmark.triangle.fill"
        default: "macbook.and.iphone"
        }
    }

    private var iconColor: Color {
        model.pairingState.phase == .active ? .green : .accentColor
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

            if state.showsClockRetry {
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

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelaySettingsDraft
    @AccessibilityFocusState private var errorFocused: Bool

    let save: (_ relayURL: String, _ token: String) throws -> Void
    let pairAgain: () -> Void
    let forget: () throws -> Void

    init(initialRelayURL: String,
         hasStoredToken: Bool,
         initialError: String? = nil,
         pairAgain: @escaping () -> Void,
         forget: @escaping () throws -> Void,
         save: @escaping (_ relayURL: String, _ token: String) throws -> Void) {
        _draft = State(initialValue: RelaySettingsDraft(initialRelayURL: initialRelayURL,
                                                        hasStoredToken: hasStoredToken,
                                                        initialError: initialError))
        self.save = save
        self.pairAgain = pairAgain
        self.forget = forget
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.hasStoredToken {
                    Section("Connection") {
                        Button("Pair Again") {
                            pairAgain()
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("settings.pairAgain")
                        Button("Forget This Mac", role: .destructive) {
                            do { try forget(); dismiss() }
                            catch { draft.errorMessage = error.localizedDescription }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("settings.forget")
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
                    Text("Each phone keeps its own connection. Add another phone by scanning a new code on that phone.")
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
    SettingsView(initialRelayURL: "", hasStoredToken: false,
                 pairAgain: {}, forget: {}, save: { _, _ in })
}

#Preview("Settings - Stored token error") {
    SettingsView(initialRelayURL: "wss://relay.example/ws",
                 hasStoredToken: true,
                 initialError: PhoneAppIssue.secureStorageUnavailable.message,
                 pairAgain: {}, forget: {}, save: { _, _ in })
}
