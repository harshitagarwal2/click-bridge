import Foundation
import UIKit

struct ScheduledToken: Hashable, Sendable { let rawValue: UUID }

protocol PhoneClock: Sendable {
    func nowUnixMilliseconds() -> Double
    func nowMonotonicMilliseconds() -> Double
}

@MainActor
protocol PhoneScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> ScheduledToken
    func cancel(_ token: ScheduledToken)
}

@MainActor
protocol VolumeChangeSource: AnyObject {
    var currentVolume: Float { get }
    func start(observing handler: @escaping @MainActor (Float) -> Void) throws
    func stop()
}

@MainActor
protocol PhoneHaptics: AnyObject {
    func terminalResult(_ result: ActionResult)
}

@MainActor
protocol PhoneActionTransport: AnyObject {
    var generation: Int { get }
    var isAuthenticated: Bool { get }
    var onEvent: (@MainActor (PhoneTransportEvent) -> Void)? { get set }
    func connect(configuration: RelayConfiguration)
    func disconnect(reason: String)
    func send(_ message: PhoneClientMessage) -> Bool
}

struct PhoneWebSocketClosure {
    let code: Int?
    let error: Error?
}

@MainActor
protocol PhoneWebSocket: AnyObject {
    var onOpen: (@MainActor () -> Void)? { get set }
    var onText: (@MainActor (String) -> Void)? { get set }
    var onBinary: (@MainActor (Data) -> Void)? { get set }
    var onClose: (@MainActor (PhoneWebSocketClosure) -> Void)? { get set }
    func open(url: URL)
    func send(text: String) throws
    func close(code: URLSessionWebSocketTask.CloseCode, reason: String)
}

@MainActor
protocol PhoneWebSocketFactory: AnyObject {
    func makeSocket() -> any PhoneWebSocket
}

struct SystemPhoneClock: PhoneClock {
    func nowUnixMilliseconds() -> Double { Date().timeIntervalSince1970 * 1_000 }
    func nowMonotonicMilliseconds() -> Double { ProcessInfo.processInfo.systemUptime * 1_000 }
}

@MainActor
final class MainQueuePhoneScheduler: PhoneScheduler {
    private var workItems: [ScheduledToken: DispatchWorkItem] = [:]

    func schedule(after delay: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let token = ScheduledToken(rawValue: UUID())
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.workItems[token] = nil
                action()
            }
        }
        workItems[token] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }

    func cancel(_ token: ScheduledToken) {
        workItems.removeValue(forKey: token)?.cancel()
    }
}

@MainActor
final class TerminalNotificationHaptics: PhoneHaptics {
    func terminalResult(_ result: ActionResult) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(result.status == .posted ? .success : .error)
    }
}
