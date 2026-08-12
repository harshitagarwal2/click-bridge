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

    func testConfirmReplacementCannotBypassCapabilityAndEnrollmentStatus() async {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)

        await controller.confirmReplacement()

        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertTrue(await transport.messages().isEmpty)
    }

    func testRegenerateAfterStatusFailureRetriesStatusInsteadOfCreating() async {
        let transport = PairingTransportRecorder(results: [.failure(TestTransportError.failed), .success(())])
        let controller = subject(transport: transport)

        await controller.refreshStatus(capabilityAvailable: true)
        XCTAssertEqual(controller.state, .failed)
        await controller.regenerate()

        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 2)
        guard case .pairStatusRequest = messages[1] else {
            return XCTFail("Expected pair.status.request retry")
        }
    }

    func testFailedStatusClearsPriorEnrollmentGate() async {
        let transport = PairingTransportRecorder(results: [.success(()), .failure(TestTransportError.failed)])
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))

        await controller.refreshStatus(capabilityAvailable: true)
        await controller.beginPairing()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(await transport.messages().count, 2)
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

        await controller.receive(.pairCreated(PairCreated(
            requestId: requestID,
            reference: reference,
            expiresAtUnixMs: 1_300_000
        )))

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

    func testCreateFailureCanRetryOnlyFromItsInvitationSafeFailure() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .failure(TestTransportError.failed), .success(())
        ])
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()
        await controller.confirmReplacement()
        XCTAssertEqual(controller.state, .failed)

        await controller.regenerate()

        guard case .pairCreate = await transport.messages().last else {
            return XCTFail("Expected pair.create retry")
        }
    }

    func testApprovalFailureCannotRegenerateAReplacementInvitation() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed)
        ])
        let controller = subject(transport: transport)
        await moveToApproval(controller)
        await controller.approve()
        let countAfterFailure = await transport.messages().count

        await controller.regenerate()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(await transport.messages().count, countAfterFailure)
    }

    func testSuspendedStatusFailureCannotOverwriteCapabilityRevocation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        let refresh = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(1)

        await controller.refreshStatus(capabilityAvailable: false)
        await transport.completeSend(at: 0, with: .failure(TestTransportError.failed))
        await refresh.value

        XCTAssertEqual(controller.state, .unavailable)
    }

    func testOverlappingCreateFailureCannotOverwriteNewerStatusCheck() async throws {
        let identifiers = RequestIDSequence([
            requestID,
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444"
        ])
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { identifiers.next() },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let status = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(1)
        await transport.completeSend(at: 0, with: .success(()))
        await status.value
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()

        let create = Task { await controller.confirmReplacement() }
        try await transport.waitUntilSendCount(2)
        let newerStatus = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(3)
        await transport.completeSend(at: 1, with: .failure(TestTransportError.failed))
        await create.value

        XCTAssertEqual(controller.state, .checkingStatus)
        await transport.completeSend(at: 2, with: .success(()))
        await newerStatus.value
    }

    func testSuspendedCancelCannotEraseAClaimThatArrivedWhileSending() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToInvitation(controller, transport: transport)

        let cancel = Task { await controller.cancel() }
        try await transport.waitUntilSendCount(3)
        await controller.receive(.pairClaimedMac(PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_300_000,
            clientKind: .ios
        )))
        await transport.completeSend(at: 2, with: .success(()))
        await cancel.value

        guard case .approval = controller.state else {
            return XCTFail("Expected the newer claim to retain ownership")
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

    private func moveToApproval(_ controller: PairingController) async {
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
            expiresAtUnixMs: 1_300_000
        )))
        await controller.receive(.pairClaimedMac(PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_300_000,
            clientKind: .ios
        )))
    }

    private func moveToInvitation(
        _ controller: PairingController,
        transport: PairingTransportRecorder
    ) async throws {
        let status = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(1)
        await transport.completeSend(at: 0, with: .success(()))
        await status.value
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()
        let create = Task { await controller.confirmReplacement() }
        try await transport.waitUntilSendCount(2)
        await transport.completeSend(at: 1, with: .success(()))
        await create.value
        await controller.receive(.pairCreated(PairCreated(
            requestId: requestID,
            reference: reference,
            expiresAtUnixMs: 1_300_000
        )))
    }
}

private actor PairingTransportRecorder: PairingTransport {
    private var sent: [WireMessage] = []
    private var results: [Result<Void, TestTransportError>]
    private let suspendSends: Bool
    private var continuations: [CheckedContinuation<Void, Error>] = []

    init(results: [Result<Void, TestTransportError>] = [], suspendSends: Bool = false) {
        self.results = results
        self.suspendSends = suspendSends
    }

    func sendPairing(_ message: WireMessage) async throws {
        sent.append(message)
        if suspendSends {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } else if !results.isEmpty {
            try results.removeFirst().get()
        }
    }

    func messages() -> [WireMessage] { sent }

    func waitUntilSendCount(_ count: Int) async throws {
        for _ in 0..<10_000 {
            if sent.count >= count { return }
            await Task.yield()
        }
        throw TestTransportError.timedOut
    }

    func completeSend(at index: Int, with result: Result<Void, TestTransportError>) {
        switch result {
        case .success:
            continuations[index].resume()
        case .failure(let error):
            continuations[index].resume(throwing: error)
        }
    }
}

private enum TestTransportError: Error { case failed, timedOut }

private final class RequestIDSequence {
    private var values: [String]

    init(_ values: [String]) { self.values = values }
    func next() -> String { values.removeFirst() }
}
