import XCTest
@testable import ClickBridgePhone

final class PhonePairingPresentationTests: XCTestCase {
    func testClaimantPresentationUsesTruthfulCopyForEveryTerminalAndWaitingState() {
        XCTAssertEqual(PhonePairingPresentation(state: .init(phase: .connecting)).title,
                       "Connecting securely…")
        XCTAssertEqual(PhonePairingPresentation(state: .init(
            phase: .awaitingApproval,
            confirmationCode: "123 456",
            expiresAtUnixMilliseconds: 1_786_579_500_000
        )).title, "Confirm on your Mac")
        XCTAssertEqual(PhonePairingPresentation(state: .init(phase: .active)).title,
                       "Mac connected")
        XCTAssertEqual(PhonePairingPresentation(state: .init(
            phase: .failed,
            failure: "denied"
        )).title, "Pairing denied")
        XCTAssertEqual(PhonePairingPresentation(state: .init(
            phase: .failed,
            failure: "expired"
        )).title, "Pairing link expired")
        XCTAssertEqual(PhonePairingPresentation(state: .init(phase: .replaced)).title,
                       "Pairing replaced")
    }

    func testConfirmationCodeAccessibilitySpellsDigitsWithoutExposingInvitation() {
        let presentation = PhonePairingPresentation(state: .init(
            phase: .awaitingApproval,
            confirmationCode: "123 456"
        ))

        XCTAssertEqual(presentation.confirmationCode, "123 456")
        XCTAssertEqual(presentation.confirmationAccessibilityLabel,
                       "Confirmation code 1 2 3, 4 5 6")
        XCTAssertFalse(presentation.confirmationAccessibilityLabel?.contains("pair") == true)
    }

    func testOnlyInFlightPairingPhasesCancelWhenAppBackgrounds() {
        XCTAssertTrue(PhonePairingPresentation.shouldCancelOnBackground(.connecting))
        XCTAssertTrue(PhonePairingPresentation.shouldCancelOnBackground(.awaitingApproval))
        XCTAssertTrue(PhonePairingPresentation.shouldCancelOnBackground(.awaitingActivation))
        XCTAssertFalse(PhonePairingPresentation.shouldCancelOnBackground(.active))
        XCTAssertFalse(PhonePairingPresentation.shouldCancelOnBackground(.failed))
    }

    func testFailureCopyDoesNotEchoUnknownServerReason() {
        let secretLikeReason = String(repeating: "a", count: 64)
        let presentation = PhonePairingPresentation(state: .init(
            phase: .failed,
            failure: secretLikeReason
        ))

        XCTAssertEqual(presentation.title, "Couldn’t connect")
        XCTAssertFalse(presentation.detail.contains(secretLikeReason))
    }
}
