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
        let messages = await transport.messages()
        XCTAssertTrue(messages.isEmpty)
    }

    func testConfirmReplacementCannotBypassCapabilityAndEnrollmentStatus() async {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)

        await controller.confirmReplacement()

        XCTAssertEqual(controller.state, .unavailable)
        let messages = await transport.messages()
        XCTAssertTrue(messages.isEmpty)
    }

    func testRegenerateAfterStatusFailureRetriesStatusInsteadOfCreating() async {
        let transport = PairingTransportRecorder(results: [.failure(TestTransportError.failed), .success(())])
        let controller = subject(transport: transport)

        await controller.refreshStatus(capabilityAvailable: true)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.recoveryAction, .retry)
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
        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 2)
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
        let messagesBeforeConfirmation = await transport.messages()
        XCTAssertEqual(messagesBeforeConfirmation.count, 1)

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
        XCTAssertEqual(controller.recoveryAction, .retry)

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
        XCTAssertEqual(controller.recoveryAction, .retry)

        await controller.regenerate()

        guard case .pairCreate = await transport.messages().last else {
            return XCTFail("Expected pair.create retry")
        }
    }

    func testApprovalFailureReconcilesStatusWithoutRegeneratingInvitation() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed)
        ])
        let controller = subject(transport: transport)
        await moveToApproval(controller)
        await controller.approve()
        XCTAssertEqual(controller.recoveryAction, .startAgain)
        await controller.regenerate()

        let messagesAfterRegenerate = await transport.messages()
        XCTAssertEqual(messagesAfterRegenerate.count, 4)
        guard case .pairStatusRequest = messagesAfterRegenerate.last else {
            return XCTFail("Expected fresh status instead of a replacement invitation")
        }
    }

    func testApprovalExpiryStartsAgainWithFreshStatus() async {
        let transport = PairingTransportRecorder()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { self.requestID },
            now: { now }
        )
        await moveToApproval(controller)

        now = Date(timeIntervalSince1970: 1_301)
        await controller.refreshExpiry()
        XCTAssertEqual(controller.state, .expired)
        XCTAssertEqual(controller.recoveryAction, .startAgain)

        await controller.regenerate()
        guard case .pairStatusRequest = await transport.messages().last else {
            return XCTFail("Expected fresh status after approval expiry")
        }
    }

    func testApproveSendFailureStartsAgainWithFreshStatus() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed), .success(())
        ])
        let controller = subject(transport: transport)
        await moveToApproval(controller)

        await controller.approve()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.recoveryAction, .startAgain)

        await controller.regenerate()
        guard case .pairStatusRequest = await transport.messages().last else {
            return XCTFail("Expected fresh status after approve send failure")
        }
    }

    func testDenySendFailureStartsAgainWithFreshStatus() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed), .success(())
        ])
        let controller = subject(transport: transport)
        await moveToApproval(controller)

        await controller.deny()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.recoveryAction, .startAgain)

        await controller.regenerate()
        guard case .pairStatusRequest = await transport.messages().last else {
            return XCTFail("Expected fresh status after deny send failure")
        }
    }

    func testDenialCompletionStartsAgainWithFreshStatus() async {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await moveToApproval(controller)

        await controller.deny()
        XCTAssertEqual(controller.state, .denied)
        XCTAssertEqual(controller.recoveryAction, .startAgain)

        await controller.regenerate()
        guard case .pairStatusRequest(let statusRequest) = await transport.messages().last else {
            return XCTFail("Expected fresh status after denial")
        }
        await controller.receive(.pairStatus(PairStatus(
            requestId: statusRequest.requestId,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))
        await controller.beginPairing()
        XCTAssertEqual(controller.state, .replacementConfirmation)
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

    func testSuspendedCancelAbsorbsMatchingClaimAndApproveCannotEscapeCancellation() async throws {
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
        let approve = Task { await controller.approve() }
        await Task.yield()
        await Task.yield()

        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(controller.state, .cancelling)
        if messages.count > 3 {
            await transport.completeSend(at: 3, with: .success(()))
        }
        await approve.value
        await transport.completeSend(at: 2, with: .success(()))
        await cancel.value

        XCTAssertEqual(controller.state, .ready)
    }

    func testCancellationAcknowledgementEndsCancellationAndClearsCorrelation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let cancel = Task { await controller.cancel() }
        try await transport.waitUntilSendCount(3)
        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: nil,
            reason: .cancelled
        )))
        XCTAssertEqual(controller.state, .ready)

        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: claimID,
            reason: .denied
        )))
        XCTAssertEqual(controller.state, .ready)

        await transport.completeSend(at: 2, with: .success(()))
        await cancel.value
        XCTAssertEqual(controller.state, .ready)
    }

    func testUnexpectedCancellationFailureRequiresStatusReconciliation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let cancel = Task { await controller.cancel() }
        try await transport.waitUntilSendCount(3)
        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: claimID,
            reason: .invalidRequest
        )))
        XCTAssertEqual(controller.state, .cancelFailed)

        await transport.completeSend(at: 2, with: .success(()))
        await cancel.value
        XCTAssertEqual(controller.state, .cancelFailed)

        let reconcile = Task { await controller.regenerate() }
        try await transport.waitUntilSendCount(4)
        guard case .pairStatusRequest = await transport.messages().last else {
            return XCTFail("Expected status reconciliation after an uncertain cancellation")
        }
        await transport.completeSend(at: 3, with: .success(()))
        await reconcile.value
    }

    func testDenialAcknowledgementEndsDenialAndClearsCorrelation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let deny = Task { await controller.deny() }
        try await transport.waitUntilSendCount(3)
        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: claimID,
            reason: .denied
        )))
        XCTAssertEqual(controller.state, .denied)

        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: nil,
            reason: .expired
        )))
        XCTAssertEqual(controller.state, .denied)

        await transport.completeSend(at: 2, with: .failure(TestTransportError.failed))
        await deny.value
        XCTAssertEqual(controller.state, .denied)
    }

    func testRequestOnlyFailureCannotReplaceApprovalOrCompletedState() async {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await moveToApproval(controller)

        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: nil,
            reason: .expired
        )))
        guard case .approval = controller.state else {
            return XCTFail("A request-only failure must not terminate an active claim")
        }

        await controller.approve()
        await controller.receive(.pairCompleted(PairCompleted(
            requestId: requestID,
            claimId: claimID,
            activePhoneCredentialVersion: 1
        )))
        XCTAssertEqual(controller.state, .completed(activePhoneCredentialVersion: 1))

        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: claimID,
            reason: .activationFailed
        )))
        XCTAssertEqual(controller.state, .completed(activePhoneCredentialVersion: 1))
    }

    func testStaleRequestAndClaimFailuresCannotReplaceReadyState() async {
        let transport = PairingTransportRecorder()
        let controller = subject(transport: transport)
        await controller.refreshStatus(capabilityAvailable: true)
        await controller.receive(.pairStatus(PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )))

        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: nil,
            reason: .expired
        )))
        await controller.receive(.pairFailed(PairFailed(
            requestId: requestID,
            claimId: claimID,
            reason: .denied
        )))

        XCTAssertEqual(controller.state, .ready)
    }

    func testSuspendedApproveCompletionCannotOverwriteCapabilityRevocation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let approve = Task { await controller.approve() }
        try await transport.waitUntilSendCount(3)
        await controller.refreshStatus(capabilityAvailable: false)
        await transport.completeSend(at: 2, with: .failure(TestTransportError.failed))
        await approve.value

        XCTAssertEqual(controller.state, .unavailable)
    }

    func testSuspendedApproveSuccessCannotOverwriteCapabilityRevocation() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let approve = Task { await controller.approve() }
        try await transport.waitUntilSendCount(3)
        await controller.refreshStatus(capabilityAvailable: false)
        await transport.completeSend(at: 2, with: .success(()))
        await approve.value

        XCTAssertEqual(controller.state, .unavailable)
    }

    func testSuspendedDenyCompletionCannotOverwriteNewerStatusRequest() async throws {
        let identifiers = RequestIDSequence([
            requestID,
            requestID,
            "44444444-4444-4444-8444-444444444444"
        ])
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { identifiers.next() },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await moveToApproval(controller, transport: transport)

        let deny = Task { await controller.deny() }
        try await transport.waitUntilSendCount(3)
        let refresh = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(4)
        await transport.completeSend(at: 2, with: .failure(TestTransportError.failed))
        await deny.value

        XCTAssertEqual(controller.state, .checkingStatus)
        await transport.completeSend(at: 3, with: .success(()))
        await refresh.value
    }

    func testSuspendedDenySuccessCannotOverwriteNewerStatusRequest() async throws {
        let identifiers = RequestIDSequence([
            requestID,
            requestID,
            "44444444-4444-4444-8444-444444444444"
        ])
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = PairingController(
            transport: transport,
            relayURL: URL(string: "wss://relay.example/ws")!,
            requestID: { identifiers.next() },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await moveToApproval(controller, transport: transport)

        let deny = Task { await controller.deny() }
        try await transport.waitUntilSendCount(3)
        let refresh = Task { await controller.refreshStatus(capabilityAvailable: true) }
        try await transport.waitUntilSendCount(4)
        await transport.completeSend(at: 2, with: .success(()))
        await deny.value

        XCTAssertEqual(controller.state, .checkingStatus)
        await transport.completeSend(at: 3, with: .success(()))
        await refresh.value
    }

    func testSuspendedDenyBlocksContradictoryApprove() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let deny = Task { await controller.deny() }
        try await transport.waitUntilSendCount(3)
        await controller.approve()

        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 3)
        await transport.completeSend(at: 2, with: .success(()))
        await deny.value
        XCTAssertEqual(controller.state, .denied)
    }

    func testSuspendedCancelBlocksContradictoryApprove() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let cancel = Task { await controller.cancel() }
        try await transport.waitUntilSendCount(3)
        await controller.approve()

        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 3)
        await transport.completeSend(at: 2, with: .success(()))
        await cancel.value
        XCTAssertEqual(controller.state, .ready)
    }

    func testSuspendedApproveBlocksContradictoryCancel() async throws {
        let transport = PairingTransportRecorder(suspendSends: true)
        let controller = subject(transport: transport)
        try await moveToApproval(controller, transport: transport)

        let approve = Task { await controller.approve() }
        try await transport.waitUntilSendCount(3)
        await controller.cancel()

        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 3)
        await transport.completeSend(at: 2, with: .success(()))
        await approve.value
        XCTAssertEqual(controller.state, .approving)
    }

    func testCancelFailureRequiresStatusReconciliationBeforePairingCanContinue() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed), .success(())
        ])
        let controller = subject(transport: transport)
        await moveToInvitation(controller)

        await controller.cancel()

        XCTAssertEqual(controller.state, .cancelFailed)
        XCTAssertEqual(controller.recoveryAction, .retry)
        await controller.beginPairing()
        await controller.confirmReplacement()
        await controller.approve()
        let messagesBeforeRegenerate = await transport.messages()
        XCTAssertEqual(messagesBeforeRegenerate.count, 3)

        await controller.regenerate()
        let messages = await transport.messages()
        XCTAssertEqual(messages.count, 4)
        guard case .pairStatusRequest = messages[3] else {
            return XCTFail("Expected status reconciliation after cancel failure")
        }
    }

    func testExpiryCancelFailureRequiresStatusReconciliation() async {
        let transport = PairingTransportRecorder(results: [
            .success(()), .success(()), .failure(TestTransportError.failed), .success(())
        ])
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

        XCTAssertEqual(controller.state, .cancelFailed)
        await controller.regenerate()
        guard case .pairStatusRequest = await transport.messages().last else {
            return XCTFail("Expected status reconciliation after expiry cancel failure")
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

    private func moveToApproval(
        _ controller: PairingController,
        transport: PairingTransportRecorder
    ) async throws {
        try await moveToInvitation(controller, transport: transport)
        await controller.receive(.pairClaimedMac(PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_300_000,
            clientKind: .ios
        )))
    }

    private func moveToInvitation(_ controller: PairingController) async {
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
