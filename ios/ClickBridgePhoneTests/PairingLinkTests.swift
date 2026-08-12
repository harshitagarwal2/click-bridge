import XCTest
@testable import ClickBridgePhone

final class PairingLinkTests: XCTestCase {
    private let reference = String(repeating: "A", count: 43)

    func testParsesCanonicalRemotePairingLinkForConfiguredHost() throws {
        let url = try XCTUnwrap(URL(string: "https://relay.example/pair#v=1&r=\(reference)"))

        let link = try PhonePairingLink.parse(url, expectedHost: "relay.example")

        XCTAssertEqual(link.reference, reference)
        XCTAssertEqual(link.claimantWebSocketURL.absoluteString, "wss://relay.example/ws")
    }

    func testParsesCanonicalWebInvitationForNativeClaimant() throws {
        let url = try XCTUnwrap(URL(string: "https://relay.example/pair/web#v=1&r=\(reference)"))

        let link = try PhonePairingLink.parse(url, expectedHost: "relay.example")

        XCTAssertEqual(link.reference, reference)
        XCTAssertEqual(link.claimantWebSocketURL.absoluteString, "wss://relay.example/ws")
    }

    func testRejectsNoncanonicalOrSecretBearingPairingLinks() throws {
        let candidates = [
            "http://relay.example/pair#v=1&r=\(reference)",
            "https://other.example/pair#v=1&r=\(reference)",
            "https://user@relay.example/pair#v=1&r=\(reference)",
            "https://relay.example:443/pair#v=1&r=\(reference)",
            "https://relay.example/pair?token=secret#v=1&r=\(reference)",
            "https://relay.example/pair/extra#v=1&r=\(reference)",
            "https://relay.example/pair#r=\(reference)&v=1",
            "https://relay.example/pair#v=1&r=\(reference)&token=secret",
            "https://relay.example/pair#v=2&r=\(reference)",
            "https://relay.example/pair#v=1&r=\(reference)=",
            "https://relay.example/%70air#v=1&r=\(reference)",
            "https://relay.example/pair/%77eb#v=1&r=\(reference)",
            "https://relay.example/pair#v%3D1%26r%3D\(reference)",
            "https://relay.example/pair#v=1&r=%41\(reference.dropFirst())",
        ]

        for candidate in candidates {
            XCTAssertThrowsError(
                try PhonePairingLink.parse(XCTUnwrap(URL(string: candidate)), expectedHost: "relay.example"),
                candidate
            )
        }
    }

    func testRejectsLinksOverMaximumUTF8Size() throws {
        let oversized = "https://relay.example/pair#v=1&r=\(reference)" + String(repeating: "x", count: 512)
        XCTAssertThrowsError(
            try PhonePairingLink.parse(XCTUnwrap(URL(string: oversized)), expectedHost: "relay.example")
        )
    }
}
