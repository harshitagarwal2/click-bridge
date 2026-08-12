import XCTest
@testable import ClickBridgeMac

private final class LockedPoster: InputPosting, @unchecked Sendable {
    private let lock = NSLock()
    var outcome: InputPostOutcome = .posted(mouseDownUnixMs: 1_000)
    private var calls = 0
    private var counts = InputPostCounts.zero

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if case .posted = outcome {
            counts = InputPostCounts(mouseDownPostCount: counts.mouseDownPostCount + 1,
                                     mouseUpPostCount: counts.mouseUpPostCount + 1)
        }
        return outcome
    }
    func diagnosticPostCounts() -> InputPostCounts { lock.withLock { counts } }
    func callCount() -> Int { lock.withLock { calls } }
}

private final class LockedPermission: PostEventPermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    init(_ granted: Bool = true) { self.granted = granted }
    func isGranted() -> Bool { lock.withLock { granted } }
    func set(_ value: Bool) { lock.withLock { granted = value } }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Double
    init(_ milliseconds: Double) { self.milliseconds = milliseconds }
    func now() -> Double { lock.withLock { milliseconds } }
    func advance(_ value: Double) { lock.withLock { milliseconds += value } }
}

final class ActionProcessorTests: XCTestCase {
    private let base = 1_786_497_600_000.0

    private func request(id: String = UUID().uuidString, issued: Double? = nil, action: String = "click") -> ActionRequest {
        let issued = issued ?? base
        return ActionRequest(actionId: id, action: action, issuedAtUnixMs: issued,
                             expiresAtUnixMs: issued + Constants.actionLifetimeMs)
    }

    private func processor(
        poster: LockedPoster = LockedPoster(),
        permission: LockedPermission = LockedPermission(),
        clock: LockedClock? = nil,
        ttl: TimeInterval = Constants.completedActionTTL,
        capacity: Int = Constants.completedActionCap
    ) -> ActionProcessor {
        let clock = clock ?? LockedClock(base)
        return ActionProcessor(poster: poster, permission: permission,
                               nowMilliseconds: { clock.now() }, ttl: ttl, capacity: capacity)
    }

    func testRuntimeGateStartsDisabledThenAllowsOneValidPost() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        let disabled = await subject.receive(request(id: "disabled"), via: .oci)
        XCTAssertEqual(disabled.reason, .remoteDisabled)
        XCTAssertEqual(poster.callCount(), 0)

        await subject.setRemoteEnabled(true)
        let posted = await subject.receive(request(id: "posted"), via: .oci)
        XCTAssertEqual(posted.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testPermissionAndEventCreationFailuresPostNoEvents() async {
        let missing = LockedPoster()
        let noPermission = processor(poster: missing, permission: LockedPermission(false))
        await noPermission.setRemoteEnabled(true)
        let permissionResult = await noPermission.receive(request(id: "permission"), via: .oci)
        XCTAssertEqual(permissionResult.reason, .permissionRequired)
        XCTAssertEqual(missing.callCount(), 0)

        let creation = LockedPoster(); creation.outcome = .creationFailed
        let failed = processor(poster: creation)
        await failed.setRemoteEnabled(true)
        let creationResult = await failed.receive(request(id: "creation"), via: .oci)
        XCTAssertEqual(creationResult.reason, .eventCreationFailed)
        XCTAssertEqual(creation.diagnosticPostCounts(), .zero)
    }

    func testCountersReflectActualPosts() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        let initial = await subject.diagnosticPostCounts()
        XCTAssertEqual(initial, .zero)
        await subject.setRemoteEnabled(true)
        _ = await subject.receive(request(id: "one"), via: .oci)
        let after = await subject.diagnosticPostCounts()
        XCTAssertEqual(after, InputPostCounts(mouseDownPostCount: 1, mouseUpPostCount: 1))
    }

    func testCompletedDuplicateReturnsExactCachedResultAndConflictIsRejected() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let original = await subject.receive(request(id: "same"), via: .oci)
        let duplicate = await subject.receive(request(id: "same"), via: .tailscale)
        XCTAssertEqual(duplicate, original)
        XCTAssertEqual(poster.callCount(), 1)

        let conflict = await subject.receive(request(id: "same", issued: base + 1), via: .tailscale)
        XCTAssertEqual(conflict.reason, .idConflict)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testExpiredInvalidAndCapacityRequestsFailClosed() async {
        let poster = LockedPoster()
        let clock = LockedClock(base + 10_000)
        let subject = processor(poster: poster, clock: clock, capacity: 1)
        await subject.setRemoteEnabled(true)
        let expired = await subject.receive(request(id: "old", issued: base), via: .oci)
        let invalid = await subject.receive(request(id: "invalid", issued: base + 10_000, action: "move"), via: .oci)
        XCTAssertEqual(expired.reason, .expired)
        XCTAssertEqual(invalid.reason, .invalidRequest)
        _ = await subject.receive(request(id: "first", issued: base + 10_000), via: .oci)
        let capacity = await subject.receive(request(id: "second", issued: base + 10_000), via: .oci)
        XCTAssertEqual(capacity.reason, .capacityExceeded)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testOneThousandConcurrentDuplicatesAcrossIngressesPostOnce() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let action = request(id: "hedged")
        await withTaskGroup(of: ActionResult.self) { group in
            for index in 0..<1_000 {
                group.addTask { await subject.receive(action, via: index.isMultiple(of: 2) ? .oci : .tailscale) }
            }
            var results: [ActionResult] = []
            for await result in group { results.append(result) }
            XCTAssertEqual(Set(results.map(\.actionId)), ["hedged"])
            XCTAssertEqual(Set(results.map(\.mouseDownPostedUnixMs)), [1_000])
        }
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testDistinctIDsPostOnceEachAndTTLPrunesCompletedEntries() async {
        let poster = LockedPoster()
        let clock = LockedClock(base)
        let subject = processor(poster: poster, clock: clock, ttl: 1, capacity: 2)
        await subject.setRemoteEnabled(true)
        _ = await subject.receive(request(id: "a"), via: .oci)
        _ = await subject.receive(request(id: "b"), via: .oci)
        XCTAssertEqual(poster.callCount(), 2)
        clock.advance(2_000)
        _ = await subject.receive(request(id: "c", issued: base + 2_000), via: .oci)
        XCTAssertEqual(poster.callCount(), 3)
        let tracked = await subject.trackedActionCount()
        XCTAssertEqual(tracked, 1)
    }

    func testCancellingOneCallerDoesNotPermitSecondExecution() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let action = request(id: "cancel")
        let first = Task { await subject.receive(action, via: .oci) }
        first.cancel()
        _ = await first.value
        _ = await subject.receive(action, via: .tailscale)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testToggleRaceIsSerializedAndResultMatchesActualPostBoundary() async {
        for index in 0..<200 {
            let poster = LockedPoster()
            let subject = processor(poster: poster)
            async let gate: Void = subject.setRemoteEnabled(true)
            async let result = subject.receive(request(id: String(format: "018f63f5-6f3d-7d21-88bc-%012x", index)), via: .oci)
            _ = await gate
            let terminal = await result
            if terminal.status == .posted {
                XCTAssertEqual(poster.callCount(), 1)
            } else {
                XCTAssertEqual(terminal.reason, .remoteDisabled)
                XCTAssertEqual(poster.callCount(), 0)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
