import XCTest
@testable import ClickBridgeMac

/// Decodes every canonical fixture from contracts/fixtures so Swift and Node
/// are provably reading the same contract.
final class WireMessageTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        // Fixtures are copied into the test bundle as resources.
        guard let url = Bundle(for: Self.self)
            .url(forResource: name, withExtension: "json") else {
            throw XCTSkip("fixture \(name).json missing from the test bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testDecodesEveryFixture() throws {
        let names = [
            "hello.phone", "hello.mac", "hello.ok",
            "heartbeat.request", "heartbeat.ack",
            "mac.state", "state",
            "action.request", "relay.ack",
            "action.result.posted", "action.result.rejected",
            "time.sync.request", "time.sync.response",
        ]
        for name in names {
            let raw = try fixture(name)
            XCTAssertNoThrow(try Wire.decode(raw), "failed to decode \(name)")
        }
    }

    func testActionRequestRoundTrips() throws {
        let raw = try fixture("action.request")
        guard case .actionRequest(let request) = try Wire.decode(raw) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(request.action, "click")
        XCTAssertEqual(request.expiresAtUnixMs - request.issuedAtUnixMs,
                       Constants.actionLifetimeMs)

        let encoded = try Wire.encode(request)
        guard case .actionRequest(let again) = try Wire.decode(encoded) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(request, again)
    }

    func testPostedAndRejectedResults() throws {
        guard case .actionResult(let posted) = try Wire.decode(fixture("action.result.posted")) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(posted.status, .posted)
        XCTAssertEqual(posted.reason, .ok)
        XCTAssertNotNil(posted.mouseDownPostedUnixMs)

        guard case .actionResult(let rejected) = try Wire.decode(fixture("action.result.rejected")) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertNil(rejected.mouseDownPostedUnixMs)
    }

    func testUnknownTypeIsRejected() {
        XCTAssertThrowsError(try Wire.decode(#"{"type":"nope","v":1}"#)) { error in
            XCTAssertEqual(error as? WireError, .unknownType("nope"))
        }
    }

    func testWrongVersionIsRejected() {
        XCTAssertThrowsError(try Wire.decode(#"{"type":"state","v":2}"#)) { error in
            XCTAssertEqual(error as? WireError, .unsupportedVersion)
        }
    }

    func testOversizedFrameIsRejected() {
        let big = #"{"type":"state","v":1,"pad":""# + String(repeating: "x", count: 5000) + #""}"#
        XCTAssertThrowsError(try Wire.decode(big)) { error in
            XCTAssertEqual(error as? WireError, .tooLarge)
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try Wire.decode("{nope"))
    }

    func testFingerprintExcludesActionId() {
        let a = ActionRequest(actionId: "a", action: "click",
                              issuedAtUnixMs: 1000, expiresAtUnixMs: 3000)
        let b = ActionRequest(actionId: "b", action: "click",
                              issuedAtUnixMs: 1000, expiresAtUnixMs: 3000)
        XCTAssertEqual(a.fingerprint, b.fingerprint)

        let c = ActionRequest(actionId: "a", action: "click",
                              issuedAtUnixMs: 1001, expiresAtUnixMs: 3001)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }
}
