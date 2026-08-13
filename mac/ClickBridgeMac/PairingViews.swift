import SwiftUI

enum PairingAccessibility {
    static let sheet = "pairing-sheet"
    static let qrCode = "pairing-qr-code"
    static let countdown = "pairing-countdown"
    static let clientKind = "pairing-client-kind"
    static let confirmationCode = "pairing-confirmation-code"
    static let approve = "pairing-approve"
    static let mismatch = "pairing-mismatch"
    static let share = "pairing-share"
    static let copyNative = "pairing-copy-native"
    static let copyBrowser = "pairing-copy-browser"
    static let cancel = "pairing-cancel"
    static let feedback = "pairing-feedback"
    static let recovery = "pairing-recovery"

    static let all = [
        sheet, qrCode, countdown, clientKind, confirmationCode, approve,
        mismatch, share, copyNative, copyBrowser, cancel, feedback, recovery,
    ]
}

enum PairingFeedback: Equatable {
    case invitationCopied
    case browserInvitationCopied
    case invitationUnavailable
    case shareStarted

    var message: String {
        switch self {
        case .invitationCopied: "Invitation link copied."
        case .browserInvitationCopied: "Browser invitation link copied."
        case .invitationUnavailable: "This invitation is no longer available. Create a new one."
        case .shareStarted: "Choose a trusted person or channel to send the invitation."
        }
    }
}

struct PairingPresentation: Equatable {
    let title: String
    let primaryActionTitle: String

    init(state: PairingController.State, recoveryAction: PairingController.RecoveryAction?) {
        switch state {
        case .unavailable:
            (title, primaryActionTitle) = ("Phone setup unavailable", "Close")
        case .checkingStatus:
            (title, primaryActionTitle) = ("Checking phone setup", "Checking…")
        case .ready:
            (title, primaryActionTitle) = ("Ready to connect", "Close")
        case .replacementConfirmation:
            (title, primaryActionTitle) = ("Confirm phone setup", "Continue")
        case .creating:
            (title, primaryActionTitle) = ("Creating invitation", "Creating…")
        case .invitation:
            (title, primaryActionTitle) = ("Connect Your Phone", "Share Secure Setup Link…")
        case .approval:
            (title, primaryActionTitle) = ("Check the Code", "Codes Match — Approve")
        case .approving:
            (title, primaryActionTitle) = ("Connecting phone", "Approving…")
        case .denying:
            (title, primaryActionTitle) = ("Keeping this Mac safe", "Denying…")
        case .cancelling:
            (title, primaryActionTitle) = ("Cancelling invitation", "Cancelling…")
        case .cancelFailed:
            (title, primaryActionTitle) = ("Invitation status unknown", "Check Status")
        case .completed:
            (title, primaryActionTitle) = ("Phone connected", "Done")
        case .denied:
            (title, primaryActionTitle) = ("Phone not connected", "Start Again")
        case .expired:
            (title, primaryActionTitle) = ("Invitation expired", "Create New Invitation")
        case .failed:
            (title, primaryActionTitle) = ("Couldn’t connect phone", recoveryAction == .startAgain ? "Start Again" : "Retry")
        }
    }

    static func countdown(secondsRemaining: Int) -> String {
        let seconds = max(0, secondsRemaining)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func clientLabel(_ kind: PairingClientKind) -> String {
        switch kind {
        case .ios: "Click Bridge for iPhone"
        case .pwa: "Click Bridge in a browser"
        }
    }

    static func groupedCode(_ code: String) -> String {
        guard code.count > 3 else { return code }
        let split = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<split]) \(code[split...])"
    }

    static func accessibilityCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}

struct PairingSheet: View {
    @ObservedObject var controller: PairingController
    @Binding var isPresented: Bool
    @State private var feedback: PairingFeedback?
    @State private var closeAfterCancellation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(presentation.title).font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.state == .cancelling || controller.state == .cancelFailed)
            }
            .padding([.horizontal, .top], 24)

            Divider().padding(.top, 16)

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(width: 700, height: 600)
        .accessibilityIdentifier(PairingAccessibility.sheet)
        .interactiveDismissDisabled(controller.preventsInteractiveDismissal)
        .onChange(of: controller.state) { _, state in
            if closeAfterCancellation, state == .ready {
                closeAfterCancellation = false
                isPresented = false
            }
        }
    }

    private var presentation: PairingPresentation {
        PairingPresentation(state: controller.state, recoveryAction: controller.recoveryAction)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .unavailable:
            terminal("Connect the relay before creating a phone invitation.", action: "Close") { isPresented = false }
        case .checkingStatus:
            progress("Checking the relay for current phone access…")
        case .ready:
            terminal("Phone setup is ready.", action: "Close") { isPresented = false }
        case .replacementConfirmation:
            progress("Preparing the invitation…")
        case .creating:
            progress("Creating a single-use invitation…")
        case .invitation(let invitation):
            invitationView(invitation)
        case .approval(let approval):
            approvalView(approval)
        case .approving:
            progress("Approving the phone and rotating phone access…")
        case .denying:
            progress("Denying this phone…")
        case .cancelling:
            progress("Waiting for the relay to confirm cancellation…")
        case .cancelFailed:
            recovery(
                "Do not reuse the old invitation. Click Bridge must confirm its status before connection settings can change.",
                action: "Check Status"
            )
        case .completed:
            terminal("Phone connected. Input Permission and Remote Control must also show Ready in Settings.", action: "Done") {
                isPresented = false
            }
        case .denied:
            recovery("The codes did not match, so the phone was not connected.", action: "Start Again")
        case .expired:
            recovery("Invitations are single use and expire after five minutes.", action: "Create New Invitation")
        case .failed:
            recovery("The invitation could not be completed. No phone was connected.", action: presentation.primaryActionTitle)
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
    }

    private func invitationView(_ invitation: PairingController.Invitation) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Phone nearby?").font(.headline)
                Text("On your iPhone, open Click Bridge and scan this code.")
                if let image = QRCodeRenderer.image(for: invitation.url) {
                    HStack {
                        Spacer()
                        Image(nsImage: image)
                            .interpolation(.none)
                            .accessibilityLabel("Pairing QR code")
                            .accessibilityValue(countdownValue(expiresAt: invitation.expiresAt))
                            .accessibilityHint("Scan using Click Bridge on iPhone.")
                            .accessibilityIdentifier(PairingAccessibility.qrCode)
                        Spacer()
                    }
                }
                CountdownView(expiresAt: invitation.expiresAt) {
                    Task { await controller.refreshExpiry() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Phone somewhere else?").font(.headline)
                Text("Send this single-use link through Messages, Mail, or another trusted channel. The devices do not need to be on the same network.")
                    .foregroundStyle(.secondary)
                SharingServiceButton(
                    resolver: controller.invitationURLResolver(for: invitation, destination: .nativeApp),
                    feedback: { feedback = $0 }
                )
                .fixedSize()
                Menu("Other Ways to Connect") {
                    Button("Copy Invitation Link") {
                        copy(invitation, destination: .nativeApp)
                    }
                    .accessibilityIdentifier(PairingAccessibility.copyNative)
                    Button("Copy Browser Invitation Link") {
                        copy(invitation, destination: .browser)
                    }
                    .accessibilityIdentifier(PairingAccessibility.copyBrowser)
                }
                if let feedback {
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(PairingAccessibility.feedback)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Button("Cancel Invitation", role: .destructive) {
                Task { await controller.cancel() }
            }
            .accessibilityIdentifier(PairingAccessibility.cancel)
        }
    }

    private func approvalView(_ approval: PairingController.Approval) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(PairingPresentation.clientLabel(approval.clientKind))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(PairingAccessibility.clientKind)
            Text(PairingPresentation.groupedCode(approval.confirmationCode))
                .font(.system(size: 52, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Confirmation code")
                .accessibilityValue(PairingPresentation.accessibilityCode(approval.confirmationCode))
                .accessibilityIdentifier(PairingAccessibility.confirmationCode)
            Text("Do both devices show this same code?").font(.headline)
            CountdownView(expiresAt: approval.expiresAt) {
                Task { await controller.refreshExpiry() }
            }
            HStack {
                Button("Codes Match — Approve") { Task { await controller.approve() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(PairingAccessibility.approve)
                Button("Codes Don’t Match", role: .destructive) {
                    Task { await controller.codesDoNotMatch() }
                }
                .accessibilityIdentifier(PairingAccessibility.mismatch)
            }
        }
    }

    private func terminal(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
            Button(action, action: perform).buttonStyle(.borderedProminent)
        }
    }

    private func recovery(_ message: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
            Button(action) { Task { await controller.regenerate() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(PairingAccessibility.recovery)
        }
    }

    private func copy(
        _ invitation: PairingController.Invitation,
        destination: PairingInvitationDestination
    ) {
        let copied = controller.copyInvitation(invitation, destination: destination)
        guard copied else {
            feedback = .invitationUnavailable
            return
        }
        feedback = destination == .nativeApp ? .invitationCopied : .browserInvitationCopied
    }

    private func close() {
        guard controller.preventsInteractiveDismissal else {
            isPresented = false
            return
        }
        switch controller.state {
        case .creating, .invitation, .approval:
            closeAfterCancellation = true
            Task { await controller.cancel() }
        default:
            break
        }
    }

    private func countdownValue(expiresAt: Date) -> String {
        "Single use. Expires in \(PairingPresentation.countdown(secondsRemaining: Int(ceil(expiresAt.timeIntervalSinceNow))))."
    }
}

private struct CountdownView: View {
    let expiresAt: Date
    let expired: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(context.date))))
            Label(
                "Single use · Expires in \(PairingPresentation.countdown(secondsRemaining: remaining))",
                systemImage: "timer"
            )
            .monospacedDigit()
            .accessibilityIdentifier(PairingAccessibility.countdown)
            .onChange(of: remaining) { _, value in
                if value == 0 { expired() }
            }
        }
    }
}
