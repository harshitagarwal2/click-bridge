import Foundation

protocol PhoneManagementTransport: Sendable {
    func sendPhoneManagement(_ message: WireMessage) async throws
}

@MainActor
final class PhoneManagementController: ObservableObject {
    struct Phone: Identifiable, Equatable {
        let deviceId: String
        var label: String
        var credentialVersion: Int
        var id: String { deviceId }
    }

    enum RevokeState: Equatable {
        case idle
        case revoking(deviceId: String)
        case failed(deviceId: String, reason: PhoneRevokeFailureReason)
    }

    @Published private(set) var phones: [Phone] = []
    @Published private(set) var isLoading = false
    @Published private(set) var revokeState: RevokeState = .idle

    private let transport: any PhoneManagementTransport
    private let requestID: () -> String
    private var currentListRequestID: String?
    private var currentRevokeRequestID: String?
    private var currentRevokeDeviceID: String?

    init(
        transport: any PhoneManagementTransport,
        requestID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.transport = transport
        self.requestID = requestID
    }

    func refresh() async {
        let identifier = requestID()
        currentListRequestID = identifier
        isLoading = true
        do {
            try await transport.sendPhoneManagement(.phoneListRequest(PhoneListRequest(requestId: identifier)))
        } catch {
            guard currentListRequestID == identifier else { return }
            isLoading = false
            currentListRequestID = nil
        }
    }

    func revoke(deviceId: String) async {
        guard currentRevokeRequestID == nil else { return }
        let identifier = requestID()
        currentRevokeRequestID = identifier
        currentRevokeDeviceID = deviceId
        revokeState = .revoking(deviceId: deviceId)
        do {
            try await transport.sendPhoneManagement(
                .phoneRevokeRequest(PhoneRevokeRequest(requestId: identifier, deviceId: deviceId))
            )
        } catch {
            guard currentRevokeRequestID == identifier else { return }
            currentRevokeRequestID = nil
            currentRevokeDeviceID = nil
            revokeState = .idle
        }
    }

    func receive(_ message: WireMessage) async {
        switch message {
        case .phoneList(let list) where list.requestId == currentListRequestID:
            isLoading = false
            currentListRequestID = nil
            phones = list.phones.map {
                Phone(deviceId: $0.deviceId, label: $0.label, credentialVersion: $0.credentialVersion)
            }
        case .phoneRevoked(let revoked) where revoked.requestId == currentRevokeRequestID:
            currentRevokeRequestID = nil
            currentRevokeDeviceID = nil
            revokeState = .idle
            phones.removeAll { $0.deviceId == revoked.deviceId }
        case .phoneRevokeFailed(let failed) where failed.requestId == currentRevokeRequestID:
            currentRevokeRequestID = nil
            let deviceId = currentRevokeDeviceID ?? failed.deviceId
            currentRevokeDeviceID = nil
            revokeState = .failed(deviceId: deviceId, reason: failed.reason)
        default:
            break
        }
    }

    func dismissRevokeFailure() {
        guard case .failed = revokeState else { return }
        revokeState = .idle
    }
}
