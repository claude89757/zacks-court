#if os(iOS)
import SwiftUI
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode; controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "court.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var completed = false // main thread only
    private var stopped = false // scanner queue only

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            if allowed { self.queue.async { self.configure() } }
            else { DispatchQueue.main.async { if !self.completed { self.onError?("需要相机权限才能扫码。请在系统设置中允许相机访问。") } } }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let angle: CGFloat
        switch orientation {
        case .landscapeRight: angle = 0
        case .landscapeLeft: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    func stop() {
        completed = true
        queue.async { [self] in
            stopped = true
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
    }
    private func configure() {
        guard !stopped else { return }
        do {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用摄像头。"])
            }
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法配置扫码相机。"])
            }
            session.addInput(input); session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            session.commitConfiguration(); session.startRunning()
            DispatchQueue.main.async { [weak self] in self?.view.setNeedsLayout() }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.completed else { return }
                self.onError?("无法打开扫码相机：\(error.localizedDescription)")
            }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !completed, let text = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        stop(); onCode?(text)
    }
}
#endif
