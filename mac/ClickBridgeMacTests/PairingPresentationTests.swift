import XCTest
@testable import ClickBridgeMac

final class PairingPresentationTests: XCTestCase {
    func testNoEnrollmentOffersPairPhoneWithoutReplacementConfirmation() {
        let presentation = PairingActionPresentation(status: nil)

        XCTAssertEqual(presentation.title, "Pair Phone")
        XCTAssertFalse(presentation.requiresReplacementConfirmation)
    }

    func testLegacyVersionZeroAndPairedEnrollmentRequireExplicitReplacement() {
        let legacy = PairingActionPresentation(status: PairStatus(
            requestId: "018f63f5-6f3d-7d21-88bc-9ef561f030ab",
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        ))
        let paired = PairingActionPresentation(status: PairStatus(
            requestId: "018f63f5-6f3d-7d21-88bc-9ef561f030ac",
            enrollmentState: .paired,
            activePhoneCredentialVersion: 2
        ))

        XCTAssertEqual(legacy.title, "Replace Phone")
        XCTAssertTrue(legacy.requiresReplacementConfirmation)
        XCTAssertEqual(paired.title, "Replace Phone")
        XCTAssertTrue(paired.requiresReplacementConfirmation)
    }
}
