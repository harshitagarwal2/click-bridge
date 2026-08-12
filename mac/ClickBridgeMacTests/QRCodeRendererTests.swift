import XCTest
@testable import ClickBridgeMac

final class QRCodeRendererTests: XCTestCase {
    func testPayloadContainsOnlyTheCanonicalPairingLink() throws {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let link = try PairingLink.make(
            relayURL: URL(string: "wss://relay.example/ws")!,
            reference: reference
        )

        XCTAssertEqual(QRCodeRenderer.payload(for: link),
                       "https://relay.example/pair#v=1&r=\(reference)")
        XCTAssertFalse(QRCodeRenderer.payload(for: link).contains("token"))
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
}
