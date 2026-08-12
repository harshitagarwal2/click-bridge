import Foundation
import CoreGraphics

/// Posts one left click at wherever the cursor already is.
///
/// Deliberately synchronous so `ActionProcessor` cannot suspend around it.
struct MacInputExecutor: InputPosting {

    /// Gap between mouse-down and mouse-up. Starts at 0; raise to 30–50 ms only
    /// if a target ignores the click. Apple's forums report zero-gap synthetic
    /// clicks being dropped on Big Sur and later, so this is a named constant
    /// rather than something to hunt for later.
    var clickGapMs: UInt32 = UInt32(Constants.clickGapMs)

    func postLeftClickAtCurrentCursor() -> InputPostOutcome {
        // Global display coordinates, top-left origin — the same space CGEvent
        // mouse events expect. No NSEvent.mouseLocation flip needed.
        guard let probe = CGEvent(source: nil) else { return .creationFailed }
        let point = probe.location

        let source = CGEventSource(stateID: .hidSystemState)

        // Build BOTH events before posting either: a half-posted click (down
        // with no up) would leave the machine with a stuck mouse button.
        guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            return .creationFailed
        }

        // Synthesised events otherwise carry a click state that some apps treat
        // as invalid and silently ignore.
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        let mouseDownUnixMs = Date().timeIntervalSince1970 * 1000
        down.post(tap: .cghidEventTap)

        if clickGapMs > 0 {
            usleep(clickGapMs * 1000)
        }
        up.post(tap: .cghidEventTap)

        return .posted(mouseDownUnixMs: mouseDownUnixMs)
    }
}

/// PostEvent is a NARROWER TCC service than Accessibility.
///
/// Apple DTS confirms `PostEvent`, `ListenEvent`, and `Accessibility` are
/// distinct services. Using `AXIsProcessTrustedWithOptions` here would request
/// the broad Accessibility privilege when only event posting is needed.
/// The user still grants it under Privacy & Security → Accessibility.
struct PostEventPermissionService: PostEventPermissionChecking {

    /// Checks status. Never prompts.
    func isGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Prompts. Call ONLY from an explicit user action (the menu item).
    @discardableResult
    func requestFromUserAction() -> Bool {
        CGRequestPostEventAccess()
    }

    var permissionState: PermissionState {
        isGranted() ? .ready : .required
    }
}
