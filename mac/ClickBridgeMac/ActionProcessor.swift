import Foundation

enum InputPostOutcome: Sendable, Equatable {
    case posted(mouseDownUnixMs: Double)
    case creationFailed
}

protocol InputPosting: Sendable {
    func postLeftClickAtCurrentCursor() -> InputPostOutcome
    func diagnosticPostCounts() -> InputPostCounts
}

protocol PostEventPermissionChecking: Sendable { func isGranted() -> Bool }

actor ActionProcessor: ActionRequestSink, DiagnosticCounterReading {
    private enum Entry {
        case processing
        case completed(fingerprint: String, result: ActionResult, completedAtMilliseconds: Double)
    }

    private let poster: any InputPosting
    private let permission: any PostEventPermissionChecking
    private let nowMilliseconds: @Sendable () -> Double
    private let ttlMilliseconds: Double
    private let capacity: Int
    private let skewToleranceMilliseconds: Double
    private var remoteEnabled = false
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(
        poster: any InputPosting,
        permission: any PostEventPermissionChecking,
        nowMilliseconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
        ttl: TimeInterval = Constants.completedActionTTL,
        capacity: Int = Constants.completedActionCap,
        skewTolerance: TimeInterval = Constants.clockSkewTolerance
    ) {
        self.poster = poster
        self.permission = permission
        self.nowMilliseconds = nowMilliseconds
        ttlMilliseconds = ttl * 1_000
        self.capacity = capacity
        skewToleranceMilliseconds = skewTolerance * 1_000
    }

    func setRemoteEnabled(_ enabled: Bool) { remoteEnabled = enabled }

    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult {
        let started = ContinuousClock.now
        guard request.action == "click",
              request.expiresAtUnixMs - request.issuedAtUnixMs == Constants.actionLifetimeMs else {
            return rejected(request.actionId, .invalidRequest, ingress, started)
        }

        let currentMilliseconds = nowMilliseconds()
        guard request.issuedAtUnixMs <= currentMilliseconds + skewToleranceMilliseconds else {
            return rejected(request.actionId, .invalidRequest, ingress, started)
        }
        guard currentMilliseconds <= request.expiresAtUnixMs + skewToleranceMilliseconds else {
            return rejected(request.actionId, .expired, ingress, started)
        }

        pruneExpired(nowMilliseconds: currentMilliseconds)
        let fingerprint = request.fingerprint
        if let existing = entries[request.actionId] {
            switch existing {
            case .processing:
                return rejected(request.actionId, .idConflict, ingress, started)
            case .completed(let existingFingerprint, let cached, _):
                guard existingFingerprint == fingerprint else {
                    return rejected(request.actionId, .idConflict, ingress, started)
                }
                return cached
            }
        }

        guard entries.count < capacity else {
            return rejected(request.actionId, .capacityExceeded, ingress, started)
        }

        entries[request.actionId] = .processing
        order.append(request.actionId)

        let result: ActionResult
        if !remoteEnabled {
            result = rejected(request.actionId, .remoteDisabled, ingress, started)
        } else if !permission.isGranted() {
            result = rejected(request.actionId, .permissionRequired, ingress, started)
        } else {
            switch poster.postLeftClickAtCurrentCursor() {
            case .posted(let timestamp):
                result = ActionResult(actionId: request.actionId, status: .posted, reason: .ok,
                                      acceptedVia: ingress, macProcessingUs: elapsedMicroseconds(started),
                                      mouseDownPostedUnixMs: timestamp)
            case .creationFailed:
                result = rejected(request.actionId, .eventCreationFailed, ingress, started)
            }
        }

        entries[request.actionId] = .completed(fingerprint: fingerprint,
                                               result: result,
                                               completedAtMilliseconds: nowMilliseconds())
        return result
    }

    func diagnosticPostCounts() -> InputPostCounts { poster.diagnosticPostCounts() }
    func trackedActionCount() -> Int { entries.count }

    private func pruneExpired(nowMilliseconds: Double) {
        let cutoff = nowMilliseconds - ttlMilliseconds
        order.removeAll { id in
            guard let entry = entries[id] else { return true }
            switch entry {
            case .processing: return false
            case .completed(_, _, let completedAt) where completedAt > cutoff: return false
            case .completed:
                entries.removeValue(forKey: id)
                return true
            }
        }
    }

    private func rejected(
        _ id: String, _ reason: ResultReason, _ ingress: ActionIngress,
        _ started: ContinuousClock.Instant
    ) -> ActionResult {
        ActionResult(actionId: id, status: .rejected, reason: reason, acceptedVia: ingress,
                     macProcessingUs: elapsedMicroseconds(started), mouseDownPostedUnixMs: nil)
    }

    private func elapsedMicroseconds(_ started: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - started
        return Double(duration.components.seconds) * 1_000_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000
    }
}
