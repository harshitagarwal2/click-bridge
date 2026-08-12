import AVFoundation
import SwiftUI

struct PairingScannerView: View {
    let receive: (String) -> Void
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch authorization {
            case .authorized:
                CameraCodeScanner(receive: receive)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Pairing code scanner")
                    .accessibilityHint("Point the camera at the pairing code shown on your Mac")
            case .denied, .restricted:
                ContentUnavailableView("Camera access is off",
                                       systemImage: "camera.fill",
                                       description: Text("Allow camera access in Settings, or paste the pairing link below."))
            case .notDetermined:
                ProgressView("Requesting camera access…")
                    .task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        authorization = AVCaptureDevice.authorizationStatus(for: .video)
                    }
            @unknown default:
                Text("Camera scanning is unavailable. Paste the pairing link below.")
            }
        }
        .frame(minHeight: 260)
    }
}

private struct CameraCodeScanner: UIViewControllerRepresentable {
    let receive: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(receive: receive) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        if !controller.configure(delegate: context.coordinator) {
            controller.showUnavailableFallback()
        }
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: Coordinator) {
        controller.stopCapture()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let receive: (String) -> Void
        private var delivered = false

        init(receive: @escaping (String) -> Void) { self.receive = receive }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered,
                  let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            delivered = true
            receive(code)
        }
    }
}

@MainActor
final class ScannerController: UIViewController {
    private let capture: any CaptureSessionControlling

    init(capture: any CaptureSessionControlling = CaptureSessionController()) {
        self.capture = capture
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureSessionFailed),
            name: .AVCaptureSessionRuntimeError,
            object: capture.session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureSessionFailed),
            name: .AVCaptureSessionWasInterrupted,
            object: capture.session
        )
    }

    func configure(delegate: AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              capture.session.canAddInput(input) else { return false }
        capture.session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.session.canAddOutput(output) else { return false }
        capture.session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: capture.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        capture.start()
        return true
    }

    func showUnavailableFallback() {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "camera.fill")
        configuration.text = "Camera unavailable"
        configuration.secondaryText = "Paste the pairing link below."
        contentUnavailableConfiguration = configuration
    }

    @objc private func captureSessionFailed() {
        handleCaptureFailure()
    }

    func handleCaptureFailure() {
        stopCapture()
        showUnavailableFallback()
    }

    func stopCapture() {
        capture.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopCapture()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

protocol CaptureSessionControlling: AnyObject {
    var session: AVCaptureSession { get }
    func start()
    func stop()
}

private final class CaptureSessionController: CaptureSessionControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.clickbridge.phone.pairing-camera")

    func start() {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}
