import Foundation

/// Where an action entered the Mac. Recorded in the result and never mutated
/// afterwards, so a cached duplicate reports the ingress that actually clicked.
enum ActionIngress: String, Codable, Sendable {
    case oci
    case tailscale
}

enum InputPostOutcome: Sendable, Equatable {
    case posted(mouseDownUnixMs: Double)
    case creationFailed
}

/// Synchronous ON PURPOSE.
///
/// The actor must not suspend between reserving an action ID and caching its
/// terminal result. If this were `async`, two copies of the same action
/// arriving over two transports could both pass the seen-before check before
/// either posted — and the Mac would click twice.
protocol InputPosting: Sendable {
    func postLeftClickAtCurrentCursor() -> InputPostOutcome
}

protocol PostEventPermissionChecking: Sendable {
    func isGranted() -> Bool
}

protocol RemoteToggleReading: Sendable {
    func isRemoteEnabled() -> Bool
}

/// The only authority permitted to call `InputPosting`.
///
/// Guarantee: at-most-once execution per actionId while this process and its
/// in-memory table are alive. Exactly-once across a crash is NOT claimed.
actor ActionProcessor {

    private enum Entry {
        case processing(fingerprint: String)
        case completed(fingerprint: String, result: ActionResult, at: Date)
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    private let poster: InputPosting
    private let permission: PostEventPermissionChecking
    private let toggle: RemoteToggleReading
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let capacity: Int
    private let skewTolerance: TimeInterval

    /// Diagnostics only; proves how many CGEvent posts actually happened.
    private(set) var mouseDownPosts = 0
    private(set) var mouseUpPosts = 0

    init(
        poster: InputPosting,
        permission: PostEventPermissionChecking,
        toggle: RemoteToggleReading,
        now: @escaping @Sendable () -> Date = { Date() },
        ttl: TimeInterval = Constants.completedActionTTL,
        capacity: Int = Constants.completedActionCap,
        skewTolerance: TimeInterval = Constants.clockSkewTolerance
    ) {
        self.poster = poster
        self.permission = permission
        self.toggle = toggle
        self.now = now
        self.ttl = ttl
        self.capacity = capacity
        self.skewTolerance = skewTolerance
    }

    // MARK: - The critical section

    /// Handle one request. Contains NO `await` between reservation (step 6) and
    /// terminal caching (step 10), so it runs atomically within the actor.
    func receive(_ request: ActionRequest, via ingress: ActionIngress) -> ActionResult {
        let started = ContinuousClock.now
        let fingerprint = request.fingerprint

        // 1 — click-only, and the lifetime relation must be exact.
        guard request.action == "click",
              request.expiresAtUnixMs - request.issuedAtUnixMs == Constants.actionLifetimeMs else {
            return .rejected(request.actionId, .invalidRequest, ingress, started)
        }

        // 2 — drop entries past their protected window.
        pruneExpired()

        // 3 — same ID, different payload.
        if let existing = entries[request.actionId] {
            switch existing {
            case .processing(let fp), .completed(let fp, _, _):
                if fp != fingerprint {
                    return .rejected(request.actionId, .idConflict, ingress, started)
                }
            }
            // 4 — identical duplicate: return the EXACT cached result, unchanged.
            if case .completed(_, let cached, _) = existing {
                return cached
            }
            // Still processing (impossible inside one actor, but defensive).
            return .rejected(request.actionId, .idConflict, ingress, started)
        }

        // 5 — reject a stale action before doing anything real.
        let nowMs = now().timeIntervalSince1970 * 1000
        if nowMs > request.expiresAtUnixMs + skewTolerance * 1000 {
            return .rejected(request.actionId, .expired, ingress, started)
        }

        // 6 — fail closed when every slot is protected.
        if entries.count >= capacity {
            return .rejected(request.actionId, .capacityExceeded, ingress, started)
        }

        // 7 — CLAIM THE ID BEFORE ANY SIDE EFFECT. This is the whole trick.
        entries[request.actionId] = .processing(fingerprint: fingerprint)
        order.append(request.actionId)

        // 8 — gates.
        var result: ActionResult
        if !toggle.isRemoteEnabled() {
            result = .rejected(request.actionId, .remoteDisabled, ingress, started)
        } else if !permission.isGranted() {
            result = .rejected(request.actionId, .permissionRequired, ingress, started)
        } else {
            // 9 — post exactly once.
            switch poster.postLeftClickAtCurrentCursor() {
            case .posted(let mouseDownUnixMs):
                mouseDownPosts += 1
                mouseUpPosts += 1
                result = ActionResult(
                    actionId: request.actionId,
                    status: .posted,
                    reason: .ok,
                    acceptedVia: ingress,
                    macProcessingUs: Self.micros(since: started),
                    mouseDownPostedUnixMs: mouseDownUnixMs
                )
            case .creationFailed:
                result = .rejected(request.actionId, .eventCreationFailed, ingress, started)
            }
        }

        // 10 — replace processing with the terminal result before returning.
        entries[request.actionId] = .completed(
            fingerprint: fingerprint, result: result, at: now())
        return result
    }

    // MARK: - Cache maintenance

    /// Never evicts an unexpired or in-flight entry: a duplicate arriving
    /// inside the protected window must always hit the cache, never re-click.
    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-ttl)
        var kept: [String] = []
        kept.reserveCapacity(order.count)
        for id in order {
            guard let entry = entries[id] else { continue }
            switch entry {
            case .processing:
                kept.append(id)
            case .completed(_, _, let at):
                if at > cutoff { kept.append(id) } else { entries.removeValue(forKey: id) }
            }
        }
        order = kept
    }

    private static func micros(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1_000_000
            + Double(d.components.attoseconds) / 1_000_000_000_000
    }

    // MARK: - Test / diagnostics access

    func trackedCount() -> Int { entries.count }
    func postCounts() -> (down: Int, up: Int) { (mouseDownPosts, mouseUpPosts) }
    func resetDiagnostics() { mouseDownPosts = 0; mouseUpPosts = 0 }
}

private extension ActionResult {
    static func rejected(
        _ id: String,
        _ reason: ResultReason,
        _ ingress: ActionIngress,
        _ started: ContinuousClock.Instant
    ) -> ActionResult {
        let d = ContinuousClock.now - started
        let us = Double(d.components.seconds) * 1_000_000
            + Double(d.components.attoseconds) / 1_000_000_000_000
        return ActionResult(
            actionId: id,
            status: .rejected,
            reason: reason,
            acceptedVia: ingress,
            macProcessingUs: us,
            mouseDownPostedUnixMs: nil
        )
    }
}
