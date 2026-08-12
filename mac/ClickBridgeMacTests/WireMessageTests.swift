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
        return name.hasPrefix("invalid-") || name == "malformed.json" || name == "oversized.json"
            || name == "unknown-field.json" || name == "wrong-role.json" || name == "wrong-version.json"
            || name == "binary-descriptor.json"
    }

    func testEveryCanonicalFixtureStrictlyDecodesAndSemanticallyRoundTrips() throws {
        let urls = try fixtureURLs()
        XCTAssertFalse(urls.isEmpty)
        for url in urls where !isInvalidFixture(url) {
            let data = try Data(contentsOf: url)
            let decoded = try StrictWireDecoder().decodeText(String(decoding: data, as: UTF8.self))
            let encoded = try Wire.encode(decoded)
            XCTAssertEqual(try StrictWireDecoder().decodeText(encoded), decoded, url.lastPathComponent)
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
