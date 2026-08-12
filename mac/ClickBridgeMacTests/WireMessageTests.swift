import XCTest
@testable import ClickBridgeMac

final class WireMessageTests: XCTestCase {
    private func fixtureURLs() throws -> [URL] {
        let bundle = Bundle(for: Self.self)
        return (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isInvalidFixture(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("invalid-") || name.hasPrefix("pair-")
            || name == "malformed.json" || name == "oversized.json"
            || name == "unknown-field.json" || name == "wrong-role.json" || name == "wrong-version.json"
            || name == "binary-descriptor.json"
    }

    func testEveryCanonicalFixtureStrictlyDecodesAndSemanticallyRoundTrips() throws {
        let urls = try fixtureURLs()
        XCTAssertFalse(urls.isEmpty)
        for url in urls where !isInvalidFixture(url) && !url.lastPathComponent.hasPrefix("pair.") {
            let data = try Data(contentsOf: url)
            let decoded = try StrictWireDecoder().decodeText(String(decoding: data, as: UTF8.self))
            let encoded = try Wire.encode(decoded)
            XCTAssertEqual(try StrictWireDecoder().decodeText(encoded), decoded, url.lastPathComponent)
        }
    }

    func testMacPairingFixturesStrictlyDecodeForMacAndRoundTrip() throws {
        let names = [
            "pair.create", "pair.created", "pair.status.request", "pair.status", "pair.cancel", "pair.claimed.mac",
            "pair.approve", "pair.deny", "pair.completed", "pair.failed.mac-before-claim",
            "pair.failed.mac-after-claim",
        ]

        for name in names {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), name)
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let decoded = try StrictWireDecoder().decodeText(text)
            XCTAssertEqual(try StrictWireDecoder().decodeText(try Wire.encode(decoded)), decoded, name)
        }
    }

    func testMacPairingDecoderRejectsClaimantMessagesAndSecretBearingFailures() {
        let invalid = [
            #"{"type":"pair.claimed.phone","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","confirmationCode":"482 917","expiresAtUnixMs":1786500000000}"#,
            #"{"type":"pair.credential","v":1,"claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","credential":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","credentialVersion":1}"#,
            #"{"type":"pair.failed","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030e1","reason":"expired","credential":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}"#,
            #"{"type":"pair.completed","v":1,"requestId":"018F63F5-6F3D-7D21-88BC-9EF561F030E1","claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","activePhoneCredentialVersion":1}"#,
        ]

        for text in invalid {
            XCTAssertThrowsError(try StrictWireDecoder().decodeText(text), text)
        }
    }

    func testPairingStatusIsRequestedExplicitlyAndLegacyVersionZeroRequiresReplacement() throws {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e0"
        let request = WireMessage.pairStatusRequest(PairStatusRequest(requestId: requestID))
        let requestText = try Wire.encode(request)
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requestText.utf8)) as? [String: Any])["type"] as? String,
            "pair.status.request"
        )

        let statusText = #"{"type":"pair.status","v":1,"requestId":"\#(requestID)","enrollmentState":"legacy","activePhoneCredentialVersion":0}"#
        let decoded = try StrictWireDecoder().decodeText(statusText, for: .mac)
        guard case .pairStatus(let status) = decoded else {
            return XCTFail("expected pair.status")
        }
        XCTAssertEqual(status.requestId, requestID)
        XCTAssertEqual(status.activePhoneCredentialVersion, Constants.legacyPhoneCredentialVersion)
        XCTAssertEqual(status.enrollmentState, .legacy)
        XCTAssertTrue(status.requiresReplacementConfirmation)
    }

    func testMacPairingReferenceRequiresCanonicalThirtyTwoByteBase64URL() throws {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e1"
        let canonical = #"{"type":"pair.created","v":1,"requestId":"\#(requestID)","reference":"\#(String(repeating: "A", count: 43))","expiresAtUnixMs":1786500000000}"#
        XCTAssertNoThrow(try StrictWireDecoder().decodeText(canonical))

        for reference in [
            String(repeating: "A", count: 42) + "B",
            String(repeating: "A", count: 43) + "=",
            String(repeating: "A", count: 42) + "+",
        ] {
            let invalid = #"{"type":"pair.created","v":1,"requestId":"\#(requestID)","reference":"\#(reference)","expiresAtUnixMs":1786500000000}"#
            XCTAssertThrowsError(try StrictWireDecoder().decodeText(invalid), reference)
        }
    }

    func testMacApprovalCasesEncodeFixedWireTypes() throws {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e1"
        let claimID = "018f63f5-6f3d-7d21-88bc-9ef561f030e2"
        let approve = try Wire.encode(WireMessage.pairApprove(PairApprove(requestId: requestID, claimId: claimID)))
        let deny = try Wire.encode(WireMessage.pairDeny(PairDeny(requestId: requestID, claimId: claimID)))

        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(approve.utf8)) as? [String: Any])["type"] as? String, "pair.approve")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(deny.utf8)) as? [String: Any])["type"] as? String, "pair.deny")
    }

    func testEveryMacPairingRequestFailsClosedBeforeEncodingMalformedMetadata() {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e1"
        let claimID = "018f63f5-6f3d-7d21-88bc-9ef561f030e2"

        var create = PairCreate(requestId: requestID)
        create.type = "pair.status.request"
        XCTAssertThrowsError(try Wire.encode(create))
        create = PairCreate(requestId: requestID)
        create.v = 2
        XCTAssertThrowsError(try Wire.encode(create))
        create = PairCreate(requestId: requestID.uppercased())
        XCTAssertThrowsError(try Wire.encode(create))
        create = PairCreate(requestId: requestID)
        create.pairingVersion = 2
        XCTAssertThrowsError(try Wire.encode(create))

        var status = PairStatusRequest(requestId: requestID)
        status.type = "pair.create"
        XCTAssertThrowsError(try Wire.encode(status))
        status = PairStatusRequest(requestId: requestID)
        status.v = 2
        XCTAssertThrowsError(try Wire.encode(status))
        status = PairStatusRequest(requestId: requestID.uppercased())
        XCTAssertThrowsError(try Wire.encode(status))
        status = PairStatusRequest(requestId: requestID)
        status.pairingVersion = 2
        XCTAssertThrowsError(try Wire.encode(status))

        var cancel = PairCancel(requestId: requestID)
        cancel.type = "pair.create"
        XCTAssertThrowsError(try Wire.encode(cancel))
        cancel = PairCancel(requestId: requestID)
        cancel.v = 2
        XCTAssertThrowsError(try Wire.encode(cancel))
        cancel = PairCancel(requestId: requestID.uppercased())
        XCTAssertThrowsError(try Wire.encode(cancel))

        var approve = PairApprove(requestId: requestID, claimId: claimID)
        approve.type = "pair.deny"
        XCTAssertThrowsError(try Wire.encode(approve))
        approve = PairApprove(requestId: requestID, claimId: claimID)
        approve.v = 2
        XCTAssertThrowsError(try Wire.encode(approve))
        XCTAssertThrowsError(try Wire.encode(PairApprove(requestId: requestID.uppercased(), claimId: claimID)))
        XCTAssertThrowsError(try Wire.encode(PairApprove(requestId: requestID, claimId: claimID.uppercased())))

        var deny = PairDeny(requestId: requestID, claimId: claimID)
        deny.type = "pair.approve"
        XCTAssertThrowsError(try Wire.encode(deny))
        deny = PairDeny(requestId: requestID, claimId: claimID)
        deny.v = 2
        XCTAssertThrowsError(try Wire.encode(deny))
        XCTAssertThrowsError(try Wire.encode(PairDeny(requestId: requestID.uppercased(), claimId: claimID)))
        XCTAssertThrowsError(try Wire.encode(PairDeny(requestId: requestID, claimId: claimID.uppercased())))
    }

    func testMacPairingServerModelsFailClosedBeforeReEncodingMalformedMetadata() {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e1"
        let claimID = "018f63f5-6f3d-7d21-88bc-9ef561f030e2"

        var created = PairCreated(
            requestId: requestID,
            reference: String(repeating: "A", count: 43),
            expiresAtUnixMs: 1_786_500_000_000
        )
        created.type = "pair.status"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCreated(created)))
        created = PairCreated(
            requestId: requestID,
            reference: String(repeating: "A", count: 43),
            expiresAtUnixMs: 1_786_500_000_000
        )
        created.v = 2
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCreated(created)))
        created = PairCreated(
            requestId: requestID.uppercased(),
            reference: String(repeating: "A", count: 43),
            expiresAtUnixMs: 1_786_500_000_000
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCreated(created)))
        created = PairCreated(
            requestId: requestID,
            reference: String(repeating: "A", count: 43),
            expiresAtUnixMs: 1_786_500_000_000
        )
        created.reference = String(repeating: "A", count: 42) + "B"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCreated(created)))
        created = PairCreated(requestId: requestID, reference: String(repeating: "A", count: 43), expiresAtUnixMs: 0)
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCreated(created)))

        var legacy = PairStatus(
            requestId: requestID,
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 1
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))
        legacy = PairStatus(requestId: requestID, enrollmentState: .paired, activePhoneCredentialVersion: 0)
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))
        legacy = PairStatus(requestId: requestID, enrollmentState: .legacy, activePhoneCredentialVersion: 0)
        legacy.type = "pair.completed"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))
        legacy = PairStatus(requestId: requestID, enrollmentState: .legacy, activePhoneCredentialVersion: 0)
        legacy.v = 2
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))
        legacy = PairStatus(
            requestId: requestID.uppercased(),
            enrollmentState: .legacy,
            activePhoneCredentialVersion: 0
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))
        legacy = PairStatus(
            requestId: requestID,
            enrollmentState: .paired,
            activePhoneCredentialVersion: 9_007_199_254_740_992
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairStatus(legacy)))

        var claimed = PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_786_500_000_000,
            clientKind: .ios
        )
        claimed.type = "pair.claimed.phone"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))
        claimed = PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_786_500_000_000,
            clientKind: .ios
        )
        claimed.v = 2
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))
        claimed = PairClaimedMac(
            requestId: requestID.uppercased(),
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_786_500_000_000,
            clientKind: .ios
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))
        claimed = PairClaimedMac(
            requestId: requestID,
            claimId: claimID.uppercased(),
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_786_500_000_000,
            clientKind: .ios
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))
        claimed = PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 1_786_500_000_000,
            clientKind: .ios
        )
        claimed.confirmationCode = "482917"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))
        claimed = PairClaimedMac(
            requestId: requestID,
            claimId: claimID,
            confirmationCode: "482 917",
            expiresAtUnixMs: 0,
            clientKind: .ios
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairClaimedMac(claimed)))

        var completed = PairCompleted(
            requestId: requestID,
            claimId: claimID,
            activePhoneCredentialVersion: 0
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))
        completed = PairCompleted(requestId: requestID, claimId: claimID, activePhoneCredentialVersion: 1)
        completed.type = "pair.failed"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))
        completed = PairCompleted(requestId: requestID, claimId: claimID, activePhoneCredentialVersion: 1)
        completed.v = 2
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))
        completed = PairCompleted(
            requestId: requestID.uppercased(),
            claimId: claimID,
            activePhoneCredentialVersion: 1
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))
        completed = PairCompleted(
            requestId: requestID,
            claimId: claimID.uppercased(),
            activePhoneCredentialVersion: 1
        )
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))
        completed.activePhoneCredentialVersion = 9_007_199_254_740_992
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairCompleted(completed)))

        var failed = PairFailed(requestId: nil, claimId: nil, reason: .expired)
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairFailed(failed)))
        failed = PairFailed(requestId: requestID, claimId: nil, reason: .expired)
        failed.type = "pair.completed"
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairFailed(failed)))
        failed = PairFailed(requestId: requestID, claimId: nil, reason: .expired)
        failed.v = 2
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairFailed(failed)))
        failed = PairFailed(requestId: requestID.uppercased(), claimId: nil, reason: .expired)
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairFailed(failed)))
        failed = PairFailed(requestId: nil, claimId: claimID.uppercased(), reason: .expired)
        XCTAssertThrowsError(try Wire.encode(WireMessage.pairFailed(failed)))
    }

    func testPairingSafeIntegerOverflowFailsClosedInsteadOfTrapping() {
        let requestID = "018f63f5-6f3d-7d21-88bc-9ef561f030e0"
        let oversized = #"{"type":"pair.status","v":1,"requestId":"\#(requestID)","enrollmentState":"paired","activePhoneCredentialVersion":9223372036854775808}"#
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(oversized, for: .mac)) { error in
            XCTAssertEqual(error as? WireError, .invalidValue)
        }
    }

    func testCredentialRotationRejectsLegacyVersionZero() {
        let completed = #"{"type":"pair.completed","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030e1","claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","activePhoneCredentialVersion":0}"#
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(completed, for: .mac)) { error in
            XCTAssertEqual(error as? WireError, .invalidValue)
        }
    }

    func testEveryCanonicalInvalidFixtureIsRejectedWhenPresent() throws {
        let invalid = try fixtureURLs().filter(isInvalidFixture)
        XCTAssertFalse(invalid.isEmpty)
        for url in invalid {
            let descriptorData = try Data(contentsOf: url)
            let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptorData) as? [String: Any])
            let kind = try XCTUnwrap(descriptor["kind"] as? String)
            let role = (descriptor["role"] as? String).flatMap(WireRole.init(rawValue:))

            if kind == "binary" {
                let bytes = try XCTUnwrap(descriptor["bytes"] as? [UInt8])
                XCTAssertThrowsError(try StrictWireDecoder().rejectBinary(Data(bytes)), url.lastPathComponent)
                continue
            }

            let text: String
            switch kind {
            case "raw":
                text = try XCTUnwrap(descriptor["raw"] as? String)
            case "fixture":
                let fixture = try XCTUnwrap(descriptor["fixture"] as? String)
                let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: nil))
                text = String(decoding: try Data(contentsOf: fixtureURL), as: UTF8.self)
            case "oversized":
                let fixture = try XCTUnwrap(descriptor["baseFixture"] as? String)
                let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: nil))
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
                object[try XCTUnwrap(descriptor["field"] as? String)] = String(
                    repeating: try XCTUnwrap(descriptor["repeat"] as? String),
                    count: try XCTUnwrap(descriptor["count"] as? Int)
                )
                text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            default:
                let message = try XCTUnwrap(descriptor["message"] as? [String: Any])
                text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            }
            XCTAssertThrowsError(try StrictWireDecoder().decodeText(text, for: role), url.lastPathComponent)
        }
    }

    func testUnknownKeyIsRejectedBeforeCodableDecoding() {
        let text = #"{"type":"heartbeat.ack","v":1,"sequence":7,"extra":true}"#
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(text)) { error in
            XCTAssertEqual(error as? WireError, .unknownKeys(["extra"]))
        }
    }

    func testHelloRoleSpecificValidationRejectsUnknownRole() {
        let text = #"{"type":"hello","v":1,"role":"server","token":"abc"}"#
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(text))
    }

    func testOversizedTextIsRejectedByUTF8ByteCount() {
        let text = String(repeating: "é", count: 2_049)
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(text)) { error in
            XCTAssertEqual(error as? WireError, .tooLarge)
        }
    }

    func testExact4096ByteValidFramePassesAnd4097Fails() throws {
        let base = #"{"type":"heartbeat.ack","v":1,"sequence":7}"#
        let exact = base + String(repeating: " ", count: Constants.maxMessageBytes - base.utf8.count)
        XCTAssertEqual(exact.utf8.count, 4_096)
        XCTAssertNoThrow(try StrictWireDecoder().decodeText(exact, for: .phone))
        XCTAssertThrowsError(try StrictWireDecoder().decodeText(exact + " ", for: .phone)) { error in
            XCTAssertEqual(error as? WireError, .tooLarge)
        }
    }

    func testScalarAndConditionalParityWithBrowserParser() {
        let invalid = [
            #"{"type":"hello","v":1,"role":"mac","token":"ABC"}"#,
            #"{"type":"heartbeat.ack","v":1,"sequence":-1}"#,
            #"{"type":"heartbeat.ack","v":1,"sequence":1.5}"#,
            #"{"type":"time.sync.request","v":1,"syncId":"not-a-uuid","phoneSendUnixMs":1}"#,
            #"{"type":"time.sync.request","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":0}"#,
            #"{"type":"time.sync.response","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":1,"macReceiveUnixMs":3,"macSendUnixMs":2}"#,
            #"{"type":"diagnostics.counters","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030ab","mouseDownPostCount":-1,"mouseUpPostCount":0}"#,
            #"{"type":"action.request","v":1,"actionId":"bad","action":"click","issuedAtUnixMs":1,"expiresAtUnixMs":2001}"#,
            #"{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"move","issuedAtUnixMs":1,"expiresAtUnixMs":2001}"#,
            #"{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"forwarded","reason":"ok","relayProcessingUs":-1}"#,
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"rejected","reason":"expired","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":null}"#,
            #"{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"ok","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":0}"#,
        ]
        for text in invalid {
            XCTAssertThrowsError(try StrictWireDecoder().decodeText(text), text)
        }
    }

    func testBinaryFrameIsRejected() {
        XCTAssertThrowsError(try StrictWireDecoder().rejectBinary(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? WireError, .binaryFrame)
        }
    }

    func testActionFingerprintExcludesOnlyActionID() {
        let first = ActionRequest(actionId: "a", action: "click", issuedAtUnixMs: 10, expiresAtUnixMs: 2_010)
        let duplicate = ActionRequest(actionId: "b", action: "click", issuedAtUnixMs: 10, expiresAtUnixMs: 2_010)
        let conflict = ActionRequest(actionId: "a", action: "click", issuedAtUnixMs: 11, expiresAtUnixMs: 2_011)
        XCTAssertEqual(first.fingerprint, duplicate.fingerprint)
        XCTAssertNotEqual(first.fingerprint, conflict.fingerprint)
    }
}
