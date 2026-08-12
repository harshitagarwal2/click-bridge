import Foundation

enum PhoneDeployment {
    static let pairingHost = "clickbridge-sjc.duckdns.org"
    static let associatedDomain = "applinks:\(pairingHost)"
    static let pairingAvailabilityCopy =
        "QR pairing connects to the compiled \(pairingHost) deployment. For another relay, use Advanced Legacy setup or rebuild the app for that host."
}
