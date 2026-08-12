import CoreGraphics

struct PostEventPermissionService: PostEventPermissionChecking {
    private let preflight: @Sendable () -> Bool
    private let request: @Sendable () -> Bool

    init(
        preflight: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        request: @escaping @Sendable () -> Bool = { CGRequestPostEventAccess() }
    ) {
        self.preflight = preflight
        self.request = request
    }

    func isGranted() -> Bool { preflight() }
    @discardableResult func requestFromUserAction() -> Bool { request() }
}
