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

private final class BlockingPoster: InputPosting, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        started.signal()
        release.wait()
        lock.withLock { calls += 1 }
        return .posted(mouseDownUnixMs: 1_000)
    }

    func diagnosticPostCounts() -> InputPostCounts {
        lock.withLock { InputPostCounts(mouseDownPostCount: calls, mouseUpPostCount: calls) }
    }

    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 1) == .success }
    func unblock() { release.signal() }
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

private actor ActivationGatedSink: ActionRequestSink {
    private let processor: ActionProcessor
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var activationStarted = false

    init(processor: ActionProcessor) { self.processor = processor }

    func activateAuthorizationLease(
        for generation: ActionAuthorizationGeneration
    ) async -> ActionAuthorizationLease {
        activationStarted = true
        await withCheckedContinuation { continuation = $0 }
        return await processor.activateAuthorizationLease(for: generation)
    }

    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) async {
        await processor.revokeAuthorizationLease(lease)
    }

    func receive(
        _ request: ActionRequest,
        via ingress: ActionIngress,
        authorization: ActionAuthorizationLease
    ) async -> ActionResult {
        await processor.receive(request, via: ingress, authorization: authorization)
    }

    func releaseActivation() {
        continuation?.resume()
        continuation = nil
    }
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

    func testFutureIssuedRequestAcceptsSkewBoundaryAndRejectsOneMillisecondBeyondIt() async {
        let poster = LockedPoster()
        let clock = LockedClock(base)
        let subject = processor(poster: poster, clock: clock)
        await subject.setRemoteEnabled(true)

        let boundary = await subject.receive(
            request(id: "boundary", issued: base + Constants.clockSkewTolerance * 1_000),
            via: .oci
        )
        XCTAssertEqual(boundary.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)

        let futurePoster = LockedPoster()
        let futureSubject = processor(poster: futurePoster, clock: clock)
        await futureSubject.setRemoteEnabled(true)
        let future = await futureSubject.receive(
            request(id: "future", issued: base + Constants.clockSkewTolerance * 1_000 + 1),
            via: .oci
        )
        XCTAssertEqual(future.reason, .invalidRequest)
        XCTAssertEqual(futurePoster.callCount(), 0)
        let tracked = await futureSubject.trackedActionCount()
        XCTAssertEqual(tracked, 0)
    }

    func testFutureIssuedReplayAfterCompletedCacheTTLNeverPosts() async {
        let poster = LockedPoster()
        let clock = LockedClock(base)
        let subject = processor(poster: poster, clock: clock, ttl: 1)
        await subject.setRemoteEnabled(true)
        let future = request(
            id: "future-replay",
            issued: base + 10_000
        )

        let first = await subject.receive(future, via: .oci)
        XCTAssertEqual(first.reason, .invalidRequest)
        XCTAssertEqual(poster.callCount(), 0)
        let firstTracked = await subject.trackedActionCount()
        XCTAssertEqual(firstTracked, 0)

        clock.advance(2_000)
        let replay = await subject.receive(future, via: .tailscale)
        XCTAssertEqual(replay.reason, .invalidRequest)
        XCTAssertEqual(poster.callCount(), 0)
        let replayTracked = await subject.trackedActionCount()
        XCTAssertEqual(replayTracked, 0)
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

    func testRevocationWaitsForAdmittedPostAndNoPostOccursAfterItReturns() async {
        let poster = BlockingPoster()
        let subject = ActionProcessor(poster: poster, permission: LockedPermission(),
                                      nowMilliseconds: { self.base })
        await subject.setRemoteEnabled(true)
        let lease = await subject.activateAuthorizationLease(
            for: ActionAuthorizationGeneration(credentialMutationEpoch: 1, connectionGeneration: 1)
        )
        let action = request(id: "admitted")
        let posting = Task { await subject.receive(action, via: .oci, authorization: lease) }
        XCTAssertTrue(poster.waitUntilStarted())

        let revoked = DispatchSemaphore(value: 0)
        let revoking = Task {
            await subject.revokeAuthorizationLease(lease)
            revoked.signal()
        }
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.1), .timedOut)
        poster.unblock()

        let result = await posting.value
        await revoking.value
        XCTAssertEqual(result.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testStaleRevokeCannotDisableNewGenerationAndStaleRejectionDoesNotCache() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let oldLease = await subject.activateAuthorizationLease(
            for: ActionAuthorizationGeneration(credentialMutationEpoch: 1, connectionGeneration: 1)
        )
        let newLease = await subject.activateAuthorizationLease(
            for: ActionAuthorizationGeneration(credentialMutationEpoch: 2, connectionGeneration: 2)
        )
        await subject.revokeAuthorizationLease(oldLease)
        let action = request(id: "same-external-revision")

        let stale = await subject.receive(action, via: .oci, authorization: oldLease)
        let current = await subject.receive(action, via: .oci, authorization: newLease)

        XCTAssertEqual(stale.status, .rejected)
        XCTAssertEqual(current.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testDelayedOlderActivationCannotReplaceNewerLease() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let gatedSink = ActivationGatedSink(processor: subject)
        let oldGeneration = ActionAuthorizationGeneration(credentialMutationEpoch: 1, connectionGeneration: 1)
        let newGeneration = ActionAuthorizationGeneration(credentialMutationEpoch: 2, connectionGeneration: 2)

        let activatingOld = Task { await gatedSink.activateAuthorizationLease(for: oldGeneration) }
        for _ in 0..<100 where !(await gatedSink.activationStarted) {
            await Task.yield()
        }
        let activationStarted = await gatedSink.activationStarted
        XCTAssertTrue(activationStarted)
        let newLease = await subject.activateAuthorizationLease(for: newGeneration)
        await gatedSink.releaseActivation()
        let oldLease = await activatingOld.value
        await gatedSink.revokeAuthorizationLease(oldLease)

        let stale = await subject.receive(request(id: "delayed-old"), via: .oci, authorization: oldLease)
        let current = await subject.receive(request(id: "current-after-delay"), via: .oci,
                                            authorization: newLease)

        XCTAssertEqual(stale.status, .rejected)
        XCTAssertEqual(current.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testOlderActivationAfterNewerGenerationCannotMutateCurrentLease() async {
        let poster = LockedPoster()
        let subject = processor(poster: poster)
        await subject.setRemoteEnabled(true)
        let newGeneration = ActionAuthorizationGeneration(credentialMutationEpoch: 3, connectionGeneration: 4)
        let oldGeneration = ActionAuthorizationGeneration(credentialMutationEpoch: 3, connectionGeneration: 3)

        let newLease = await subject.activateAuthorizationLease(for: newGeneration)
        let repeatedNewLease = await subject.activateAuthorizationLease(for: newGeneration)
        let oldLease = await subject.activateAuthorizationLease(for: oldGeneration)
        await subject.revokeAuthorizationLease(oldLease)

        XCTAssertEqual(repeatedNewLease, newLease)
        let stale = await subject.receive(request(id: "older-direct"), via: .oci, authorization: oldLease)
        let current = await subject.receive(request(id: "newer-direct"), via: .oci, authorization: newLease)
        XCTAssertEqual(stale.status, .rejected)
        XCTAssertEqual(current.status, .posted)
        XCTAssertEqual(poster.callCount(), 1)
    }

    func testRemoteDisableWaitsForAdmittedPostThenRejectsQueuedWork() async {
        let poster = BlockingPoster()
        let subject = ActionProcessor(poster: poster, permission: LockedPermission(),
                                      nowMilliseconds: { self.base })
        await subject.setRemoteEnabled(true)
        let posting = Task { await subject.receive(self.request(id: "before-disable"), via: .tailscale) }
        XCTAssertTrue(poster.waitUntilStarted())

        let disabled = DispatchSemaphore(value: 0)
        let disabling = Task {
            await subject.setRemoteEnabled(false)
            disabled.signal()
        }
        XCTAssertEqual(disabled.wait(timeout: .now() + 0.1), .timedOut)
        poster.unblock()
        let result = await posting.value
        XCTAssertEqual(result.status, .posted)
        await disabling.value

        let rejected = await subject.receive(request(id: "after-disable"), via: .tailscale)
        XCTAssertEqual(rejected.reason, .remoteDisabled)
        XCTAssertEqual(poster.callCount(), 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
