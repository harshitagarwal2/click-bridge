import SwiftUI

struct PhoneManagementView: View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
