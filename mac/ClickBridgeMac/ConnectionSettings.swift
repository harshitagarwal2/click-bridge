import Foundation

struct ConnectionSettingsDraft: Equatable, Sendable {
    var appliedRelayURLString: String
    var relayURLString: String
    var replacementMacToken: String

    var hasChanges: Bool {
        relayURLString != appliedRelayURLString || !replacementMacToken.isEmpty
    }

    mutating func discardChanges() {
        relayURLString = appliedRelayURLString
        replacementMacToken = ""
    }

    mutating func reduce(
        outcome: ConnectionActionOutcome,
        acceptedRelayURLString: String
    ) {
        guard outcome == .accepted else { return }
        appliedRelayURLString = acceptedRelayURLString
        relayURLString = acceptedRelayURLString
        replacementMacToken = ""
    }

    mutating func reduceCredentialRemoval(outcome: ConnectionActionOutcome) {
        guard outcome == .accepted else { return }
        replacementMacToken = ""
    }
}

enum ConnectionTokenInput: Equatable, Sendable {
    case reuseStored
    case replacement(String)
}

struct ValidatedConnectionSettings: Equatable, Sendable {
    let relayURL: URL
    let relayURLString: String
    let tokenInput: ConnectionTokenInput
}

enum ConnectionSettingsValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidRelayURL
    case invalidReplacementToken

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return "Enter a secure relay URL ending in /ws."
        case .invalidReplacementToken:
            return "Enter a 64-character hexadecimal Mac token."
        }
    }
}

enum ConnectionSettingsValidator {
    static func validate(
        relayURLString: String,
        replacementMacToken: String
    ) throws -> ValidatedConnectionSettings {
        let normalizedURLString = relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayURL: URL
        do {
            relayURL = try RelayEndpoint.validated(normalizedURLString, allowLocalSimulator: false)
        } catch {
            throw ConnectionSettingsValidationError.invalidRelayURL
        }

        let trimmedToken = replacementMacToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenInput: ConnectionTokenInput
        if trimmedToken.isEmpty {
            tokenInput = .reuseStored
        } else {
            let normalizedToken = trimmedToken.lowercased()
            guard normalizedToken.utf8.count == 64,
                  normalizedToken.utf8.allSatisfy(Self.isLowercaseHex) else {
                throw ConnectionSettingsValidationError.invalidReplacementToken
            }
            tokenInput = .replacement(normalizedToken)
        }

        return ValidatedConnectionSettings(
            relayURL: relayURL,
            relayURLString: normalizedURLString,
            tokenInput: tokenInput
        )
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

struct StoredConnection: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let relayURLString: String
    let macToken: String
}
