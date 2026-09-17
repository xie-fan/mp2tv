import AVFoundation
import SwiftUI

/// 扫码配对页：AVCaptureMetadataOutput 识别 mp2tv:// 二维码。
struct ScanView: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onResult = onResult
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onResult: (String) -> Void = { _ in }
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video),
                  let inp = try? AVCaptureDeviceInput(device: dev),
                  session.canAddInput(inp) else { return }
            session.addInput(inp)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let prev = AVCaptureVideoPreviewLayer(session: session)
            prev.frame = view.bounds
            prev.videoGravity = .resizeAspectFill
            view.layer.addSublayer(prev)
            DispatchQueue.global().async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objs: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done,
                  let m = objs.first as? AVMetadataMachineReadableCodeObject,
                  let s = m.stringValue, s.hasPrefix("mp2tv://") else { return }
            done = true
            session.stopRunning()
            onResult(s)
        }
    }
}
