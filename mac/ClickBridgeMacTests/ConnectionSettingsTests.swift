import XCTest
@testable import ClickBridgeMac

final class ConnectionSettingsTests: XCTestCase {
    private let validToken = String(repeating: "a1", count: 32)

    func testValidatorTrimsAndAcceptsPublicRelayEndpoint() throws {
        let validated = try ConnectionSettingsValidator.validate(
            relayURLString: "  \n wss://relay.example.com/ws \t",
            replacementMacToken: ""
        )

        XCTAssertEqual(validated.relayURL, URL(string: "wss://relay.example.com/ws"))
        XCTAssertEqual(validated.relayURLString, "wss://relay.example.com/ws")
        XCTAssertEqual(validated.tokenInput, .reuseStored)
    }

    func testValidatorRejectsUnsafeOrMalformedRelayEndpoints() {
        let invalidValues = [
            "http://relay.example.com/ws",
            "wss:///ws",
            "wss://relay.example.com/other",
            "wss://user@relay.example.com/ws",
            "wss://relay.example.com/ws?token=value",
            "wss://relay.example.com/ws#fragment"
        ]

        for value in invalidValues {
            XCTAssertThrowsError(
                try ConnectionSettingsValidator.validate(
                    relayURLString: value,
                    replacementMacToken: ""
                ),
                "Expected rejection for \(value)"
            ) { error in
                XCTAssertEqual(error as? ConnectionSettingsValidationError, .invalidRelayURL)
                XCTAssertEqual(error.localizedDescription, "Enter a secure relay URL ending in /ws.")
            }
        }
    }

    func testBlankReplacementTokenReusesStoredCredential() throws {
        for blank in ["", "  ", "\n\t"] {
            let validated = try ConnectionSettingsValidator.validate(
                relayURLString: "wss://relay.example.com/ws",
                replacementMacToken: blank
            )
            XCTAssertEqual(validated.tokenInput, .reuseStored)
        }
    }

    func testReplacementTokenIsTrimmedLowercasedAndAcceptedAtExactly64HexCharacters() throws {
        let validated = try ConnectionSettingsValidator.validate(
            relayURLString: "wss://relay.example.com/ws",
            replacementMacToken: "  \(validToken.uppercased())\n"
        )

        XCTAssertEqual(validated.tokenInput, .replacement(validToken))
    }

    func testReplacementTokenRejectsWrongLengthAndNonhexWithoutEchoingInput() {
        let invalidValues = [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "z", count: 64)
        ]

        for value in invalidValues {
            XCTAssertThrowsError(
                try ConnectionSettingsValidator.validate(
                    relayURLString: "wss://relay.example.com/ws",
                    replacementMacToken: value
                )
            ) { error in
                XCTAssertEqual(error as? ConnectionSettingsValidationError, .invalidReplacementToken)
                XCTAssertEqual(error.localizedDescription, "Enter a 64-character hexadecimal Mac token.")
                XCTAssertFalse(error.localizedDescription.contains(value))
            }
        }
    }

    func testDraftTracksURLAndTokenChangesAndDiscardsBoth() {
        var draft = ConnectionSettingsDraft(
            appliedRelayURLString: "wss://old.example.com/ws",
            relayURLString: "wss://old.example.com/ws",
            replacementMacToken: ""
        )
        XCTAssertFalse(draft.hasChanges)

        draft.relayURLString = "wss://new.example.com/ws"
        XCTAssertTrue(draft.hasChanges)

        draft.relayURLString = draft.appliedRelayURLString
        draft.replacementMacToken = validToken
        XCTAssertTrue(draft.hasChanges)

        draft.discardChanges()
        XCTAssertEqual(draft.relayURLString, "wss://old.example.com/ws")
        XCTAssertEqual(draft.replacementMacToken, "")
        XCTAssertFalse(draft.hasChanges)
    }

    func testRejectedValidationLeavesDraftUntouchedForCorrection() {
        let draft = ConnectionSettingsDraft(
            appliedRelayURLString: "wss://old.example.com/ws",
            relayURLString: "https://unsafe.example.com/ws",
            replacementMacToken: "not-a-token"
        )
        let original = draft

        XCTAssertThrowsError(
            try ConnectionSettingsValidator.validate(
                relayURLString: draft.relayURLString,
                replacementMacToken: draft.replacementMacToken
            )
        )
        XCTAssertEqual(draft, original)
    }
}
