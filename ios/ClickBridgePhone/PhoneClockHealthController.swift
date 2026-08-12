import Foundation

struct ClockSample: Equatable, Sendable {
    let offsetMilliseconds: Double
    let roundTripMilliseconds: Double

    init(t0: Double, t1: Double, t2: Double, t3: Double) {
        offsetMilliseconds = ((t1 - t0) + (t2 - t3)) / 2
        roundTripMilliseconds = (t3 - t0) - (t2 - t1)
    }

    static func best(_ samples: [Self]) -> Self? {
        samples
            .filter { $0.roundTripMilliseconds.isFinite && $0.roundTripMilliseconds >= 0 }
            .min { $0.roundTripMilliseconds < $1.roundTripMilliseconds }
    }
}

@MainActor
final class PhoneClockHealthController {
    private struct PendingExchange {
        let syncID: UUID
        let phoneSendUnixMilliseconds: Double
        let socketGeneration: Int
        let batchToken: Int
        let timeout: ScheduledToken
    }

    private let clock: any PhoneClock
    private let scheduler: any PhoneScheduler
    private let makeSyncID: @MainActor () -> UUID
    private let isActionPending: @MainActor () -> Bool
    private let onHealth: @MainActor (ClockHealth) -> Void

    private var foregroundGeneration: Int?
    private var socketGeneration = 0
    private var send: (@MainActor (PhoneClientMessage) -> Bool)?
    private var batchToken = 0
    private var samples: [ClockSample] = []
    private var exchangeCount = 0
    private var pending: PendingExchange?
    private var refreshToken: ScheduledToken?
    private var refreshDeferred = false

    init(
        clock: any PhoneClock,
        scheduler: any PhoneScheduler,
        makeSyncID: @escaping @MainActor () -> UUID = UUID.init,
        isActionPending: @escaping @MainActor () -> Bool,
        onHealth: @escaping @MainActor (ClockHealth) -> Void
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.makeSyncID = makeSyncID
        self.isActionPending = isActionPending
        self.onHealth = onHealth
    }

    func start(
        foregroundGeneration: Int,
        socketGeneration: Int,
        send: @escaping @MainActor (PhoneClientMessage) -> Bool
    ) {
        stop()
        self.foregroundGeneration = foregroundGeneration
        self.socketGeneration = socketGeneration
        self.send = send
        beginBatch()
    }

    func handle(_ message: TimeSyncResponse, socketGeneration: Int) -> Bool {
        guard let pending,
              pending.batchToken == batchToken,
              pending.socketGeneration == socketGeneration,
              message.syncID == pending.syncID,
              message.phoneSendUnixMilliseconds == pending.phoneSendUnixMilliseconds else { return false }

        scheduler.cancel(pending.timeout)
        self.pending = nil
        let sample = ClockSample(
            t0: pending.phoneSendUnixMilliseconds,
            t1: message.macReceiveUnixMilliseconds,
            t2: message.macSendUnixMilliseconds,
            t3: clock.nowUnixMilliseconds()
        )
        if sample.roundTripMilliseconds.isFinite, sample.roundTripMilliseconds >= 0 {
            samples.append(sample)
        }
        exchangeCount += 1

        if exchangeCount == PhoneProtocolV1.clockSampleCount {
            finishBatch()
        } else {
            sendNextExchange()
        }
        return true
    }

    func actionDidSettle() {
        guard refreshDeferred, !isActionPending() else { return }
        refreshDeferred = false
        beginBatch()
    }

    func retry() {
        guard foregroundGeneration != nil, send != nil else { return }
        beginBatch()
    }

    func stop() {
        batchToken += 1
        if let pending { scheduler.cancel(pending.timeout) }
        if let refreshToken { scheduler.cancel(refreshToken) }
        pending = nil
        refreshToken = nil
        refreshDeferred = false
        samples.removeAll(keepingCapacity: true)
        exchangeCount = 0
        foregroundGeneration = nil
        send = nil
    }

    private func beginBatch() {
        batchToken += 1
        if let pending { scheduler.cancel(pending.timeout) }
        if let refreshToken { scheduler.cancel(refreshToken) }
        pending = nil
        refreshToken = nil
        refreshDeferred = false
        samples.removeAll(keepingCapacity: true)
        exchangeCount = 0
        onHealth(ClockHealth(status: .checking, offsetMilliseconds: nil, uncertaintyMilliseconds: nil))
        sendNextExchange()
    }

    private func sendNextExchange() {
        guard pending == nil, let send else { return }
        let expectedBatch = batchToken
        let syncID = makeSyncID()
        let t0 = clock.nowUnixMilliseconds()
        let request = TimeSyncRequest(syncID: syncID, phoneSendUnixMilliseconds: t0)
        guard send(.timeSyncRequest(request)) else {
            failBatch()
            return
        }

        let expectedSocketGeneration = socketGeneration
        let timeout = scheduler.schedule(after: PhoneProtocolV1.clockExchangeTimeout) { [weak self] in
            guard let self, let pending = self.pending,
                  pending.batchToken == expectedBatch,
                  pending.socketGeneration == expectedSocketGeneration,
                  pending.syncID == syncID else { return }
            self.pending = nil
            self.failBatch()
        }
        pending = PendingExchange(
            syncID: syncID,
            phoneSendUnixMilliseconds: t0,
            socketGeneration: expectedSocketGeneration,
            batchToken: expectedBatch,
            timeout: timeout
        )
    }

    private func finishBatch() {
        guard let selected = ClockSample.best(samples) else {
            failBatch()
            return
        }
        let uncertainty = selected.roundTripMilliseconds / 2
        let status: ClockHealth.Status = abs(selected.offsetMilliseconds)
            <= PhoneProtocolV1.clockSkewToleranceMilliseconds + uncertainty ? .healthy : .mismatch
        onHealth(ClockHealth(
            status: status,
            offsetMilliseconds: selected.offsetMilliseconds,
            uncertaintyMilliseconds: uncertainty
        ))
        scheduleRefresh()
    }

    private func failBatch() {
        if let pending { scheduler.cancel(pending.timeout) }
        pending = nil
        samples.removeAll(keepingCapacity: true)
        exchangeCount = 0
        onHealth(ClockHealth(status: .unavailable, offsetMilliseconds: nil, uncertaintyMilliseconds: nil))
    }

    private func scheduleRefresh() {
        refreshToken = scheduler.schedule(after: PhoneProtocolV1.clockRefreshInterval) { [weak self] in
            guard let self else { return }
            self.refreshToken = nil
            if self.isActionPending() {
                self.refreshDeferred = true
            } else {
                self.beginBatch()
            }
        }
    }
}
