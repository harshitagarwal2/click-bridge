import Foundation

enum ActionIngress: String, Codable, Sendable { case oci, tailscale }

struct InputPostCounts: Sendable, Equatable {
    let mouseDownPostCount: Int
    let mouseUpPostCount: Int
    static let zero = InputPostCounts(mouseDownPostCount: 0, mouseUpPostCount: 0)
}

protocol ActionRequestSink: Sendable {
    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult
}

protocol DiagnosticCounterReading: Sendable {
    func diagnosticPostCounts() async -> InputPostCounts
}

struct RejectingActionSink: ActionRequestSink {
    func receive(_ request: ActionRequest, via ingress: ActionIngress) async -> ActionResult {
        ActionResult(actionId: request.actionId, status: .rejected, reason: .remoteDisabled,
                     acceptedVia: ingress, macProcessingUs: 0, mouseDownPostedUnixMs: nil)
    }
}

struct ZeroDiagnosticCounterReader: DiagnosticCounterReading {
    func diagnosticPostCounts() async -> InputPostCounts { .zero }
}
