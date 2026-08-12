import CryptoKit
import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhonePairingClientTests: XCTestCase {
    private let reference = String(repeating: "A", count: 43)
    private let credential = String(repeating: "b", count: 64)
    private let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030")!
    private let nonce = Data(repeating: 0xcc, count: 32)

    private func makeStore() throws -> PhoneSettingsStore {
        try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            secrets: PairingTestSecretStore()
        )
    }

    private func makeSubject(
        store: PhoneSettingsStore,
        factory: FakePhoneWebSocketFactory,
        scheduler: FakePhoneScheduler,
        normalTransport: FakePhoneActionTransport? = nil
    ) -> PhonePairingClient {
        let normalTransport = normalTransport ?? FakePhoneActionTransport()
        return PhonePairingClient(
            socketFactory: factory,
            settings: store,
            normalTransport: normalTransport,
            clock: FakePhoneClock(),
            scheduler: scheduler,
            claimID: { self.claimID },
            randomBytes: { self.nonce }
        )
    }

    func testDedicatedSocketClaimsAndPublishesOnlyMatchingClaimState() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )

        subject.start(link)
        let socket = try XCTUnwrap(factory.sockets.first)
        XCTAssertEqual(socket.openedURLs.first?.absoluteString, "wss://relay.example/ws")
        socket.emitOpen()

        let claim = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.first).utf8)) as? [String: Any]
        )
        XCTAssertEqual(claim["type"] as? String, "pair.claim")
        XCTAssertEqual(claim["reference"] as? String, reference)
        XCTAssertEqual(claim["claimId"] as? String, claimID.uuidString.lowercased())
        XCTAssertEqual(claim["sessionNonce"] as? String, String(repeating: "cc", count: 32))

        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"11111111-1111-1111-1111-111111111111","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        XCTAssertEqual(subject.state.phase, .failed)
    }

    func testStagesCredentialBeforeSendingExactActivationHMACThenPromotesOnActive() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let normal = FakePhoneActionTransport()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler, normalTransport: normal)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

        XCTAssertEqual(try store.pendingPairingCredential(), .init(token: credential, version: 1))
        XCTAssertNil(try store.phoneToken())
        let ack = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(socket.sentTexts.last!.utf8)) as? [String: Any]
        )
        let key = SymmetricKey(data: Data(repeating: 0xbb, count: 32))
        let expectedProof = HMAC<SHA256>.authenticationCode(
            for: Data("clickbridge-pair-activate:v1:\(claimID.uuidString.lowercased()):1".utf8),
            using: key
        ).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ack["proof"] as? String, expectedProof)

        socket.emitText(#"{"type":"pair.active","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","activePhoneCredentialVersion":1}"#)

        XCTAssertEqual(try store.phoneToken(), credential)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(normal.configurations.last?.token, credential)
        XCTAssertEqual(subject.state.phase, .active)
    }

    func testCancelInvalidatesDelayedSendCompletionAndDoesNotReconnect() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)
        let socket = factory.sockets[0]
        socket.automaticallyCompletesSends = false
        socket.emitOpen()

        subject.cancel()
        socket.completeNextSend(error: FakePhoneWebSocketError.sendFailed)

        XCTAssertEqual(subject.state.phase, .cancelled)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertTrue(scheduler.entries.isEmpty)
    }

    func testCredentialWriteFailureSendsNoAcknowledgementAndKeepsNoPendingSlot() throws {
        let secrets = PairingTestSecretStore()
        let store = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            secrets: secrets
        )
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        secrets.writeError = FakePhoneWebSocketError.sendFailed

        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

        XCTAssertEqual(socket.sentTexts.filter { $0.contains("pair.credential.ack") }.count, 0)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(subject.state.failure, "storage_failed")
    }

    func testCredentialReplacementCloseIsTerminalAndNeverReconnects() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)

        factory.sockets[0].emitClose(code: PhoneProtocolV1.credentialReplacedCloseCode)

        XCTAssertEqual(subject.state.phase, .replaced)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertTrue(scheduler.entries.isEmpty)
    }

    func testApprovalExpiryClosesClaimantWithoutAReconnect() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = makeSubject(store: store, factory: factory, scheduler: scheduler)
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030","confirmationCode":"123 456","expiresAtUnixMs":1786579200500}"#)

        scheduler.runFirst(after: 0.5)

        XCTAssertEqual(subject.state.phase, .failed)
        XCTAssertEqual(subject.state.failure, "expired")
        XCTAssertEqual(factory.sockets.count, 1)
    }

    func testLostTerminalRecoveryAuthenticatesPendingBeforePromotion() async throws {
        let store = try makeStore()
        let pending = PhonePairingCredential(token: credential, version: 1)
        try store.stagePairingCredential(pending)
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let normal = FakePhoneActionTransport()
        var authenticated: [RelayConfiguration] = []
        let subject = PhonePairingClient(
            socketFactory: factory,
            settings: store,
            normalTransport: normal,
            clock: FakePhoneClock(),
            scheduler: scheduler,
            claimID: { self.claimID },
            randomBytes: { self.nonce },
            authenticatePending: { configuration in
                authenticated.append(configuration)
                return true
            }
        )

        let recovered = await subject.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )

        XCTAssertTrue(recovered)
        XCTAssertEqual(authenticated.map(\.token), [credential])
        XCTAssertEqual(try store.phoneToken(), credential)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(normal.configurations.map(\.token), [credential])
    }
}

private final class PairingTestSecretStore: SecretStoring, @unchecked Sendable {
    var value: String?
    var writeError: Error?
    func read(account: String) throws -> String? { value }
    func write(_ value: String, account: String) throws {
        if let writeError { throw writeError }
        self.value = value
    }
    func delete(account: String) throws { value = nil }
}
