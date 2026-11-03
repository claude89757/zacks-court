import SwiftUI
import AVFoundation

/// A bounded background display path. Each mounted view owns its own renderer;
/// opening another window cannot steal the embedded view's CALayer.
final class PreviewPipeline: @unchecked Sendable {
    private final class Target {
        let layer: AVSampleBufferDisplayLayer
        var needsKeyframe = true
        init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
    }
    private let queue = DispatchQueue(label: "court.preview", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private var needsKeyframe = true
    private var size: CGSize?
    private var enqueued = 0
    // Target membership and decoder state are confined to queue.
    private var targets: [ObjectIdentifier: Target] = [:]
    var enqueuedFrames: Int { lock.lock(); defer { lock.unlock() }; return enqueued }
    var imageSize: CGSize? { lock.lock(); defer { lock.unlock() }; return size }
    var aspectRatio: CGFloat {
        guard let size = imageSize, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            let id = ObjectIdentifier(layer)
            if self?.targets[id] == nil { self?.targets[id] = Target(layer) }
        }
    }
    func detach(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            self?.targets.removeValue(forKey: ObjectIdentifier(layer))
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
    func submit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        lock.lock()
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        }
        guard pending < 6 else { needsKeyframe = true; lock.unlock(); return }
        guard !needsKeyframe || keyframe else { lock.unlock(); return }
        let flush = needsKeyframe
        needsKeyframe = false
        let currentGeneration = generation
        pending += 1
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == currentGeneration
            if current { self.pending -= 1 }
            self.lock.unlock()
            guard current else { return }
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true) as? [NSMutableDictionary] {
                attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            var delivered = false
            for target in self.targets.values {
                let renderer = target.layer.sampleBufferRenderer
                if flush || renderer.status == .failed || !renderer.isReadyForMoreMediaData { target.needsKeyframe = true }
                if target.needsKeyframe {
                    guard keyframe else { continue }
                    renderer.flush()
                    target.needsKeyframe = false
                }
                guard renderer.isReadyForMoreMediaData else { target.needsKeyframe = true; continue }
                renderer.enqueue(copy)
                delivered = true
            }
            if delivered { self.lock.lock(); self.enqueued += 1; self.lock.unlock() }
        }
        lock.unlock()
    }
    func clear() {
        lock.lock()
        generation += 1; pending = 0; needsKeyframe = true; size = nil
        queue.async { [weak self] in
            for target in self?.targets.values ?? Dictionary<ObjectIdentifier, Target>().values {
                target.needsKeyframe = true
                target.layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
        }
        lock.unlock()
    }
}

#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    let pipeline: PreviewPipeline
    func makeNSView(context: Context) -> VideoHostView { VideoHostView(pipeline: pipeline) }
    func updateNSView(_ view: VideoHostView, context: Context) {}
    static func dismantleNSView(_ view: VideoHostView, coordinator: ()) { view.detach() }
}

final class VideoHostView: NSView {
    let video = AVSampleBufferDisplayLayer()
    private let pipeline: PreviewPipeline
    init(pipeline: PreviewPipeline) {
        self.pipeline = pipeline
        super.init(frame: .zero)
        video.videoGravity = .resizeAspect
        video.backgroundColor = CGColor(gray: 0, alpha: 1)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { video }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { pipeline.attach(video) }
    }
    func detach() { pipeline.detach(video) }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraHostView { CameraHostView(session: session) }
    func updateNSView(_ view: CameraHostView, context: Context) {}
}

final class CameraHostView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        preview.videoGravity = .resizeAspect
        wantsLayer = true; layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}
#else
struct VideoSurface: UIViewRepresentable {
    let pipeline: PreviewPipeline
    func makeUIView(context: Context) -> VideoHostView { VideoHostView(pipeline: pipeline) }
    func updateUIView(_ view: VideoHostView, context: Context) {}
    static func dismantleUIView(_ view: VideoHostView, coordinator: ()) { view.detach() }
}

final class VideoHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var video: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private let pipeline: PreviewPipeline
    init(pipeline: PreviewPipeline) {
        self.pipeline = pipeline
        super.init(frame: .zero)
        video.videoGravity = .resizeAspect
        video.backgroundColor = CGColor(gray: 0, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { pipeline.attach(video) }
    }
    func detach() { pipeline.detach(video) }
}

/// The capture model fixes one landscape direction until capture stops. Preview
/// uses its own coordinator because layer and capture rotation may differ.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraHostView {
        let view = CameraHostView()
        view.preview.session = session; view.preview.videoGravity = .resizeAspect
        view.configureRotation()
        return view
    }
    func updateUIView(_ view: CameraHostView, context: Context) { view.configureRotation() }
    static func dismantleUIView(_ view: CameraHostView, coordinator: ()) { view.releaseRotation() }
}

final class CameraHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseRotation() } else { configureRotation() }
    }
    override func layoutSubviews() { super.layoutSubviews(); configureRotation() }
    func configureRotation() {
        guard window != nil,
              let device = preview.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first?.device else { return }
        if rotationCoordinator?.device !== device {
            releaseRotation()
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyRotation(angle) }
            }
        }
        if let coordinator = rotationCoordinator { applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview) }
    }
    private func applyRotation(_ angle: CGFloat) {
        guard window != nil, let connection = preview.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
    }
    func releaseRotation() { rotationObservation = nil; rotationCoordinator = nil }
}
#endif
