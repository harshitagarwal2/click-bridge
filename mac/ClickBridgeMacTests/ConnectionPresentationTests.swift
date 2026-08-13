import XCTest
@testable import ClickBridgeMac

@MainActor
final class ConnectionPresentationTests: XCTestCase {
    func testReadinessRowsExposeTextSymbolsAndStableIdentifiers() {
        XCTAssertEqual(
            SettingsReadinessPresentation.relay(.connected),
            .init(title: "Relay", value: "Connected", symbol: "checkmark.circle.fill", identifier: SettingsAccessibility.relayStatus)
        )
        XCTAssertEqual(SettingsReadinessPresentation.relay(.connecting).value, "Connecting")
        XCTAssertEqual(SettingsReadinessPresentation.relay(.disconnected).value, "Not Connected")
        XCTAssertEqual(SettingsReadinessPresentation.permission(.ready).value, "Ready")
        XCTAssertEqual(SettingsReadinessPresentation.permission(.required).value, "Required")
        XCTAssertEqual(SettingsReadinessPresentation.remote(enabled: true).value, "Enabled")
        XCTAssertEqual(SettingsReadinessPresentation.remote(enabled: false).value, "Disabled")
    }

    func testDraftClearsOnlyAfterAcceptedApply() {
        var accepted = ConnectionSettingsDraft(
            appliedRelayURLString: "wss://old.example/ws",
            relayURLString: "wss://new.example/ws",
            replacementMacToken: String(repeating: "a", count: 64)
        )
        accepted.reduce(
            outcome: .accepted,
            acceptedRelayURLString: "wss://new.example/ws"
        )
        XCTAssertEqual(accepted.appliedRelayURLString, "wss://new.example/ws")
        XCTAssertEqual(accepted.relayURLString, "wss://new.example/ws")
        XCTAssertEqual(accepted.replacementMacToken, "")
        XCTAssertFalse(accepted.hasChanges)

        for issue in [
            ConnectionActionIssue.pairingInProgress,
            .invalidRelayURL,
            .invalidReplacementToken,
            .missingToken,
            .keychainUnavailable,
        ] {
            var rejected = ConnectionSettingsDraft(
                appliedRelayURLString: "wss://old.example/ws",
                relayURLString: "wss://new.example/ws",
                replacementMacToken: "keep-me"
            )
            rejected.reduce(
                outcome: .rejected(issue),
                acceptedRelayURLString: "wss://ignored.example/ws"
            )
            XCTAssertEqual(rejected.appliedRelayURLString, "wss://old.example/ws")
            XCTAssertEqual(rejected.relayURLString, "wss://new.example/ws")
            XCTAssertEqual(rejected.replacementMacToken, "keep-me")
            XCTAssertTrue(rejected.hasChanges)
        }
    }

    func testStableSettingsIdentifiersAreUnique() {
        let identifiers = SettingsAccessibility.all
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.contains(SettingsAccessibility.relayURLField))
        XCTAssertTrue(identifiers.contains(SettingsAccessibility.saveAndReconnect))
        XCTAssertTrue(identifiers.contains(SettingsAccessibility.removeCredential))
        XCTAssertTrue(identifiers.contains(SettingsAccessibility.inlineFeedback))
    }
}
