import XCTest
@testable import ClickBridgeMac

@MainActor
final class PairingControllerTests: XCTestCase {
    private let requestID = "11111111-1111-4111-8111-111111111111"
    private let claimID = "22222222-2222-4222-8222-222222222222"
    private let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testUnavailableCapabilityCannotCreateInvitation() async {
        let transport = PairingTransportRecorder()
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { self.requestID },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await controller.refreshStatus(capabilityAvailable: false)
        await controller.beginPairing()

        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertTrue(await transport.messages().isEmpty)
    }

    func testLegacyEnrollmentRequiresReplacementConfirmationBeforeCreate() async throws {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))

        await controller.beginPairing()
        XCTAssertEqual(controller.state, .replacementConfirmation)
        XCTAssertEqual(await transport.messages().count, 1)

        await controller.confirmReplacement()
        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 2)
        guard case .pairCreate(let create) = messages[1] else { return XCTFail("Expected pair.create") }
        XCTAssertEqual(create.requestId, requestID)
    }

    func testInvitationUsesOneCanonicalHTTPSPayloadForQRAndSharing() async throws {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .paired,
            activePhoneCredentialVersion: 3
        )))
        await controller.beginPairing()
        await controller.confirmReplacement()
        await controller.receive(.pairCreated(PairCreated(
            requestId: requestID,
            reference: reference,
            expiresAtUnixMs: 1_300_000
        )))

        guard case .invitation(let invitation) = controller.state else {
            return XCTFail("Expected invitation")
        }
        XCTAssertEqual(invitation.url.absoluteString,
                       "https://relay.example/pair#v=1&r=\(reference)")
        XCTAssertEqual(invitation.qrPayload, invitation.url.absoluteString)
        XCTAssertEqual(invitation.sharePayload, invitation.url.absoluteString)
        XCTAssertFalse(invitation.accessibilityLabel.contains(reference))
    }

    func testStaleEventsAreIgnoredAndMismatchSendsDeny() async throws {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()
        await controller.confirmReplacement()
        await controller.receive(.pairClaimedMac(PairClaimedMac(
            requestId: "33333333-3333-4333-8333-333333333333",
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_300_000,
            clientKind: .ios
        )))
        XCTAssertEqual(controller.state, .creating)

        await controller.receive(.pairClaimedMac(PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_300_000,
            clientKind: .ios
        )))
        guard case .approval(let approval) = controller.state else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(approval.accessibilityCode, "Confirmation code 482 917")

        await controller.codesDoNotMatch()
        guard case .pairDeny(let deny) = await transport.messages().last else {
            return XCTFail("Expected pair.deny")
        }
        XCTAssertEqual(deny.claimId, claimID)
    }

    func testExpiryCancelsInvitationAndAllowsRegeneration() async throws {
        let transport = PairingTransportRecorder()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { self.requestID },
            now: { now }
        )
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()
        await controller.confirmReplacement()
        await controller.receive(.pairCreated(PairCreated(
            requestId: requestID,
            reference: reference,
            expiresAtUnixMs: 1_001_000
        )))

        now = Date(timeIntervalSince1970: 1_002)
        await controller.refreshExpiry()
        XCTAssertEqual(controller.state, .expired)

        await controller.regenerate()
        guard case .pairCreate = await transport.messages().last else {
            return XCTFail("Expected a regenerated pair.create")
        }
    }

    private func subject(transport: PairingTransportRecorder) -> PairingController {
        PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { self.requestID },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }
}

private actor PairingTransportRecorder: PairingTransport {
    private var sent: [WireMessage] = []

    func sendPairing(_ message: WireMessage) async throws { sent.append(message) }
    func messages() -> [WireMessage] { sent }
}
