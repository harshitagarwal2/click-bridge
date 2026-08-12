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
        controller.configure(delegate: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

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

private final class ScannerController: UIViewController {
    private let session = AVCaptureSession()

    func configure(delegate: AVCaptureMetadataOutputObjectsDelegate) {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        Task.detached { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }
}
