import Foundation
import AVFoundation
import CourtCore

/// Capture only. Every delivered frame goes to the shared `CameraMediaPipeline` on the same
/// serial queue, which records, previews and feeds camera-side analysis (docs/camera-side-analysis.md §3).
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// (status text, capturing)
    var onState: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    /// Every delivered capture frame, on the camera queue, after the pipeline saw it.
    /// Must return promptly and must not retain the buffer (measurement mode only).
    var onPixelFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Capture drop reason (kCMSampleBufferAttachmentKey_DroppedFrameReason), on the camera queue.
    var onCaptureDrop: ((String) -> Void)?
    private let queue = DispatchQueue(label: "court.camera", qos: .userInitiated)
    let pipeline: CameraMediaPipeline
    private var configured = false
    private var running = false
    private var stopping = false
    private var begun = false
    private var fps = 60
    private var width = 1920
    private var height = 1080
    private var captureSequence: UInt64 = 0
    private var intrinsicDeliveryState: CaptureFrameMetadata.DeliveryState = .unsupported
    private var observers: [NSObjectProtocol] = []
    private var stopCompletions: [() -> Void] = []
    private(set) var device: AVCaptureDevice?
    /// Requested zoom in display units (0.5× ultra-wide, 1× main); applied (clamped) when capture is configured.
    private var zoomFactor = 1.0
    private var zoomRange: CameraZoomRange?
    /// (range of the active format, applied factor), on the camera queue. A nil range means no zoom.
    var onZoom: ((CameraZoomRange?, Double) -> Void)?

    override init() {
        pipeline = CameraMediaPipeline(queue: queue)
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    // Only an active capture can be interrupted; reporting one
                    // before Start shows an error the user never caused.
                    guard let self, self.running else { return }
                    self.stopOnQueue()
                    self.onError?(courtText("相机被系统中断，已停止采集，记录已暂停。回到 App 后点「开始采集」，再点「继续」。"))
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// `standalone` is kept for the measurement mode's call site; capture never needs a peer now.
    func start(rotationAngle: CGFloat = 0, standalone: Bool = true) {
        queue.async { [self] in
            guard !running, !stopping else { return }
            do {
                try configure()
                guard let output = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
                      let capture = output.connection(with: .video),
                      (rotationAngle == 0 || rotationAngle == 180),
                      capture.isVideoRotationAngleSupported(rotationAngle) else {
                    throw CourtError.message(courtText("摄像头不支持所选横向方向。请横放设备后重试。"))
                }
                // VideoDataOutput physically rotates buffers. Fix the chosen
                // horizon-level landscape direction before starting the session.
                capture.videoRotationAngle = rotationAngle
                // The delivery controls are iOS-only even though CoreMedia's attachment key
                // also exists on macOS. Preserve the current stabilization configuration.
                #if os(iOS)
                if capture.isCameraIntrinsicMatrixDeliverySupported {
                    capture.isCameraIntrinsicMatrixDeliveryEnabled = true
                    intrinsicDeliveryState = capture.isCameraIntrinsicMatrixDeliveryEnabled ? .enabled : .disabled
                } else {
                    intrinsicDeliveryState = .unsupported
                }
                #else
                intrinsicDeliveryState = .unsupported
                #endif
                captureSequence = 0
                begun = false
                running = true; session.startRunning()
                guard session.isRunning else { throw CourtError.message(courtText("相机未能开始采集。")) }
                onState?(courtFormat("横向采集 %1$@×%2$@ / %3$@ fps", "\(width)", "\(height)", "\(fps)"), true)
            } catch { onError?(error.localizedDescription); stopOnQueue() }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    /// Sets the zoom (display units) now when capturing, otherwise at the next start. Reports the applied factor.
    func setZoom(_ factor: Double) {
        queue.async { [self] in
            guard configured, let device, let zoomRange else { zoomFactor = factor; return }
            let value = zoomRange.clamp(factor)
            guard abs(value - zoomFactor) > 0.001 else { return }
            #if os(iOS)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(zoomRange.deviceFactor(value))
                device.unlockForConfiguration()
                zoomFactor = value
            } catch { onError?(courtFormat("无法调整镜头倍率：%1$@", "\(error.localizedDescription)")) }
            #endif
            onZoom?(zoomRange, zoomFactor)
        }
    }
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue { [self] in pipeline.stopRecording { continuation.resume() } }
            }
        }
    }

    private func configure() throws {
        guard !configured else { return }
        #if os(iOS)
        // The same lenses as the system camera: the triple camera (ultra-wide, main, telephoto) when
        // it has 1080p60, then the dual-wide camera, then the main camera alone (starting at 1×).
        let devices = [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            .compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }
        guard !devices.isEmpty else { throw CourtError.message(courtText("没有可用的后置主摄像头。")) }
        #else
        guard let only = AVCaptureDevice.default(for: .video) else { throw CourtError.message(courtText("没有可用的摄像头。")) }
        let devices = [only]
        #endif
        let (selectedWidth, selectedHeight, selectedFPS) = (1920, 1080, 60)
        var choice: (AVCaptureDevice, AVCaptureDevice.Format)?
        for candidate in devices {
            if let format = candidate.formats.first(where: {
                let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dimensions.width == selectedWidth && dimensions.height == selectedHeight &&
                    $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(selectedFPS) && $0.maxFrameRate >= Double(selectedFPS) }
            }) { choice = (candidate, format); break }
        }
        guard let (device, format) = choice else {
            throw CourtError.message(courtText("此摄像头不支持 1920×1080 / 60 fps，无法开始采集。"))
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        #if os(iOS)
        session.sessionPreset = .inputPriority
        #endif
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CourtError.message(courtText("无法配置视频采集。")) }
        session.addInput(input); session.addOutput(output)
        #if os(macOS)
        let preset: AVCaptureSession.Preset = .hd1920x1080
        guard session.canSetSessionPreset(preset) else {
            session.removeInput(input); session.removeOutput(output)
            throw CourtError.message(courtText("此摄像头无法输出所选分辨率。"))
        }
        session.sessionPreset = preset
        #endif
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(selectedFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(selectedFPS))
            #if os(iOS)
            // On a multi-lens camera the device's factor 1 is the ultra-wide (0.5×); the main lens and
            // the telephoto take over at the switch-over factors. Lenses change only when the zoom changes (never on
            // their own for focus or light), and zoom is locked while recording, so one recording
            // keeps one lens. Buffers stay 1920×1080 at every factor.
            let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
            let multiplier = device.isVirtualDevice ? 1 / (switchOvers.first ?? 1) : 1
            if device.isVirtualDevice {
                device.setPrimaryConstituentDeviceSwitchingBehavior(.restricted, restrictedSwitchingBehaviorConditions: .videoZoomChanged)
            }
            zoomRange = CameraZoomRange(formatMaximum: Double(format.videoMaxZoomFactor),
                                        displayMultiplier: multiplier, switchOvers: switchOvers)
            zoomFactor = zoomRange?.clamp(zoomFactor) ?? 1
            device.videoZoomFactor = CGFloat(zoomRange?.deviceFactor(zoomFactor) ?? 1)
            #else
            zoomRange = nil; zoomFactor = 1
            #endif
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
            }
            width = selectedWidth; height = selectedHeight; fps = selectedFPS
            self.device = device
            configured = true
            onZoom?(zoomRange, zoomFactor)
        } catch { session.removeInput(input); session.removeOutput(output); throw error }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Initialize from the actual delivered buffer, never assumed preset dimensions.
        let actualWidth = CVPixelBufferGetWidth(image), actualHeight = CVPixelBufferGetHeight(image)
        if !begun {
            guard actualWidth == 1920, actualHeight == 1080 else {
                onError?(courtText("相机没有输出 1920×1080 横向画面，采集已停止。请横放设备后重新开始。"))
                stopOnQueue(); return
            }
            width = actualWidth; height = actualHeight; begun = true
            pipeline.begin(width: width, height: height, fps: fps)
        }
        guard actualWidth == width, actualHeight == height else {
            onError?(courtText("相机输出尺寸在采集中改变，采集已停止。"))
            stopOnQueue(); return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        captureSequence &+= 1
        // Copy only small values from this sample. In particular, do not retain a capture
        // sample/pixel buffer or reuse another frame's intrinsics when its attachment is absent.
        let connectionObservation: CaptureFrameMetadata.ConnectionObservation
        let deviceObservation: CaptureFrameMetadata.DeviceObservation
        #if os(iOS)
        connectionObservation = .init(rotationDegrees: Double(connection.videoRotationAngle), mirrored: connection.isVideoMirrored,
                                      preferredStabilization: connection.preferredVideoStabilizationMode.rawValue,
                                      activeStabilization: connection.activeVideoStabilizationMode.rawValue)
        deviceObservation = .init(zoomFactor: device.map { Double($0.videoZoomFactor) },
                                  exposureDuration: device?.exposureDuration, iso: device.map { Double($0.iso) },
                                  lensPosition: device.map { Double($0.lensPosition) })
        #else
        connectionObservation = .init(rotationDegrees: Double(connection.videoRotationAngle), mirrored: connection.isVideoMirrored)
        deviceObservation = .init()
        #endif
        let metadata = CaptureFrameMetadata(captureSequence: captureSequence, sourcePTS: pts,
                                            deliveredWidth: actualWidth, deliveredHeight: actualHeight,
                                            intrinsic: .from(sampleBuffer: sampleBuffer), deliveryState: intrinsicDeliveryState,
                                            connection: connectionObservation, device: deviceObservation)
        pipeline.submit(image, pts: pts, captureMetadata: metadata)
        onPixelFrame?(image, pts.seconds)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        pipeline.noteCaptureDrop()
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        onCaptureDrop?(reason ?? "unknown")
    }

    /// Local recording outside any session (measurement mode).
    func startLocalRecording(directory: URL, prefix: String) {
        pipeline.startRecording(directory: directory, prefix: prefix, owner: nil)
    }
    /// Finishes the current local recording; completion runs after the file is closed.
    func finishLocalRecording(_ completion: @escaping @Sendable () -> Void) { pipeline.stopRecording(completion: completion) }
    /// Delivered frames, capture drops, encoded frames and frames appended to the open recording.
    func counters(_ completion: @escaping @Sendable (UInt64, UInt64, UInt64, Int) -> Void) {
        queue.async { [self] in
            let value = pipeline.currentCounters
            completion(value.delivered, value.captureDrops, value.encoded, value.recordedFrames)
        }
    }
    /// Exposure time (milliseconds) and ISO of the active camera (iOS); nil elsewhere or before a device is set.
    var exposure: (ms: Double, iso: Double)? {
        #if os(iOS)
        guard let device else { return nil }
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        return seconds.isFinite && seconds > 0 ? (seconds * 1000, Double(device.iso)) : nil
        #else
        return nil
        #endif
    }
    /// AVCaptureDevice.SystemPressureState level of the active camera (iOS), e.g. "nominal".
    var pressureLevel: String? {
        #if os(iOS)
        return device?.systemPressureState.level.rawValue
        #else
        return nil
        #endif
    }

    private func stopOnQueue(completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        guard !stopping else { return }
        stopping = true; running = false
        if session.isRunning { session.stopRunning() }
        // Frames already delivered are on this queue ahead of the barrier; the pipeline closes
        // the recording after them.
        queue.async { [self] in
            if begun { pipeline.end() }
            begun = false; stopping = false
            captureSequence = 0; intrinsicDeliveryState = .unsupported
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration(); configured = false
            onState?(courtText("采集已停止"), false)
            let completions = stopCompletions; stopCompletions.removeAll()
            completions.forEach { $0() }
        }
    }
}
