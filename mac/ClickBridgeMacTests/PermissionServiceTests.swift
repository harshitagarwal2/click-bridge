import XCTest
@testable import ClickBridgeMac

private final class AtomicInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class PermissionServiceTests: XCTestCase {
    func testCheckingDoesNotPromptAndUserActionRequestsOnce() {
        let checks = AtomicInteger()
        let requests = AtomicInteger()
        let service = PostEventPermissionService(
            preflight: { checks.increment(); return true },
            request: { requests.increment(); return false }
        )
        XCTAssertTrue(service.isGranted())
        XCTAssertEqual(checks.read(), 1)
        XCTAssertEqual(requests.read(), 0)
        XCTAssertFalse(service.requestFromUserAction())
        XCTAssertEqual(requests.read(), 1)
    }
}
