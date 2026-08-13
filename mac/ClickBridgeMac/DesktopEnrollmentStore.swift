import Foundation

struct DesktopEnrollmentRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let relayURL: String
    let macToken: String
    let enrollmentId: String
    let automaticRecoveryUsed: Bool

    init(
        relayURL: String,
        macToken: String,
        enrollmentId: String = UUID().uuidString.lowercased(),
        automaticRecoveryUsed: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.relayURL = relayURL
        self.macToken = macToken
        self.enrollmentId = enrollmentId
        self.automaticRecoveryUsed = automaticRecoveryUsed
    }

    func replacingAutomaticRecoveryUsed(_ used: Bool) -> DesktopEnrollmentRecord {
        DesktopEnrollmentRecord(
            relayURL: relayURL,
            macToken: macToken,
            enrollmentId: enrollmentId,
            automaticRecoveryUsed: used
        )
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && (try? RelayEndpoint.validated(relayURL, allowLocalSimulator: false)) != nil
            && macToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && UUID(uuidString: enrollmentId) != nil
    }
}

enum DesktopEnrollmentStoreError: LocalizedError {
    case invalidRecord

    var errorDescription: String? {
        "The saved relay enrollment is invalid."
    }
}

struct DesktopEnrollmentStore {
    static let account = "desktopEnrollment"

    private let secrets: any SecretStoring
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(secrets: any SecretStoring) {
        self.secrets = secrets
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> DesktopEnrollmentRecord? {
        guard let serialized = try secrets.read(account: Self.account) else { return nil }
        guard let data = serialized.data(using: .utf8),
              let record = try? decoder.decode(DesktopEnrollmentRecord.self, from: data),
              record.isValid else {
            throw DesktopEnrollmentStoreError.invalidRecord
        }
        return record
    }

    func save(_ record: DesktopEnrollmentRecord) throws {
        guard record.isValid,
              let serialized = String(data: try encoder.encode(record), encoding: .utf8) else {
            throw DesktopEnrollmentStoreError.invalidRecord
        }
        try secrets.write(serialized, account: Self.account)
    }

    func clear() throws {
        try secrets.delete(account: Self.account)
    }
}
