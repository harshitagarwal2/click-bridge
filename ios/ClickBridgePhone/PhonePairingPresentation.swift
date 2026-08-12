import Foundation

struct PhonePairingPresentation: Equatable {
    let title: String
    let detail: String
    let confirmationCode: String?
    let confirmationAccessibilityLabel: String?
    let showsProgress: Bool
    let canTryAgain: Bool

    init(state: PhonePairingState) {
        confirmationCode = state.confirmationCode
        confirmationAccessibilityLabel = Self.accessibilityCode(state.confirmationCode)
        switch state.phase {
        case .idle:
            title = "Connect to your Mac"
            detail = "Scan the pairing code shown by Click Bridge on your Mac."
            showsProgress = false
            canTryAgain = false
        case .connecting, .claiming:
            title = "Connecting securely…"
            detail = "Keep Click Bridge open on both devices."
            showsProgress = true
            canTryAgain = false
        case .awaitingApproval:
            title = "Confirm on your Mac"
            detail = "Make sure this six-digit code matches, then approve the phone on your Mac."
            showsProgress = true
            canTryAgain = false
        case .awaitingCredential, .awaitingActivation:
            title = "Finishing connection…"
            detail = "Your Mac approved this phone. Activating its saved connection now."
            showsProgress = true
            canTryAgain = false
        case .active:
            title = "Mac connected"
            detail = "This phone is paired and ready to use."
            showsProgress = false
            canTryAgain = false
        case .cancelled:
            title = "Pairing cancelled"
            detail = "No connection was saved."
            showsProgress = false
            canTryAgain = true
        case .replaced:
            title = "Pairing replaced"
            detail = "That invitation was used by another claimant. Create a new code on your Mac."
            showsProgress = false
            canTryAgain = true
        case .failed:
            (title, detail) = Self.failureCopy(state.failure)
            showsProgress = false
            canTryAgain = true
        }
    }

    static func shouldCancelOnBackground(_ phase: PhonePairingPhase) -> Bool {
        switch phase {
        case .connecting, .claiming, .awaitingApproval, .awaitingCredential, .awaitingActivation:
            true
        default:
            false
        }
    }

    private static func accessibilityCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let groups = code.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }
        guard groups.count == 2 else { return "Confirmation code" }
        return "Confirmation code \(groups[0]), \(groups[1])"
    }

    private static func failureCopy(_ reason: String?) -> (String, String) {
        switch reason {
        case "denied":
            ("Pairing denied", "Your Mac declined this phone. Create a new code when you’re ready to try again.")
        case "expired", "claim_timeout", "connection_timeout":
            ("Pairing link expired", "Create a new pairing code on your Mac and scan it again.")
        case "replaced":
            ("Pairing replaced", "That invitation was used by another claimant. Create a new code on your Mac.")
        default:
            ("Couldn’t connect", "The secure pairing could not finish. Create a new code on your Mac and try again.")
        }
    }
}
