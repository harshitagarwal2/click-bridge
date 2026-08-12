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
        XCTAssertEqual(result, .authenticated)
        XCTAssertEqual(transport.configurations, [configuration])
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_complete"])
    }

    func testOnlyAuthoritativeAuthenticationRejectionRejectsAndNeverResendsActions() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        transport.emit(.connection(generation: transport.generation, state: .authenticationRejected))

        let result = await task.value
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(transport.sendAttempts.isEmpty)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_rejected"])
    }

    func testInternalErrorBackoffIsUnavailableRatherThanCredentialRejection() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        transport.emit(.connection(generation: transport.generation, state: .backoff))

        let result = await task.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(transport.sendAttempts.isEmpty)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_unavailable"])
    }

    func testCancellationDisconnectsAndCompletesFalse() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_cancelled"])
    }

    func testCancellationWinsOverImmediateAuthenticationRejection() async {
        let transport = FakePhoneActionTransport()
        let subject = PhonePendingAuthenticator(transport: transport)

        let task = Task { await subject.authenticate(configuration) }
        await Task.yield()
        task.cancel()
        transport.emit(.connection(generation: transport.generation, state: .authenticationRejected))

        let result = await task.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(transport.disconnectReasons, ["pending_authentication_cancelled"])
    }
}
