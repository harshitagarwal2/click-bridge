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
