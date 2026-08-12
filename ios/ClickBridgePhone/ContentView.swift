import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PhoneAppModel
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusCard
                Text("\(Int((model.state.volume.value * 100).rounded()))%")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .accessibilityLabel("System volume \(Int((model.state.volume.value * 100).rounded())) percent")
                if let outcome = model.state.lastActionOutcome {
                    Text(outcome).font(.callout).foregroundStyle(.secondary)
                }
                Text("Any system volume change can trigger, including Control Center, wired or Bluetooth headsets, and AirPods.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Click Bridge")
            .toolbar { Button("Settings") { showingSettings = true } }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            Text(model.state.primaryStatus.title).font(.title2.bold())
            if let detail = model.state.primaryStatus.detail {
                Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if model.state.clock.status == .unavailable {
                Button("Retry clock check") { model.retryClockCheck() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([model.state.primaryStatus.title, model.state.primaryStatus.detail]
            .compactMap { $0 }.joined(separator: ". "))
    }
}

private struct SettingsView: View {
    @ObservedObject var model: PhoneAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var relayURL = ""
    @State private var token = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Relay WSS URL", text: $relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(model.settings.hasToken ? "Replace phone token" : "Phone token", text: $token)
                    .textInputAutocapitalization(.never)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Section {
                    Text("The native app and PWA are fallback clients. Use only one live phone client at a time.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try model.saveSettings(urlString: relayURL, token: token)
                            token = ""
                            dismiss()
                        } catch {
                            token = ""
                            errorMessage = "Enter a valid relay URL and phone token."
                        }
                    }
                    .disabled(token.isEmpty)
                }
            }
            .onAppear { relayURL = model.settings.relayURLString }
        }
    }
}
