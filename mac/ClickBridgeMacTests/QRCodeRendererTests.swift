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

    func testWebInvitationMapsCanonicalNativeInvitationWithoutChangingReference() throws {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let native = URL(string: "https://relay.example:8443/pair#v=1&r=\(reference)")!

        let web = try PairingLink.makeWebInvitation(from: native)

        XCTAssertEqual(web.absoluteString,
                       "https://relay.example:8443/pair/web#v=1&r=\(reference)")
        XCTAssertEqual(web.fragment, native.fragment)
        XCTAssertEqual(native.absoluteString,
                       "https://relay.example:8443/pair#v=1&r=\(reference)")
    }

    func testSessionScopedInvitationPreservesItsSessionInNativeAndWebLinks() throws {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let session = "AbCdEfGhIjKlMnOpQrStUv"
        let native = try PairingLink.make(
            relayURL: URL(string: "wss://relay.example/ws/\(session)")!, reference: reference
        )

        XCTAssertEqual(native.absoluteString, "https://relay.example/pair/\(session)#v=1&r=\(reference)")
        XCTAssertEqual(try PairingLink.makeWebInvitation(from: native).absoluteString,
                       "https://relay.example/pair/web/\(session)#v=1&r=\(reference)")
    }

    func testWebInvitationRejectsHostileOrNonCanonicalSources() {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalidLinks = [
            "http://relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair/web#v=1&r=\(reference)",
            "https://relay.example/pair?token=secret#v=1&r=\(reference)",
            "https://user@relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair#v=1&r=\(reference)&token=secret",
            "https://relay.example/pair#v=1&r=A"
        ]

        for rawValue in invalidLinks {
            XCTAssertThrowsError(try PairingLink.makeWebInvitation(
                from: URL(string: rawValue)!
            ), rawValue)
        }
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
