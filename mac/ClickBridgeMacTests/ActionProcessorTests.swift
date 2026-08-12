import XCTest
@testable import ClickBridgeMac

/// Counts posts and can be driven from any task.
final class FakePoster: InputPosting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    var outcome: InputPostOutcome = .posted(mouseDownUnixMs: 1_786_497_600_068)

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        lock.lock(); calls += 1; lock.unlock()
        return outcome
    }
}

struct FakePermission: PostEventPermissionChecking {
    var granted = true
    func isGranted() -> Bool { granted }
}

struct FakeToggle: RemoteToggleReading {
    var enabled = true
    func isRemoteEnabled() -> Bool { enabled }
}

private func makeRequest(
    id: String = UUID().uuidString.lowercased(),
    issued: Double = Date().timeIntervalSince1970 * 1000
) -> ActionRequest {
    ActionRequest(
        actionId: id,
        action: "click",
        issuedAtUnixMs: issued,
        expiresAtUnixMs: issued + Constants.actionLifetimeMs
    )
}

private func makeProcessor(
    poster: FakePoster = FakePoster(),
    permission: FakePermission = FakePermission(),
    toggle: FakeToggle = FakeToggle()
) -> ActionProcessor {
    ActionProcessor(poster: poster, permission: permission, toggle: toggle)
}

final class ActionProcessorTests: XCTestCase {

    func testValidRequestPostsExactlyOnce() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let result = await p.receive(makeRequest(), via: .oci)

        XCTAssertEqual(result.status, .posted)
        XCTAssertEqual(result.reason, .ok)
        XCTAssertEqual(result.acceptedVia, .oci)
        XCTAssertNotNil(result.mouseDownPostedUnixMs)
        XCTAssertEqual(poster.calls, 1)
    }

    func testRemoteDisabledPostsNothing() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster, toggle: FakeToggle(enabled: false))
        let result = await p.receive(makeRequest(), via: .oci)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reason, .remoteDisabled)
        XCTAssertNil(result.mouseDownPostedUnixMs)
        XCTAssertEqual(poster.calls, 0)
    }

    func testMissingPermissionPostsNothing() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster, permission: FakePermission(granted: false))
        let result = await p.receive(makeRequest(), via: .oci)

        XCTAssertEqual(result.reason, .permissionRequired)
        XCTAssertEqual(poster.calls, 0)
    }

    func testEventCreationFailurePostsNothing() async {
        let poster = FakePoster()
        poster.outcome = .creationFailed
        let p = makeProcessor(poster: poster)
        let result = await p.receive(makeRequest(), via: .oci)

        XCTAssertEqual(result.reason, .eventCreationFailed)
        XCTAssertNil(result.mouseDownPostedUnixMs)
    }

    func testExpiredRequestPostsNothing() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let stale = Date().timeIntervalSince1970 * 1000 - 60_000
        let result = await p.receive(makeRequest(issued: stale), via: .oci)

        XCTAssertEqual(result.reason, .expired)
        XCTAssertEqual(poster.calls, 0)
    }

    func testDuplicateReturnsTheExactCachedResult() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let request = makeRequest()

        let first = await p.receive(request, via: .oci)
        let second = await p.receive(request, via: .tailscale)

        // The cached wire result is returned UNCHANGED — including acceptedVia
        // and timestamps. Mutating it would mean two callers see different
        // bytes for the same actionId.
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.acceptedVia, .oci, "ingress reflects who actually clicked")
        XCTAssertEqual(poster.calls, 1)
    }

    func testSameIdDifferentPayloadIsAConflict() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let id = UUID().uuidString.lowercased()
        let now = Date().timeIntervalSince1970 * 1000

        _ = await p.receive(makeRequest(id: id, issued: now), via: .oci)
        let conflict = await p.receive(makeRequest(id: id, issued: now + 1), via: .oci)

        XCTAssertEqual(conflict.reason, .idConflict)
        XCTAssertEqual(poster.calls, 1, "no second click")
    }

    func testInvalidLifetimeIsRejected() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let now = Date().timeIntervalSince1970 * 1000
        var bad = makeRequest(issued: now)
        bad.expiresAtUnixMs = now + 9999            // not exactly the lifetime

        let result = await p.receive(bad, via: .oci)
        XCTAssertEqual(result.reason, .invalidRequest)
        XCTAssertEqual(poster.calls, 0)
    }

    func testNonClickActionIsRejected() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        var bad = makeRequest()
        bad.action = "key"

        let result = await p.receive(bad, via: .oci)
        XCTAssertEqual(result.reason, .invalidRequest)
        XCTAssertEqual(poster.calls, 0)
    }

    /// The gate that makes dual-path racing safe.
    func testThousandConcurrentDuplicatesPostOnce() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)
        let request = makeRequest()

        let results = await withTaskGroup(of: ActionResult.self) { group -> [ActionResult] in
            for i in 0..<1000 {
                group.addTask {
                    await p.receive(request, via: i.isMultiple(of: 2) ? .oci : .tailscale)
                }
            }
            var all: [ActionResult] = []
            for await r in group { all.append(r) }
            return all
        }

        XCTAssertEqual(poster.calls, 1, "exactly one CGEvent post for one actionId")
        XCTAssertEqual(results.count, 1000)

        let unique = Set(results.map { "\($0.status)|\($0.reason)|\($0.acceptedVia)" })
        XCTAssertEqual(unique.count, 1, "every caller saw the same terminal result")

        let counts = await p.postCounts()
        XCTAssertEqual(counts.down, 1)
        XCTAssertEqual(counts.up, 1)
    }

    func testDistinctIdsEachPostOnce() async {
        let poster = FakePoster()
        let p = makeProcessor(poster: poster)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = await p.receive(makeRequest(), via: .oci) }
            }
        }
        XCTAssertEqual(poster.calls, 200)
    }

    func testCapacityFailsClosed() async {
        let poster = FakePoster()
        let p = ActionProcessor(
            poster: poster,
            permission: FakePermission(),
            toggle: FakeToggle(),
            capacity: 3
        )
        for _ in 0..<3 { _ = await p.receive(makeRequest(), via: .oci) }
        let overflow = await p.receive(makeRequest(), via: .oci)

        XCTAssertEqual(overflow.reason, .capacityExceeded)
        XCTAssertEqual(poster.calls, 3, "no click once the cache is saturated")
    }

    func testTTLCleanupNeverAdmitsADuplicateInsideTheWindow() async {
        let poster = FakePoster()
        var clock = Date()
        let p = ActionProcessor(
            poster: poster,
            permission: FakePermission(),
            toggle: FakeToggle(),
            now: { clock },
            ttl: 300
        )
        let request = makeRequest(issued: clock.timeIntervalSince1970 * 1000)

        _ = await p.receive(request, via: .oci)
        clock = clock.addingTimeInterval(299)                 // still protected
        let dup = await p.receive(request, via: .oci)

        XCTAssertEqual(dup.status, .posted, "served from cache")
        XCTAssertEqual(poster.calls, 1, "no second click inside the window")
    }

    func testCompletedEntriesAreEvictedAfterTheTTL() async {
        let poster = FakePoster()
        var clock = Date()
        let p = ActionProcessor(
            poster: poster,
            permission: FakePermission(),
            toggle: FakeToggle(),
            now: { clock },
            ttl: 300
        )
        _ = await p.receive(makeRequest(issued: clock.timeIntervalSince1970 * 1000), via: .oci)
        XCTAssertEqual(await p.trackedCount(), 1)

        clock = clock.addingTimeInterval(600)
        _ = await p.receive(makeRequest(issued: clock.timeIntervalSince1970 * 1000), via: .oci)
        XCTAssertEqual(await p.trackedCount(), 1, "the stale entry was pruned")
    }

    /// Randomised arrival order across both ingresses, repeated many times.
    func testAdversarialArrivalOrderNeverDoubleClicks() async {
        for _ in 0..<200 {
            let poster = FakePoster()
            let p = makeProcessor(poster: poster)
            let request = makeRequest()
            let ingresses: [ActionIngress] = (0..<8).map { _ in
                Bool.random() ? .oci : .tailscale
            }
            await withTaskGroup(of: Void.self) { group in
                for via in ingresses {
                    group.addTask { _ = await p.receive(request, via: via) }
                }
            }
            XCTAssertEqual(poster.calls, 1)
        }
    }
}
