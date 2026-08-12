import XCTest
@testable import ClickBridgeMac

final class QRCodeRendererTests: XCTestCase {
    func testPayloadContainsOnlyTheCanonicalPairingLink() throws {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let link = try PairingLink.make(
            relayURL: URL(string: "wss://relay.example/ws")!,
            reference: reference
        )

        XCTAssertEqual(try QRCodeRenderer.payload(for: link),
                       "https://relay.example/pair#v=1&r=\(reference)")
        XCTAssertFalse(try QRCodeRenderer.payload(for: link).contains("token"))
    }

    func testPairingLinkRejectsNonWebSocketRelayAndNonCanonicalReference() {
        XCTAssertThrowsError(try PairingLink.make(
            relayURL: URL(string: "https://relay.example/ws")!,
            reference: "A"
        ))
        XCTAssertThrowsError(try PairingLink.make(
            relayURL: URL(string: "wss://relay.example/ws")!,
            reference: String(repeating: "=", count: 43)
        ))
    }

    func testRendererRejectsAnythingExceptTheCanonicalInvitationURL() {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalidLinks = [
            "clickbridge://pair?token=secret",
            "https://relay.example/other#v=1&r=\(reference)",
            "https://relay.example/pair?token=secret#v=1&r=\(reference)",
            "https://user@relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair#v=1&r=\(reference)&token=secret",
            "https://relay.example/pair#v=1&r=A"
        ]

        for rawValue in invalidLinks {
            let link = URL(string: rawValue)!
            XCTAssertThrowsError(try QRCodeRenderer.payload(for: link))
            XCTAssertNil(QRCodeRenderer.image(for: link))
        }
    }
}
