import Foundation

enum ActionIngress: String, Codable, Sendable { case oci, tailscale }

struct ActionAuthorizationGeneration: Hashable, Sendable {
    let credentialMutationEpoch: UInt64
    let connectionGeneration: Int
}

struct ActionAuthorizationLease: Hashable, Sendable {
    fileprivate let id = UUID()
    let generation: ActionAuthorizationGeneration
}

struct InputPostCounts: Sendable, Equatable {
    let mouseDownPostCount: Int
    let mouseUpPostCount: Int
    static let zero = InputPostCounts(mouseDownPostCount: 0, mouseUpPostCount: 0)
}

protocol ActionRequestSink: Sendable {
    func activateAuthorizationLease(for generation: ActionAuthorizationGeneration) async -> ActionAuthorizationLease
    func revokeAuthorizationLease(_ lease: ActionAuthorizationLease) async
    func receive(
        _ request: ActionRequest,
        via ingress: ActionIngress,
        authorization: ActionAuthorizationLease
    ) async -> ActionResult
}

protocol DiagnosticCounterReading: Sendable {
    func diagnosticPostCounts() async -> InputPostCounts
}
