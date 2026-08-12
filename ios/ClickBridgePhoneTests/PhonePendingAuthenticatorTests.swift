import XCTest
@testable import ClickBridgePhone

@MainActor
final class PhonePendingAuthenticatorTests: XCTestCase {
    private let configuration = RelayConfiguration(
        url: URL(string: "wss://relay.example/ws")!,
        token: String(repeating: "a", count: 64)
    )

    func testAuthenticationSucceedsOnceAndDisconnectsTemporaryTransport() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        let generation = transport.generation
        transport.isAuthenticated = true
        transport.emit(.connection(generation: generation, state: .authenticated))

        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertEqual(transport.configurations, [configuration])
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_complete"])
    }

    func testAuthenticationRejectsFailureAndNeverResendsActions() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        transport.emit(.connection(generation: transport.generation, state: .backoff))

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(transport.sendAttempts.isEmpty)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_rejected"])
    }

    func testCancellationDisconnectsAndCompletesFalse() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        task.cancel()

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_cancelled"])
    }
}
