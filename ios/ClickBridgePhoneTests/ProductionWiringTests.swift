import XCTest
@testable import ClickBridgePhone

final class ProductionWiringTests: XCTestCase {
    func testAssociatedDomainMatchesCompiledPairingHost() throws {
        let entitlements = try source("ClickBridgePhone/ClickBridgePhone.entitlements")

        XCTAssertTrue(entitlements.contains("<string>\(PhoneDeployment.associatedDomain)</string>"))
    }

    /// The pairing host and bundle id must also agree with the relay, which
    /// serves them in its apple-app-site-association response — Apple requires
    /// all three to match or Universal Link pairing silently stops working.
    /// This checks the compiled iOS app against the shared contract; the relay
    /// endpoint is checked behaviorally in relay.pairing.socket.test.js.
    func testDeploymentIdentityMatchesSharedContract() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "deployment", withExtension: "json"))
        let contract = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])

        let host = try XCTUnwrap(contract["pairingHost"] as? String)
        let prefix = try XCTUnwrap(contract["associatedDomainPrefix"] as? String)
        let bundleId = try XCTUnwrap(contract["bundleId"] as? String)

        XCTAssertEqual(PhoneDeployment.pairingHost, host)
        XCTAssertEqual(PhoneDeployment.associatedDomain, prefix + host)

        let entitlements = try source("ClickBridgePhone/ClickBridgePhone.entitlements")
        XCTAssertTrue(entitlements.contains("<string>\(prefix)\(host)</string>"))

        XCTAssertEqual(Bundle.main.bundleIdentifier, bundleId)
    }

    func testCompositionInstallsRealPairingClientAndPendingAuthenticator() throws {
        let app = try source("ClickBridgePhone/ClickBridgePhoneApp.swift")

        XCTAssertTrue(app.contains("PhonePendingAuthenticator(transport: pendingTransport)"))
        XCTAssertTrue(app.contains("authenticatePending: pendingAuthenticator.authenticate"))
        XCTAssertTrue(app.contains("model.installPairingClient(pairing)"))
    }

    func testAppIntentMetadataAvoidsAppleRestrictedMacTerm() {
        let title = String(localized: TriggerClickIntent.title)
        let description = String(localized: TriggerClickIntent.description.descriptionText)

        XCTAssertEqual(
            description,
            "Open Click Bridge and send three ordinary clicks to the connected computer."
        )
        for value in [title, description] {
            XCTAssertFalse(value.localizedCaseInsensitiveContains("mac"))
        }
    }

    func testUniversalLinkAndSceneLifecycleAreWiredInProductionOrder() throws {
        let app = try source("ClickBridgePhone/ClickBridgePhoneApp.swift")
        let openURL = try XCTUnwrap(app.range(of: ".onOpenURL(perform: model.handlePairingInvitation)"))
        let scenePhase = try XCTUnwrap(app.range(of: ".onChange(of: scenePhase"))

        XCTAssertLessThan(openURL.lowerBound, scenePhase.lowerBound)
    }

    func testClaimantSheetOwnsScannerCallbackAndPasteFallback() throws {
        let content = try source("ClickBridgePhone/ContentView.swift")

        XCTAssertTrue(content.contains("PairingScannerView(receive: model.submitPairingInvitation)"))
        XCTAssertTrue(content.contains("PasteButton(payloadType: String.self)"))
        XCTAssertTrue(content.contains("switch model.presentedFlow"))
    }

    func testScannerRepresentableStopsCaptureWhenRemoved() throws {
        let scanner = try source("ClickBridgePhone/PairingScannerView.swift")

        XCTAssertTrue(scanner.contains("static func dismantleUIViewController"))
        XCTAssertTrue(scanner.contains("controller.stopCapture()"))
        XCTAssertTrue(scanner.contains("AVCaptureSessionRuntimeError"))
        XCTAssertTrue(scanner.contains("AVCaptureSessionWasInterrupted"))
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosDirectory = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: iosDirectory.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
