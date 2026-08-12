import XCTest
@testable import ClickBridgePhone

final class PhoneWireProtocolTests: XCTestCase {
    private let actionID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030de")!

    func testActionRequestEncodesExactProtocolFieldsAndLifetime() throws {
        let request = ActionRequest(
            actionID: actionID,
            action: "click",
            issuedAtUnixMilliseconds: 1_786_579_200_000,
            expiresAtUnixMilliseconds: 1_786_579_202_000
        )

        let data = Data(try PhoneClientMessage.actionRequest(request).encodedText().utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["type", "v", "actionId", "action", "issuedAtUnixMs", "expiresAtUnixMs"]
        )
        XCTAssertEqual(object["type"] as? String, "action.request")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["actionId"] as? String, actionID.uuidString.lowercased())
        XCTAssertEqual(object["action"] as? String, "click")
        XCTAssertEqual(
            (object["expiresAtUnixMs"] as! Double) - (object["issuedAtUnixMs"] as! Double),
            2_000
        )
        XCTAssertEqual(PhoneClientMessage.actionRequest(request).actionID, actionID)
    }

    func testAllOutboundMessagesUseFlatExactWireObjects() throws {
        let token = String(repeating: "a", count: 64)
        let syncID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030ab")!
        let cases: [(PhoneClientMessage, Set<String>)] = [
            (.hello(Hello(role: "phone", token: token)), ["type", "v", "role", "token"]),
            (.heartbeatRequest(HeartbeatRequest(sequence: 7)), ["type", "v", "sequence"]),
            (.timeSyncRequest(TimeSyncRequest(syncID: syncID, phoneSendUnixMilliseconds: 10)),
             ["type", "v", "syncId", "phoneSendUnixMs"]),
        ]

        for (message, keys) in cases {
            let data = Data(try message.encodedText().utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), keys)
            XCTAssertEqual(object["v"] as? Int, 1)
        }
    }

    /// PhoneWireProtocol.swift is a hand-written mirror of the JavaScript
    /// runtime constants — Swift cannot import them. Message *shapes* were
    /// already protected by the shared fixture corpus, but the *values* were
    /// not, so editing a timeout on the JS side and forgetting Swift would
    /// silently leave this client on a different schedule with every test green.
    ///
    /// The JS side asserts against the same file in
    /// relay/test/runtime-constants-parity.test.js.
    func testRuntimeConstantsMatchSharedFixture() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "runtime-constants", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        func expect(_ key: String) throws -> Double {
            let value = try XCTUnwrap(canonical[key] as? NSNumber, "missing \(key)")
            return value.doubleValue
        }

        // Stored in Swift as seconds; the fixture is canonical milliseconds.
        XCTAssertEqual(PhoneProtocolV1.heartbeatInterval, try expect("heartbeatIntervalMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.heartbeatTimeout, try expect("heartbeatTimeoutMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.resultTimeout, try expect("phoneResultTimeoutMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.reconnectBase, try expect("phoneReconnectBaseMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.reconnectCap, try expect("phoneReconnectCapMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.clockExchangeTimeout,
                       try expect("clockHealthExchangeTimeoutMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.clockRefreshInterval,
                       try expect("clockHealthRefreshMs") / 1000)
        XCTAssertEqual(PhoneProtocolV1.pairingTTL, try expect("pairingTtlMs") / 1000)

        // Stored in the same unit as the fixture.
        XCTAssertEqual(PhoneProtocolV1.clockSkewToleranceMilliseconds,
                       try expect("clockSkewToleranceMs"))
        XCTAssertEqual(PhoneProtocolV1.actionLifetimeMilliseconds, try expect("actionLifetimeMs"))
        XCTAssertEqual(Double(PhoneProtocolV1.clockSampleCount), try expect("clockHealthSamples"))
        XCTAssertEqual(Double(PhoneProtocolV1.maximumMessageBytes), try expect("maxMessageBytes"))
        XCTAssertEqual(Double(PhoneProtocolV1.version), try expect("protocolVersion"))
        XCTAssertEqual(Double(PhoneProtocolV1.pairingVersion), try expect("pairingVersion"))
        XCTAssertEqual(Double(PhoneProtocolV1.phoneTakenOverCloseCode),
                       try expect("phoneTakenOverCloseCode"))
        XCTAssertEqual(Double(PhoneProtocolV1.authenticationRejectedCloseCode),
                       try expect("authenticationRejectedCloseCode"))
        XCTAssertEqual(Double(PhoneProtocolV1.credentialReplacedCloseCode),
                       try expect("credentialReplacedCloseCode"))
    }

    func testCanonicalServerToPhoneFixturesDecode() throws {
        let fixtureNames = [
            "hello.ok", "heartbeat.ack", "state", "relay.ack", "relay.ack.mac-offline",
            "relay.ack.rejected-expired", "relay.ack.rejected-invalid-request",
            "action.result.posted", "action.result.rejected", "action.result.rejected.expired",
            "diagnostics.counters", "time.sync.response",
        ]

        for name in fixtureNames {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), name)
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertNoThrow(try StrictPhoneWireDecoder().decodeText(text), name)
        }
    }

    func testCanonicalPairingServerToPhoneFixturesDecode() throws {
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        let fixtures: [(String, PhonePairingReceiveState)] = [
            ("pair.claimed.phone", .claiming),
            ("pair.credential", .awaitingCredential),
            ("pair.active", .awaitingActivation),
            ("pair.failed.claimant", .claiming),
        ]

        for (name, state) in fixtures {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), name)
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let context = PhonePairingReceiveContext(claimID: claimID, generation: 7, state: state)
            XCTAssertNoThrow(
                try StrictPhoneWireDecoder().decodePairingText(
                    text,
                    context: context,
                    activeGeneration: 7
                ),
                name
            )
        }
    }

    func testPairingServerFramesRejectOrdinaryWrongStateWrongClaimAndStaleGeneration() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "pair.claimed.phone", withExtension: "json")
        )
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        let otherClaimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e3")!
        let current = PhonePairingReceiveContext(claimID: claimID, generation: 7, state: .claiming)

        XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text))
        XCTAssertThrowsError(
            try StrictPhoneWireDecoder().decodePairingText(
                text,
                context: PhonePairingReceiveContext(
                    claimID: claimID,
                    generation: 7,
                    state: .awaitingCredential
                ),
                activeGeneration: 7
            )
        )
        XCTAssertThrowsError(
            try StrictPhoneWireDecoder().decodePairingText(
                text,
                context: PhonePairingReceiveContext(
                    claimID: otherClaimID,
                    generation: 7,
                    state: .claiming
                ),
                activeGeneration: 7
            )
        )
        XCTAssertThrowsError(
            try StrictPhoneWireDecoder().decodePairingText(
                text,
                context: current,
                activeGeneration: 8
            )
        )
    }

    func testPairingClientMessagesEncodeTheirExactRoleAppropriateShapes() throws {
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        let cases: [(PhoneClientMessage, Set<String>, String)] = [
            (
                .pairClaim(PairClaim(
                    reference: String(repeating: "A", count: 43),
                    claimID: claimID,
                    sessionNonce: String(repeating: "b", count: 64),
                    clientKind: .ios
                )),
                ["type", "v", "reference", "claimId", "sessionNonce", "pairingVersion", "clientKind"],
                "pair.claim"
            ),
            (
                .pairCredentialAcknowledgement(PairCredentialAcknowledgement(
                    claimID: claimID,
                    credentialVersion: 1,
                    proof: String(repeating: "c", count: 64)
                )),
                ["type", "v", "claimId", "credentialVersion", "proof"],
                "pair.credential.ack"
            ),
            (
                .pairCancelClaim(PairCancelClaim(claimID: claimID)),
                ["type", "v", "claimId"],
                "pair.cancel.claim"
            ),
        ]

        for (message, keys, type) in cases {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(try message.encodedText().utf8)) as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), keys)
            XCTAssertEqual(object["type"] as? String, type)
        }
    }

    func testPairingClientEncodersRejectInvalidVersionNonceProofAndTypeBeforeNetwork() throws {
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!

        for nonce in [String(repeating: "B", count: 64), String(repeating: "b", count: 63)] {
            let claim = PairClaim(
                reference: String(repeating: "A", count: 43),
                claimID: claimID,
                sessionNonce: nonce,
                clientKind: .ios
            )
            XCTAssertThrowsError(try PhoneClientMessage.pairClaim(claim).encodedText())
        }

        var wrongPairingVersion = PairClaim(
            reference: String(repeating: "A", count: 43),
            claimID: claimID,
            sessionNonce: String(repeating: "b", count: 64),
            clientKind: .ios
        )
        wrongPairingVersion.pairingVersion = 0
        XCTAssertThrowsError(try PhoneClientMessage.pairClaim(wrongPairingVersion).encodedText())

        var wrongClaimType = wrongPairingVersion
        wrongClaimType.pairingVersion = PhoneProtocolV1.pairingVersion
        wrongClaimType.type = "pair.cancel.claim"
        XCTAssertThrowsError(try PhoneClientMessage.pairClaim(wrongClaimType).encodedText())

        var wrongClaimWireVersion = wrongPairingVersion
        wrongClaimWireVersion.pairingVersion = PhoneProtocolV1.pairingVersion
        wrongClaimWireVersion.v = 2
        XCTAssertThrowsError(try PhoneClientMessage.pairClaim(wrongClaimWireVersion).encodedText())

        for (version, proof) in [
            (0, String(repeating: "c", count: 64)),
            (1, String(repeating: "C", count: 64)),
            (1, String(repeating: "c", count: 63)),
            (Int.max, String(repeating: "c", count: 64)),
        ] {
            let acknowledgement = PairCredentialAcknowledgement(
                claimID: claimID,
                credentialVersion: version,
                proof: proof
            )
            XCTAssertThrowsError(
                try PhoneClientMessage.pairCredentialAcknowledgement(acknowledgement).encodedText()
            )
        }

        var wrongAckType = PairCredentialAcknowledgement(
            claimID: claimID,
            credentialVersion: 1,
            proof: String(repeating: "c", count: 64)
        )
        wrongAckType.type = "pair.claim"
        XCTAssertThrowsError(
            try PhoneClientMessage.pairCredentialAcknowledgement(wrongAckType).encodedText()
        )

        var wrongAckWireVersion = wrongAckType
        wrongAckWireVersion.type = "pair.credential.ack"
        wrongAckWireVersion.v = 2
        XCTAssertThrowsError(
            try PhoneClientMessage.pairCredentialAcknowledgement(wrongAckWireVersion).encodedText()
        )

        var wrongCancelType = PairCancelClaim(claimID: claimID)
        wrongCancelType.type = "pair.claim"
        XCTAssertThrowsError(try PhoneClientMessage.pairCancelClaim(wrongCancelType).encodedText())

        var wrongCancelWireVersion = PairCancelClaim(claimID: claimID)
        wrongCancelWireVersion.v = 2
        XCTAssertThrowsError(try PhoneClientMessage.pairCancelClaim(wrongCancelWireVersion).encodedText())
    }

    func testPairClaimEncodesOnlyCanonicalThirtyTwoByteBase64URLReferences() throws {
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        func claim(reference: String) -> PhoneClientMessage {
            .pairClaim(PairClaim(
                reference: reference,
                claimID: claimID,
                sessionNonce: String(repeating: "b", count: 64),
                clientKind: .ios
            ))
        }

        XCTAssertNoThrow(try claim(reference: String(repeating: "A", count: 43)).encodedText())
        for reference in [
            String(repeating: "A", count: 42) + "B",
            String(repeating: "A", count: 43) + "=",
            String(repeating: "A", count: 42) + "+",
        ] {
            XCTAssertThrowsError(try claim(reference: reference).encodedText(), reference)
        }
    }

    func testPhonePairingDecoderRejectsMacMessagesAndSecretBearingFailures() {
        let invalid = [
            #"{"type":"pair.created","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030e1","reference":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expiresAtUnixMs":1786500000000}"#,
            #"{"type":"pair.failed","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","reason":"expired","credential":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}"#,
            #"{"type":"pair.active","v":1,"claimId":"018F63F5-6F3D-7D21-88BC-9EF561F030E2","activePhoneCredentialVersion":1}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testPairingSafeIntegerOverflowFailsClosedInsteadOfTrapping() {
        let oversized = #"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","credential":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","credentialVersion":9223372036854775808}"#
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        let context = PhonePairingReceiveContext(
            claimID: claimID,
            generation: 7,
            state: .awaitingCredential
        )

        XCTAssertThrowsError(
            try StrictPhoneWireDecoder().decodePairingText(
                oversized,
                context: context,
                activeGeneration: 7
            )
        ) { error in
            XCTAssertEqual(error as? PhoneWireError, .invalidValue)
        }
    }

    func testCredentialRotationRejectsLegacyVersionZero() throws {
        let claimID = UUID(uuidString: "018f63f5-6f3d-7d21-88bc-9ef561f030e2")!
        let acknowledgement = PhoneClientMessage.pairCredentialAcknowledgement(
            PairCredentialAcknowledgement(
                claimID: claimID,
                credentialVersion: 0,
                proof: String(repeating: "c", count: 64)
            )
        )
        XCTAssertThrowsError(try acknowledgement.encodedText())

        for text in [
            #"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","credential":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","credentialVersion":0}"#,
            #"{"type":"pair.active","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","activePhoneCredentialVersion":0}"#,
        ] {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testExact4096ByteFramePassesAnd4097Fails() throws {
        let base = #"{"type":"heartbeat.ack","v":1,"sequence":7}"#
        let exact = base + String(repeating: " ", count: PhoneProtocolV1.maximumMessageBytes - base.utf8.count)

        XCTAssertEqual(exact.utf8.count, 4_096)
        XCTAssertNoThrow(try StrictPhoneWireDecoder().decodeText(exact))
        XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(exact + " ")) { error in
            XCTAssertEqual(error as? PhoneWireError, .tooLarge)
        }
    }

    func testBinaryFrameIsRejectedWithoutTextCoercion() {
        XCTAssertThrowsError(try StrictPhoneWireDecoder().rejectBinary(Data([0x7B, 0x7D]))) { error in
            XCTAssertEqual(error as? PhoneWireError, .binaryFrame)
        }
    }

    func testUnknownMissingAndWrongVersionFieldsAreRejected() {
        let invalid = [
            #"{"type":"heartbeat.ack","v":1,"sequence":7,"extra":true}"#,
            #"{"type":"heartbeat.ack","v":1}"#,
            #"{"type":"heartbeat.ack","v":2,"sequence":7}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testPhoneRoleRejectsMessagesThatAreNotServerToPhone() {
        let invalid = [
            #"{"type":"hello.ok","v":1,"role":"mac"}"#,
            #"{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"click","issuedAtUnixMs":1,"expiresAtUnixMs":2001}"#,
            #"{"type":"mac.state","v":1,"remoteEnabled":true,"permission":"ready"}"#,
            #"{"type":"heartbeat.request","v":1,"sequence":1}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testHeartbeatSequenceMustBeANonnegativeInteger() {
        for text in [
            #"{"type":"heartbeat.ack","v":1,"sequence":-1}"#,
            #"{"type":"heartbeat.ack","v":1,"sequence":1.5}"#,
            #"{"type":"heartbeat.ack","v":1,"sequence":true}"#,
        ] {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testRelayAckStatusReasonPairingIsStrict() {
        let invalid = [
            #"{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"forwarded","reason":"expired","relayProcessingUs":1}"#,
            #"{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"mac_offline","reason":"ok","relayProcessingUs":1}"#,
            #"{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"rejected","reason":"mac_offline","relayProcessingUs":1}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }

    func testActionResultStatusReasonAndOptionalTimestampPairingIsStrict() {
        let invalid = [
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"expired","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":2}"#,
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"ok","acceptedVia":"oci","macProcessingUs":1}"#,
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"rejected","reason":"ok","acceptedVia":"oci","macProcessingUs":1}"#,
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"rejected","reason":"expired","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":2}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictPhoneWireDecoder().decodeText(text), text)
        }
    }
}
