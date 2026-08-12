import XCTest
@testable import ClickBridgePhone

final class PhoneStateTests: XCTestCase {
    func testExactStatusTitlesAndBoundaryDetails() {
        XCTAssertEqual(PhonePrimaryStatus.ready.title, "Ready")
        XCTAssertEqual(PhonePrimaryStatus.notConnected.title, "Not connected")
        XCTAssertEqual(PhonePrimaryStatus.macOffline.title, "Mac offline")
        XCTAssertEqual(PhonePrimaryStatus.clockUnavailable.title, "Clock check unavailable")
        XCTAssertEqual(PhonePrimaryStatus.clockUnavailable.detail,
                       "Unable to validate the phone and Mac clocks. Retry the clock check.")
        XCTAssertEqual(PhonePrimaryStatus.clockMismatch.title, "Clock mismatch")
        XCTAssertEqual(PhonePrimaryStatus.anotherPhoneTookOver.title, "Another phone took over")
        XCTAssertEqual(PhonePrimaryStatus.anotherPhoneTookOver.detail,
                       "Reconnect this phone when you are ready to take control again.")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).title, "At volume boundary")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.minimum).detail,
                       "Volume Down cannot create another change, so it cannot be detected. Volume Up can still trigger.")
        XCTAssertEqual(PhonePrimaryStatus.atVolumeBoundary(.maximum).detail,
                       "Volume Up cannot create another change, so it cannot be detected. Volume Down can still trigger.")
    }

    func testStatusPrecedence() {
        var state = PhoneState()
        XCTAssertEqual(state.primaryStatus, .notConnected)
        state.connection = .takenOver
        XCTAssertTrue(state.phoneTakenOver)
        XCTAssertEqual(state.primaryStatus, .anotherPhoneTookOver)
        state.connection = .disconnected
        XCTAssertFalse(state.phoneTakenOver)
        state.foregroundSessionActive = true
        state.connection = .authenticated
        state.mac = .init(online: false, remoteEnabled: false, permission: .unknown)
        XCTAssertEqual(state.primaryStatus, .macOffline)
        state.mac = .init(online: true, remoteEnabled: false, permission: .ready)
        XCTAssertEqual(state.primaryStatus, .macNotReady)
        state.mac.remoteEnabled = true
        state.clock = .init(status: .checking, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
        XCTAssertEqual(state.primaryStatus, .checkingClock)
        state.clock = .init(status: .unavailable, offsetMilliseconds: nil, uncertaintyMilliseconds: nil)
        XCTAssertEqual(state.primaryStatus, .clockUnavailable)
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

    func testClockRetryVisibilityOnlyForUnavailableHealth() {
        var state = PhoneState()
        for status in [ClockHealth.Status.unchecked, .checking, .healthy, .mismatch] {
            state.clock = .init(status: status,
                                offsetMilliseconds: nil,
                                uncertaintyMilliseconds: nil)
            XCTAssertFalse(state.showsClockRetry)
        }

        state.clock = .init(status: .unavailable,
                            offsetMilliseconds: nil,
                            uncertaintyMilliseconds: nil)
        XCTAssertTrue(state.showsClockRetry)
    }

    func testConnectionProgressProvidesSpecificRecoveryDetail() {
        var state = PhoneState()
        state.foregroundSessionActive = true

        state.connection = .connecting
        XCTAssertEqual(state.primaryStatusDetail, "Connecting to the relay.")

        state.connection = .authenticating
        XCTAssertEqual(state.primaryStatusDetail, "Authenticating with the relay.")

        state.connection = .backoff
        XCTAssertEqual(state.primaryStatusDetail, "Connection lost. Retrying automatically.")
    }

    func testOnlySettingsRelatedIssuesAreForwardedIntoSettings() {
        XCTAssertEqual(PhoneAppIssue.invalidSettings.settingsMessage,
                       PhoneAppIssue.invalidSettings.message)
        XCTAssertEqual(PhoneAppIssue.secureStorageUnavailable.settingsMessage,
                       PhoneAppIssue.secureStorageUnavailable.message)
        XCTAssertNil(PhoneAppIssue.volumeMonitoringUnavailable.settingsMessage)
    }

    func testDashboardAccessibilityFocusPrefersIssueWhenIssueAndOutcomeAreNew() {
        let previous = DashboardAccessibilityAnnouncement(issue: nil, outcome: nil)

        XCTAssertEqual(DashboardAccessibilityAnnouncement(issue: .invalidSettings,
                                                           outcome: "Posted in 12 ms").focusChange(from: previous),
                       .issue)
        XCTAssertEqual(DashboardAccessibilityAnnouncement(issue: nil,
                                                           outcome: "Posted in 12 ms").focusChange(from: previous),
                       .outcome)
        XCTAssertNil(DashboardAccessibilityAnnouncement(issue: nil,
                                                         outcome: nil).focusChange(from: previous))
    }

    func testDashboardAccessibilityFocusIgnoresUnchangedOutcomeWhenIssueClears() {
        let previous = DashboardAccessibilityAnnouncement(issue: .invalidSettings,
                                                           outcome: "Posted in 12 ms")
        let current = DashboardAccessibilityAnnouncement(issue: nil,
                                                          outcome: "Posted in 12 ms")

        XCTAssertNil(current.focusChange(from: previous))
    }

    func testDashboardAccessibilityFocusPrefersChangedIssueWhenOutcomeAlsoChanges() {
        let previous = DashboardAccessibilityAnnouncement(issue: nil,
                                                           outcome: "Posted in 12 ms")
        let current = DashboardAccessibilityAnnouncement(issue: .volumeMonitoringUnavailable,
                                                          outcome: "Mac Accessibility permission is required.")

        XCTAssertEqual(current.focusChange(from: previous), .issue)
    }
}
