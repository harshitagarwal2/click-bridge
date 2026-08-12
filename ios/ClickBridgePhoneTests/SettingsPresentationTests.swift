import XCTest
@testable import ClickBridgePhone

final class SettingsPresentationTests: XCTestCase {
    private let validToken = String(repeating: "a", count: 64)

    func testDraftRequiresAValidURLAndNewTokenForFirstTimeSetup() {
        var draft = RelaySettingsDraft(initialRelayURL: "", hasStoredToken: false)

        XCTAssertFalse(draft.canSave)

        draft.relayURL = "https://relay.example/ws"
        draft.token = validToken
        XCTAssertFalse(draft.canSave)

        draft.relayURL = "wss://relay.example/ws"
        draft.token = "abc"
        XCTAssertFalse(draft.canSave)

        draft.token = validToken
        XCTAssertTrue(draft.canSave)
    }

    func testDraftAllowsAValidURLToReuseAnExistingStoredToken() {
        let draft = RelaySettingsDraft(initialRelayURL: "wss://new.example/ws",
                                       hasStoredToken: true)

        XCTAssertTrue(draft.canSave)
    }

    func testDraftPreservesSensitiveInputAfterFailureAndClearsErrorWhenEdited() {
        var draft = RelaySettingsDraft(initialRelayURL: "wss://relay.example/ws",
                                       hasStoredToken: false)
        draft.token = validToken
        draft.errorMessage = "Secure storage is unavailable."

        XCTAssertEqual(draft.token, validToken)
        XCTAssertEqual(draft.errorMessage, "Secure storage is unavailable.")

        draft.relayURL = "wss://new.example/ws"
        XCTAssertNil(draft.errorMessage)
        XCTAssertEqual(draft.token, validToken)
    }
}
