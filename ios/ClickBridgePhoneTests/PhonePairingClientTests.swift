import CryptoKit
import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhonePairingClientTests: XCTestCase {
    private let reference = String(repeating: "A", count: 43)
    private let credential = String(repeating: "b", count: 64)
    private let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!
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
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

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

        socket.emitText(#"{"type":"pair.active","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","activePhoneCredentialVersion":1}"#)

        XCTAssertEqual(try store.phoneToken(), credential)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(normal.configurations.last?.token, credential)
        XCTAssertEqual(subject.state.phase, .active)
    }

    func testExplicitReplacementAuthorizationKeepsLegacyActiveUntilActivation() throws {
        let oldToken = String(repeating: "a", count: 64)
        let secrets = PairingTestSecretStore()
        secrets.value = oldToken
        let store = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets
        )
        let factory = FakePhoneWebSocketFactory()
        let normal = FakePhoneActionTransport()
        let subject = makeSubject(
            store: store,
            factory: factory,
            scheduler: FakePhoneScheduler(),
            normalTransport: normal
        )
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )

        subject.start(
            link,
            replacementAuthorization: try XCTUnwrap(store.replacementAuthorization())
        )
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

        XCTAssertEqual(try store.phoneToken(), oldToken)
        XCTAssertEqual(try store.pendingPairingCredential(), .init(token: credential, version: 1))

        socket.emitText(#"{"type":"pair.active","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","activePhoneCredentialVersion":1}"#)
        XCTAssertEqual(try store.phoneToken(), credential)
        XCTAssertEqual(normal.configurations.map(\.token), [credential])
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
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        secrets.writeError = FakePhoneWebSocketError.sendFailed

        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

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

    func testAuthoritativeFailureAfterStagingDiscardsExactPendingCredential() throws {
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
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)
        XCTAssertNotNil(try store.pendingPairingCredential())

        socket.emitText(#"{"type":"pair.failed","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","reason":"activation_failed"}"#)

        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(subject.state.failure, "activation_failed")
    }

    func testCredentialReplacedCloseAfterStagingDiscardsExactPendingCredential() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let subject = makeSubject(store: store, factory: factory, scheduler: FakePhoneScheduler())
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )
        subject.start(link)
        let socket = factory.sockets[0]
        socket.emitOpen()
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

        socket.emitClose(code: PhoneProtocolV1.credentialReplacedCloseCode)

        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(subject.state.phase, .replaced)
    }

    func testAmbiguousDisconnectAfterStagingPreservesPendingCredential() throws {
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
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579500000}"#)
        socket.emitText(#"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","credential":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credentialVersion":1}"#)

        socket.emitClose(code: 1006)

        XCTAssertEqual(try store.pendingPairingCredential(), .init(token: credential, version: 1))
        XCTAssertEqual(subject.state.failure, "disconnected")
    }

    func testRandomnessFailureStopsBeforeCreatingOrOpeningSocket() throws {
        let store = try makeStore()
        let factory = FakePhoneWebSocketFactory()
        let scheduler = FakePhoneScheduler()
        let subject = PhonePairingClient(
            socketFactory: factory,
            settings: store,
            normalTransport: FakePhoneActionTransport(),
            clock: FakePhoneClock(),
            scheduler: scheduler,
            claimID: { self.claimID },
            randomBytes: { throw FakePhoneWebSocketError.sendFailed }
        )
        let link = try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        )

        subject.start(link)

        XCTAssertTrue(factory.sockets.isEmpty)
        XCTAssertEqual(subject.state.failure, "pairing_unavailable")
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
        socket.emitText(#"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","confirmationCode":"123 456","expiresAtUnixMs":1786579200500}"#)

        scheduler.runFirst(after: 0.5)

        XCTAssertEqual(subject.state.phase, .failed)
        XCTAssertEqual(subject.state.failure, "expired")
        XCTAssertEqual(factory.sockets.count, 1)
    }

    func testLostTerminalRecoveryAuthenticatesPendingBeforePromotion() async throws {
        let store = try makeStore()
        let pending = PhonePairingCredential(token: credential, version: 1)
        try store.stagePairingCredential(
            pending,
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
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

        XCTAssertEqual(recovered, .recovered)
        XCTAssertEqual(authenticated.map(\.token), [credential])
        XCTAssertEqual(try store.phoneToken(), credential)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertEqual(normal.configurations.map(\.token), [credential])
    }

    func testRecoveryRejectsCallerOriginMismatchBeforeAuthenticationOrConnect() async throws {
        let store = try makeStore()
        let pending = PhonePairingCredential(token: credential, version: 1)
        try store.stagePairingCredential(
            pending,
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let normal = FakePhoneActionTransport()
        var authenticationCalls = 0
        let subject = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(),
            settings: store,
            normalTransport: normal,
            clock: FakePhoneClock(),
            scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce },
            authenticatePending: { _ in authenticationCalls += 1; return true }
        )

        let result = await subject.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://hostile.example/ws"))
        )

        XCTAssertEqual(result, .originMismatch)
        XCTAssertEqual(authenticationCalls, 0)
        XCTAssertTrue(normal.configurations.isEmpty)
        XCTAssertEqual(try store.pendingPairingCredential(), pending)
    }

    func testRecoveryDistinguishesNoPendingAuthenticationAndStorageFailures() async throws {
        let emptyStore = try makeStore()
        let noPending = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: emptyStore,
            normalTransport: FakePhoneActionTransport(), clock: FakePhoneClock(),
            scheduler: FakePhoneScheduler(), randomBytes: { self.nonce }
        )
        let noPendingResult = await noPending.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        XCTAssertEqual(noPendingResult, .noPending)

        let rejectedStore = try makeStore()
        try rejectedStore.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let rejected = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: rejectedStore,
            normalTransport: FakePhoneActionTransport(), clock: FakePhoneClock(),
            scheduler: FakePhoneScheduler(), randomBytes: { self.nonce },
            authenticatePending: { _ in false }
        )
        let rejectedResult = await rejected.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        XCTAssertEqual(rejectedResult, .authenticationRejected)

        let secrets = PairingTestSecretStore()
        let brokenStore = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets
        )
        try brokenStore.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        secrets.readError = FakePhoneWebSocketError.sendFailed
        let normal = FakePhoneActionTransport()
        let broken = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: brokenStore,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in true }
        )
        let brokenResult = await broken.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        XCTAssertEqual(brokenResult, .storageReadFailed)
        XCTAssertTrue(normal.configurations.isEmpty)

        let corruptSecrets = PairingTestSecretStore()
        let corruptStore = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: corruptSecrets
        )
        corruptSecrets.value = "not-a-credential-record"
        let corrupt = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: corruptStore,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }
        )
        let corruptResult = await corrupt.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        XCTAssertEqual(corruptResult, .storageCorrupt)
        XCTAssertTrue(normal.configurations.isEmpty)

        let promotionSecrets = PairingTestSecretStore()
        let promotionStore = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: promotionSecrets
        )
        try promotionStore.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        promotionSecrets.writeError = FakePhoneWebSocketError.sendFailed
        let promotionNormal = FakePhoneActionTransport()
        let promotion = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: promotionStore,
            normalTransport: promotionNormal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in true }
        )
        let promotionResult = await promotion.recoverPending(
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        XCTAssertEqual(promotionResult, .promotionFailed)
        XCTAssertTrue(promotionNormal.configurations.isEmpty)
    }

    func testRecoveryReportsSupersededWhenNewerSaveWinsDuringAuthentication() async throws {
        let secrets = PairingTestSecretStore()
        let store = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets
        )
        try store.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let gate = PairingAuthenticationGate()
        let normal = FakePhoneActionTransport()
        let subject = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: store,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in await gate.wait() }
        )

        let recovery = Task {
            await subject.recoverPending(
                relayWebSocketURL: try! XCTUnwrap(URL(string: "wss://relay.example/ws"))
            )
        }
        await gate.waitUntilEntered()
        let newerToken = String(repeating: "c", count: 64)
        try store.savePhoneToken(newerToken)
        gate.resume(authenticated: true)

        let result = await recovery.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(try store.phoneToken(), newerToken)
        XCTAssertTrue(normal.configurations.isEmpty)
    }

    func testRecoveryReportsSupersededWhenPendingIsDiscardedDuringAuthentication() async throws {
        let store = try makeStore()
        let pending = try store.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let gate = PairingAuthenticationGate()
        let normal = FakePhoneActionTransport()
        let subject = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: store,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in await gate.wait() }
        )

        let recovery = Task {
            await subject.recoverPending(
                relayWebSocketURL: try! XCTUnwrap(URL(string: "wss://relay.example/ws"))
            )
        }
        await gate.waitUntilEntered()
        try store.discardPairingCredential(pending)
        gate.resume(authenticated: true)

        let result = await recovery.value
        XCTAssertEqual(result, .superseded)
        XCTAssertNil(try store.pendingPairingCredential())
        XCTAssertTrue(normal.configurations.isEmpty)
    }

    func testRecoveryReportsStorageCorruptWhenRecordCorruptsDuringAuthentication() async throws {
        let secrets = PairingTestSecretStore()
        let store = try PhoneSettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets
        )
        try store.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let gate = PairingAuthenticationGate()
        let normal = FakePhoneActionTransport()
        let subject = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: store,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in await gate.wait() }
        )

        let recovery = Task {
            await subject.recoverPending(
                relayWebSocketURL: try! XCTUnwrap(URL(string: "wss://relay.example/ws"))
            )
        }
        await gate.waitUntilEntered()
        secrets.value = "corrupt-pairing-record"
        gate.resume(authenticated: true)

        let result = await recovery.value
        XCTAssertEqual(result, .storageCorrupt)
        XCTAssertTrue(normal.configurations.isEmpty)
    }

    func testCancelDuringRecoveryAuthenticationSupersedesRecovery() async throws {
        let store = try makeStore()
        try store.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let gate = PairingAuthenticationGate()
        let normal = FakePhoneActionTransport()
        let subject = PhonePairingClient(
            socketFactory: FakePhoneWebSocketFactory(), settings: store,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            randomBytes: { self.nonce }, authenticatePending: { _ in await gate.wait() }
        )

        let recovery = Task {
            await subject.recoverPending(
                relayWebSocketURL: try! XCTUnwrap(URL(string: "wss://relay.example/ws"))
            )
        }
        await gate.waitUntilEntered()
        subject.cancel()
        gate.resume(authenticated: true)

        let result = await recovery.value
        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(normal.configurations.isEmpty)
    }

    func testNewPairingDuringRecoveryAuthenticationSupersedesRecovery() async throws {
        let store = try makeStore()
        try store.stagePairingCredential(
            .init(token: credential, version: 1),
            relayWebSocketURL: try XCTUnwrap(URL(string: "wss://relay.example/ws"))
        )
        let gate = PairingAuthenticationGate()
        let factory = FakePhoneWebSocketFactory()
        let normal = FakePhoneActionTransport()
        let subject = PhonePairingClient(
            socketFactory: factory, settings: store,
            normalTransport: normal, clock: FakePhoneClock(), scheduler: FakePhoneScheduler(),
            claimID: { self.claimID }, randomBytes: { self.nonce },
            authenticatePending: { _ in await gate.wait() }
        )

        let recovery = Task {
            await subject.recoverPending(
                relayWebSocketURL: try! XCTUnwrap(URL(string: "wss://relay.example/ws"))
            )
        }
        await gate.waitUntilEntered()
        subject.start(try PhonePairingLink.parse(
            XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)")),
            expectedHost: "relay.example"
        ))
        gate.resume(authenticated: true)

        let result = await recovery.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(subject.state.phase, .connecting)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertTrue(normal.configurations.isEmpty)
    }
}

@MainActor
private final class PairingAuthenticationGate {
    private var authenticationContinuation: CheckedContinuation<Bool, Never>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func wait() async -> Bool {
        entered = true
        let entryContinuations = self.entryContinuations
        self.entryContinuations.removeAll()
        entryContinuations.forEach { $0.resume() }
        return await withCheckedContinuation { authenticationContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryContinuations.append($0) }
    }

    func resume(authenticated: Bool) {
        authenticationContinuation?.resume(returning: authenticated)
        authenticationContinuation = nil
    }
}

private final class PairingTestSecretStore: SecretStoring, @unchecked Sendable {
    var value: String?
    var readError: Error?
    var writeError: Error?
    func read(account: String) throws -> String? {
        if let readError { throw readError }
        return value
    }
    func write(_ value: String, account: String) throws {
        if let writeError { throw writeError }
        self.value = value
    }
    func delete(account: String) throws { value = nil }
}
