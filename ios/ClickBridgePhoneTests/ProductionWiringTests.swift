import XCTest
@testable import ClickBridgePhone

final class ProductionWiringTests: XCTestCase {
    func testAssociatedDomainMatchesCompiledPairingHost() throws {
        let entitlements = try source("ClickBridgePhone/ClickBridgePhone.entitlements")

        XCTAssertTrue(entitlements.contains("<string>\(PhoneDeployment.associatedDomain)</string>"))
    }

    func testCompositionInstallsRealPairingClientAndPendingAuthenticator() throws {
        let app = try source("ClickBridgePhone/ClickBridgePhoneApp.swift")

        XCTAssertTrue(app.contains("PhonePendingAuthenticator(transport: pendingTransport)"))
        XCTAssertTrue(app.contains("authenticatePending: pendingAuthenticator.authenticate"))
        XCTAssertTrue(app.contains("model.installPairingClient(pairing)"))
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

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosDirectory = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: iosDirectory.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
