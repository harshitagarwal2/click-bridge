import Foundation

/// Lock-protected snapshot of the Mac's user-controlled state.
///
/// Why this exists: `ActionProcessor` must decide whether to click **without
/// suspending** — no `await` may occur between reserving an actionId and
/// caching the terminal result, or two copies of the same action could both
/// pass the checks and both click. That rules out awaiting the main actor to
/// read `@Published` settings.
///
/// So the direction is inverted: the main actor *pushes* changes in here, and
/// the processor reads a plain synchronous snapshot from any thread.
///
/// The previous version called `MainActor.assumeIsolated` from inside the
/// actor's executor. That compiles, but the assumption is false — it would have
/// trapped on the first real click.
final class SharedMacState: RemoteToggleReading, @unchecked Sendable {

    private let lock = NSLock()
    private var _remoteEnabled: Bool
    private var _permission: PermissionState

    init(remoteEnabled: Bool = false, permission: PermissionState = .unknown) {
        self._remoteEnabled = remoteEnabled
        self._permission = permission
    }

    /// Called from inside `ActionProcessor`'s critical section. Synchronous by
    /// contract — see `InputPosting` for the same reasoning.
    func isRemoteEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _remoteEnabled
    }

    /// Read by `RelayClient` when publishing `mac.state`.
    var snapshot: (remoteEnabled: Bool, permission: PermissionState) {
        lock.lock()
        defer { lock.unlock() }
        return (_remoteEnabled, _permission)
    }

    func setRemoteEnabled(_ value: Bool) {
        lock.lock()
        _remoteEnabled = value
        lock.unlock()
    }

    func setPermission(_ value: PermissionState) {
        lock.lock()
        _permission = value
        lock.unlock()
    }
}
