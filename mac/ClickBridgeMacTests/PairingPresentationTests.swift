import XCTest
import UniformTypeIdentifiers
@testable import ClickBridgeMac

@MainActor
final class PairingPresentationTests: XCTestCase {
    func testNoEnrollmentOffersPairPhoneWithoutReplacementConfirmation() {
        let presentation = PairingActionPresentation(status: nil)

        XCTAssertEqual(presentation.title, "Pair Phone")
        XCTAssertEqual(presentation.buttonTitle, "Pair Phone")
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

        XCTAssertEqual(legacy.buttonTitle, "Pair Phone")
        XCTAssertTrue(legacy.requiresReplacementConfirmation)
        XCTAssertEqual(legacy.confirmationActionTitle, "Pair Phone")
        XCTAssertTrue(legacy.warning.contains("older shared phone access"))
        XCTAssertEqual(paired.buttonTitle, "Replace Phone…")
        XCTAssertTrue(paired.requiresReplacementConfirmation)
        XCTAssertEqual(paired.confirmationActionTitle, "Replace Phone")
        XCTAssertTrue(paired.warning.contains("current phone"))
    }

    func testCountdownFormattingAtImportantBoundaries() {
        XCTAssertEqual(PairingPresentation.countdown(secondsRemaining: 300), "5:00")
        XCTAssertEqual(PairingPresentation.countdown(secondsRemaining: 299), "4:59")
        XCTAssertEqual(PairingPresentation.countdown(secondsRemaining: 1), "0:01")
        XCTAssertEqual(PairingPresentation.countdown(secondsRemaining: 0), "0:00")
        XCTAssertEqual(PairingPresentation.countdown(secondsRemaining: -10), "0:00")
    }

    func testClientLabelsAndConfirmationCodePresentation() {
        XCTAssertEqual(PairingPresentation.clientLabel(.ios), "Click Bridge for iPhone")
        XCTAssertEqual(PairingPresentation.clientLabel(.pwa), "Click Bridge in a browser")
        XCTAssertEqual(PairingPresentation.groupedCode("123456"), "123 456")
        XCTAssertEqual(PairingPresentation.accessibilityCode("123456"), "1 2 3 4 5 6")
    }

    func testEveryStateHasDeterministicPrimaryPresentation() {
        let invitation = PairingController.Invitation(
            url: URL(string: "https://relay.example/pair#v=1&r=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")!,
            expiresAt: Date(timeIntervalSince1970: 1_786_497_900)
        )
        let approval = PairingController.Approval(
            confirmationCode: "123456",
            clientKind: .ios,
            expiresAt: invitation.expiresAt
        )
        let states: [PairingController.State] = [
            .unavailable, .checkingStatus, .ready, .replacementConfirmation,
            .creating, .invitation(invitation), .approval(approval), .approving,
            .denying, .cancelling, .cancelFailed,
            .completed(activePhoneCredentialVersion: 2), .denied, .expired, .failed,
        ]

        for state in states {
            let presentation = PairingPresentation(state: state, recoveryAction: .retry)
            XCTAssertFalse(presentation.title.isEmpty, "Missing title for \(state)")
            XCTAssertFalse(presentation.primaryActionTitle.isEmpty, "Missing action for \(state)")
        }
    }

    func testFeedbackIsFixedAndDoesNotEchoInvitation() {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertEqual(PairingFeedback.invitationCopied.message, "Invitation link copied.")
        XCTAssertEqual(PairingFeedback.browserInvitationCopied.message, "Browser invitation link copied.")
        XCTAssertEqual(PairingFeedback.invitationUnavailable.message, "This invitation is no longer available. Create a new one.")
        XCTAssertFalse(PairingFeedback.invitationUnavailable.message.contains(reference))
    }

    func testStablePairingIdentifiersAreUniqueAndComplete() {
        let identifiers = PairingAccessibility.all
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for required in [
            PairingAccessibility.sheet,
            PairingAccessibility.qrCode,
            PairingAccessibility.countdown,
            PairingAccessibility.clientKind,
            PairingAccessibility.confirmationCode,
            PairingAccessibility.approve,
            PairingAccessibility.mismatch,
            PairingAccessibility.share,
            PairingAccessibility.copyNative,
            PairingAccessibility.copyBrowser,
            PairingAccessibility.recovery,
        ] {
            XCTAssertTrue(identifiers.contains(required))
        }
    }

    func testSharePreparationAndLazyConsumptionResolveIndependently() async throws {
        let url = URL(string: "https://relay.example/pair#v=1&r=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")!
        var calls = 0
        let provider = PairingShareProviderFactory.prepare {
            calls += 1
            return url
        }

        XCTAssertNotNil(provider)
        XCTAssertEqual(calls, 1, "Button activation must resolve once")

        let data = try await loadData(from: provider!, typeIdentifier: UTType.plainText.identifier)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), url.absoluteString)
        XCTAssertEqual(calls, 2, "Representation load must resolve again")
    }

    func testShareDoesNotPresentWhenActivationIsStale() {
        var calls = 0
        let provider = PairingShareProviderFactory.prepare {
            calls += 1
            return nil
        }

        XCTAssertNil(provider)
        XCTAssertEqual(calls, 1)
    }

    func testShareProviderReturnsNoDataWhenInvitationBecomesStale() async {
        let url = URL(string: "https://relay.example/pair#v=1&r=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")!
        var current: URL? = url
        let provider = PairingShareProviderFactory.prepare { current }
        XCTAssertNotNil(provider)
        current = nil

        do {
            _ = try await loadData(from: provider!, typeIdentifier: UTType.url.identifier)
            XCTFail("Expected the stale representation to fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? PairingShareProviderError.invitationUnavailable)
                }
            }
        }
    }
}
