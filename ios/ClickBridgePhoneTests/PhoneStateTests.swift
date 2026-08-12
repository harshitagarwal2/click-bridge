import XCTest
@testable import ClickBridgePhone

final class PhoneStateTests: XCTestCase {
    func testExactStatusTitlesAndBoundaryDetails() {
        XCTAssertEqual(PhonePrimaryStatus.ready.title, "Ready")
        XCTAssertEqual(PhonePrimaryStatus.notConnected.title, "Not connected")
        XCTAssertEqual(PhonePrimaryStatus.macOffline.title, "Mac offline")
        XCTAssertEqual(PhonePrimaryStatus.clockMismatch.title, "Clock mismatch")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).title, "At volume boundary")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).detail,
                       "Volume Down cannot create another change, so it cannot be detected. Volume Up can still trigger.")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.maximum).detail,
                       "Volume Up cannot create another change, so it cannot be detected. Volume Down can still trigger.")
    }

    func testStatusPrecedence() {
        var state = PhoneState()
        XCTAssertEqual(state.primaryStatus, .notConnected)
        state.foregroundSessionActive = true
        state.connection = .authenticated
        state.mac = .init(online: false, remoteEnabled: false, permission: .unknown)
        XCTAssertEqual(state.primaryStatus, .macOffline)
        state.mac = .init(online: true, remoteEnabled: false, permission: .ready)
        XCTAssertEqual(state.primaryStatus, .macNotReady)
        state.mac.remoteEnabled = true
        state.clock = .init(status: .checking, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
        XCTAssertEqual(state.primaryStatus, .checkingClock)
        state.clock = .init(status: .mismatch, offsetMilliseconds: 2_000, uncertaintyMilliseconds: 5)
        XCTAssertEqual(state.primaryStatus, .clockMismatch)
        state.clock = .init(status: .healthy, offsetMilliseconds: 0, uncertaintyMilliseconds: 2)
        state.actionPhase = .sending(actionID: UUID())
        XCTAssertEqual(state.primaryStatus, .sending)
        state.actionPhase = .idle
        state.volume = .init(value: 1)
        XCTAssertEqual(state.primaryStatus, .atVolumeBoundary(.maximum))
        state.actionPhase = .forwarded(actionID: UUID())
        XCTAssertEqual(state.primaryStatus, .sending)
        state.actionPhase = .idle
        state.volume = .init(value: 0.5)
        XCTAssertEqual(state.primaryStatus, .ready)
    }
}
