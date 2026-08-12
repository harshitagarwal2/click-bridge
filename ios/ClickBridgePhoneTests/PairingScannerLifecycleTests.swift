import AVFoundation
import XCTest
@testable import ClickBridgePhone

@MainActor
final class PairingScannerLifecycleTests: XCTestCase {
    func testRemovalStopsCaptureOnOwnedController() {
        let capture = FakeScannerCaptureSession()
        let controller = ScannerController(capture: capture)

        controller.stopCapture()

        XCTAssertEqual(capture.stopCount, 1)
    }

    func testRuntimeFailureStopsCaptureAndSurfacesPasteFallback() {
        let capture = FakeScannerCaptureSession()
        let controller = ScannerController(capture: capture)
        controller.loadViewIfNeeded()

        NotificationCenter.default.post(name: .AVCaptureSessionRuntimeError,
                                        object: capture.session)

        XCTAssertEqual(capture.stopCount, 1)
        let fallback = controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        XCTAssertEqual(fallback?.text, "Camera unavailable")
        XCTAssertEqual(fallback?.secondaryText,
                       "Paste the pairing link below.")
    }
}

private final class FakeScannerCaptureSession: CaptureSessionControlling {
    let session = AVCaptureSession()
    private(set) var stopCount = 0

    func start() {}
    func stop() { stopCount += 1 }
}
