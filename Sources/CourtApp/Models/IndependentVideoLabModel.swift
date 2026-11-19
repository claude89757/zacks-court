import Foundation
import Observation
import AVFoundation
import CourtCore
import Darwin

struct IndependentVideoLabError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Immutable filesystem identity, compared before/after analysis and every image
/// request. The core additionally hashes the entire source before/after inference.
struct IndependentVideoLabFileIdentity: Equatable, Sendable {
    let device: Int64, inode: UInt64, size: Int64
    let modifiedSeconds: Int64, modifiedNanoseconds: Int64
    let changedSeconds: Int64, changedNanoseconds: Int64
}
struct IndependentVideoLabInspection: Sendable {
    let identity: IndependentVideoLabFileIdentity
    let trackID: CMPersistentTrackID
}
struct IndependentVideoLabImage: @unchecked Sendable {
    // CGImage is immutable. Only this copied image crosses to the UI actor;
    // the AVAssetImageGenerator never does.
    let image: CGImage
    let actualTime: CMTime
}
struct IndependentVideoLabRunMetadata: Encodable, Sendable {
    let runID: UUID
    let filename: String
    let startedAt: Date, completedAt: Date
    let requestedStartSeconds: Double, requestedDurationSeconds: Double
    let sourceSHA256: String, modelID: String, modelManifestSHA256: String, backendID: String
    let human = false, formal = false, production = false, physicalAccuracyValidated = false
}

/// Test injection is feature-local; the default runner accepts only bundled,
/// reviewed independent assets, never environment/private model directories.
struct IndependentVideoLabDependencies {
    var probe: @Sendable () async throws -> Void = {}
    var run: @Sendable (IndependentLocalVideoRequest, @escaping @Sendable (IndependentLocalVideoProgress) -> Void) async throws -> IndependentLocalVideoResult
    var inspect: @Sendable (URL) async throws -> IndependentVideoLabInspection
    var identity: @Sendable (URL) async throws -> IndependentVideoLabFileIdentity
    var image: @Sendable (URL, CMTime, CMPersistentTrackID) async throws -> IndependentVideoLabImage
    var persist: @Sendable (IndependentLocalVideoResult, IndependentVideoLabRunMetadata, URL) async throws -> URL
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void
    static var live: Self {
        .init(probe: { try await IndependentVideoLabServices.probe() },
              run: { try await IndependentVideoLabServices.run($0, progress: $1) },
              inspect: { try await IndependentVideoLabServices.inspect($0) },
              identity: { try await IndependentVideoLabServices.identity($0) },
              image: { try await IndependentVideoLabServices.image($0, time: $1, trackID: $2) },
              persist: { try await IndependentVideoLabServices.persist($0, metadata: $1, directory: $2) },
              startAccess: { $0.startAccessingSecurityScopedResource() }, stopAccess: { $0.stopAccessingSecurityScopedResource() })
    }
}

private final class IndependentVideoLabScope {
    private let url: URL, started: Bool
    private let stop: @Sendable (URL) -> Void
    init(url: URL, dependencies: IndependentVideoLabDependencies) {
        self.url = url; self.stop = dependencies.stopAccess; started = dependencies.startAccess(url)
    }
    deinit { if started { stop(url) } }
}

enum IndependentVideoLabServices {
    static func background<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try Task.checkCancellation(); return try await operation() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func probe(bundle: Bundle = .main) async throws {
        try await background {
            do { _ = try IndependentBallModelAssets.bundled(in: bundle) }
            catch is CancellationError { throw CancellationError() }
            catch { throw IndependentVideoLabError(message: courtText("当前安装包未包含可用的独立模型。")) }
        }
    }
    static func run(_ request: IndependentLocalVideoRequest,
                    progress: @escaping @Sendable (IndependentLocalVideoProgress) -> Void, bundle: Bundle = .main) async throws -> IndependentLocalVideoResult {
        try await background {
            let assets: IndependentBallModelAssets
            do { assets = try IndependentBallModelAssets.bundled(in: bundle) }
            catch is CancellationError { throw CancellationError() }
            catch { throw IndependentVideoLabError(message: courtText("当前安装包未包含可用的独立模型。")) }
            return try await IndependentLocalVideoAnalyzer.run(request: request, assets: assets, progress: progress)
        }
    }
    private static func fingerprint(_ url: URL) throws -> IndependentVideoLabFileIdentity {
        guard url.isFileURL else { throw IndependentVideoLabError(message: courtText("请选择本机视频。")) }
        var value = stat()
        let code = url.withUnsafeFileSystemRepresentation { pointer in pointer.map { lstat($0, &value) } ?? -1 }
        guard code == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw IndependentVideoLabError(message: courtText("无法访问原视频，请重新选择。")) }
        return .init(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
                     modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                     changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    static func identity(_ url: URL) async throws -> IndependentVideoLabFileIdentity {
        try await background { try fingerprint(url) }
    }
    static func inspect(_ url: URL) async throws -> IndependentVideoLabInspection {
        try await background {
            let before = try fingerprint(url)
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            guard tracks.count == 1, let track = tracks.first else { throw IndependentVideoLabError(message: courtText("暂只支持含一路画面的视频。")) }
            guard try fingerprint(url) == before else { throw sourceChanged() }
            return .init(identity: before, trackID: track.trackID)
        }
    }
    static func sourceChanged() -> IndependentVideoLabError { .init(message: courtText("原视频已变化，请重新选择并分析。")) }
    private final class ImageGenerator: @unchecked Sendable {
        // cancelAllCGImageGeneration is the generator's explicit cancellation API.
        let value: AVAssetImageGenerator
        init(_ asset: AVAsset) {
            value = AVAssetImageGenerator(asset: asset)
            value.appliesPreferredTrackTransform = false
            value.requestedTimeToleranceBefore = .zero; value.requestedTimeToleranceAfter = .zero
        }
    }
    static func image(_ url: URL, time: CMTime, trackID: CMPersistentTrackID) async throws -> IndependentVideoLabImage {
        try await background {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1, tracks.first?.trackID == trackID else {
                throw IndependentVideoLabError(message: courtText("画面轨道与分析不一致，请重新分析。"))
            }
            let generator = ImageGenerator(asset)
            let image = try await withTaskCancellationHandler(operation: { try await generator.value.image(at: time) },
                onCancel: { generator.value.cancelAllCGImageGeneration() })
            try Task.checkCancellation()
            return .init(image: image.image, actualTime: image.actualTime)
        }
    }
    static func persist(_ result: IndependentLocalVideoResult, metadata: IndependentVideoLabRunMetadata, directory: URL) async throws -> URL {
        try await background {
            guard !metadata.filename.isEmpty, !metadata.filename.contains("/") else { throw IndependentVideoLabError(message: courtText("报告文件名无效。")) }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let final = directory.appendingPathComponent(metadata.runID.uuidString, isDirectory: true)
            let stage = directory.appendingPathComponent(".run-"+UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stage) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
            for (name, data) in [("report.json", try encoder.encode(result)), ("run.json", try encoder.encode(metadata))] {
                try Task.checkCancellation()
                let file = stage.appendingPathComponent(name)
                try data.write(to: file, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try Task.checkCancellation()
            let code = stage.path.withCString { from in final.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
            guard code == 0 else { throw IndependentVideoLabError(message: courtText("报告未保存，目录可能已存在。可以重试。")) }
            return final
        }
    }
}

/// Independent experiment only. No CourtSession, ordinary history, scoring,
/// public speed, automatic event, or physical qualification is produced here.
@MainActor @Observable public final class IndependentVideoLabModel {
    public enum ModelAvailability: Equatable { case checking, available, unavailable(String) }
    public private(set) var modelAvailability: ModelAvailability = .checking
    public enum Phase: String { case idle, analyzing, saving, cancelling, completed, cancelled, failed }
    public var startSeconds = 0.0
    public var durationSeconds = 10.0
    public private(set) var filename: String?
    public private(set) var phase: Phase = .idle
    public private(set) var progressFraction = 0.0
    public private(set) var progressText = courtText("选择本机视频后开始。")
    public private(set) var error: String?
    public private(set) var saveError: String?
    public private(set) var savedDirectory: URL?
    public private(set) var result: IndependentLocalVideoResult?
    public private(set) var selectedFrameIndex = 0
    public private(set) var displayedImage: CGImage?
    public private(set) var overlayPoint: CGPoint?
    public private(set) var frameError: String?
    public private(set) var isLoadingFrame = false
    @ObservationIgnored private var selectedURL: URL?
    @ObservationIgnored private let dependencies: IndependentVideoLabDependencies
    @ObservationIgnored private let reportsDirectory: URL
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var previewTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var previewID = UUID()
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var originalIdentity: IndependentVideoLabFileIdentity?
    @ObservationIgnored private var runMetadata: IndependentVideoLabRunMetadata?
    public private(set) var isBusy = false
    public var canStart: Bool { modelAvailability == .available && filename != nil && !isBusy && !closed }
    public var speedText: String { "—" }
    public var speedReason: String { courtText("缺少触拍/触地事件与可信相机，暂不估算球速。") }
    public var selectedFrame: IndependentLocalVideoFrameResult? {
        guard let result, result.frames.indices.contains(selectedFrameIndex) else { return nil }
        return result.frames[selectedFrameIndex]
    }
    public init(reportsDirectory: URL? = nil) {
        self.reportsDirectory = reportsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zacks Court/IndependentRuns", isDirectory: true)
        dependencies = .live
    }
    init(reportsDirectory: URL, dependencies: IndependentVideoLabDependencies) {
        self.reportsDirectory = reportsDirectory; self.dependencies = dependencies
    }
    public func prepare() async {
        guard !closed else { return }
        if modelAvailability == .available { return }
        if let probeTask { await probeTask.value; return }
        modelAvailability = .checking
        let dependencies = self.dependencies
        let task = Task { [self] in
            defer { probeTask = nil }
            do {
                try await dependencies.probe(); try Task.checkCancellation()
                if !closed { modelAvailability = .available }
            } catch is CancellationError { }
            catch { if !closed { modelAvailability = .unavailable(Self.message(error)) } }
        }
        probeTask = task
        // The model owns this probe. A system picker may cancel its temporary
        // SwiftUI task waiter; only close() cancels the underlying byte check.
        await task.value
    }
    public func selectVideo(_ url: URL) {
        guard !isBusy, !closed else { return }
        cancelPreviews(); selectedURL = url; filename = url.lastPathComponent
        result = nil; runMetadata = nil; originalIdentity = nil; savedDirectory = nil
        error = nil; saveError = nil; phase = .idle; progressFraction = 0; progressText = courtText("已选视频，可以开始分析。")
    }
    public func clearError() { error = nil }
    public func reportImportFailure(_ message: String) { if !closed { error = message } }
    public func start() {
        guard canStart, let url = selectedURL else { return }
        guard startSeconds.isFinite, startSeconds >= 0, durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 120 else {
            error = courtText("起始位置须不小于0，时长须大于0且不超过120秒。"); return
        }
        let start = CMTime(seconds: startSeconds, preferredTimescale: 1_000_000_000)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000_000)
        guard start.isNumeric, duration.isNumeric else { error = courtText("起始位置或时长无效。"); return }
        cancelPreviews(); result = nil; savedDirectory = nil; runMetadata = nil; originalIdentity = nil
        error = nil; saveError = nil; cancelled = false; phase = .analyzing; progressFraction = 0; progressText = courtText("正在准备独立分析…")
        let id = UUID(); runID = id; isBusy = true
        let startedAt = Date(), requestedStart = startSeconds, requestedDuration = durationSeconds
        let dependencies = self.dependencies
        analysisTask = Task { [self] in
            let scope = IndependentVideoLabScope(url: url, dependencies: dependencies)
            defer {
                withExtendedLifetime(scope) {}
                analysisTask = nil; isBusy = false
            }
            do {
                let inspection = try await dependencies.inspect(url)
                try Task.checkCancellation()
                let request = IndependentLocalVideoRequest(videoURL: url, trackID: inspection.trackID, timeRange: .init(start: start, duration: duration))
                let output = try await dependencies.run(request) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.runID == id, !self.cancelled, !self.closed, self.phase == .analyzing else { return }
                        self.progressFraction = progress.fraction
                        switch progress.phase {
                        case "verifying_source": self.progressText = courtText("正在核对视频…")
                        case "loading_independent_model": self.progressText = courtText("正在载入独立模型…")
                        default: self.progressText = courtFormat("已读取%1$@帧 · 已分析%2$@帧", "\(progress.decodedFrames)", "\(progress.inferredFrames)")
                        }
                    }
                }
                try Task.checkCancellation()
                guard try await dependencies.identity(url) == inspection.identity else { throw IndependentVideoLabServices.sourceChanged() }
                guard output.metadata.trackID == inspection.trackID else { throw IndependentVideoLabServices.sourceChanged() }
                guard runID == id, !closed, !cancelled else { throw CancellationError() }
                result = output; originalIdentity = inspection.identity; selectedFrameIndex = 0
                let metadata = IndependentVideoLabRunMetadata(runID: id, filename: url.lastPathComponent, startedAt: startedAt, completedAt: Date(),
                    requestedStartSeconds: requestedStart, requestedDurationSeconds: requestedDuration, sourceSHA256: output.sourceSHA256,
                    modelID: output.modelID, modelManifestSHA256: output.modelManifestSHA256, backendID: output.backendID)
                runMetadata = metadata; phase = .saving; progressText = courtText("分析完成，正在保存报告…")
                do {
                    let saved = try await dependencies.persist(output, metadata, reportsDirectory)
                    recordCommittedDirectory(saved, run: id)
                    try Task.checkCancellation()
                    guard runID == id, !closed, !cancelled else { throw CancellationError() }
                } catch is CancellationError { throw CancellationError() }
                catch { saveError = courtText("报告未保存，结果仍在本页。可以重试。") }
                guard !closed, !cancelled else { throw CancellationError() }
                phase = .completed; progressFraction = 1; progressText = courtText("分析完成。")
                selectFrame(index: 0)
            } catch is CancellationError {
                if !closed, runID == id {
                    phase = result == nil ? .cancelled : .completed
                    progressText = savedDirectory == nil ? courtText("已取消。") : courtText("分析完成，报告已保存。")
                    if result != nil, savedDirectory == nil { saveError = courtText("报告未保存，可以重试。") }
                }
            } catch {
                if !closed, runID == id { self.error = Self.message(error); phase = .failed; progressText = courtText("分析未完成。") }
            }
        }
    }
    public func cancel() {
        guard isBusy else { return }
        cancelled = true; phase = .cancelling; progressText = courtText("正在取消，请稍候…")
        analysisTask?.cancel(); saveTask?.cancel()
    }
    public func close() {
        closed = true; cancelled = true; probeTask?.cancel(); analysisTask?.cancel(); saveTask?.cancel(); cancelPreviews(); selectedURL = nil
    }
    /// Useful to owners/tests that explicitly await shutdown. Each operation
    /// retains its own scope until its worker has actually returned.
    public func waitUntilIdle() async {
        if let task = probeTask { await task.value }
        if let task = analysisTask { await task.value }
        if let task = saveTask { await task.value }
        for task in Array(previewTasks.values) { await task.value }
    }
    public func retrySave() {
        guard !isBusy, !closed, savedDirectory == nil, let result, let metadata = runMetadata else { return }
        cancelled = false; phase = .saving; saveError = nil; isBusy = true
        let id = runID, dependencies = self.dependencies, directory = reportsDirectory
        saveTask = Task { [self] in
            defer { saveTask = nil; isBusy = false }
            do {
                let saved = try await dependencies.persist(result, metadata, directory)
                recordCommittedDirectory(saved, run: id)
                try Task.checkCancellation()
                guard runID == id, !closed, !cancelled else { throw CancellationError() }
                phase = .completed
            } catch {
                if !closed, runID == id {
                    if savedDirectory == nil { saveError = courtText("报告未保存，结果仍在本页。可以重试。") }
                    else { saveError = nil; progressText = courtText("分析完成，报告已保存。") }
                    phase = .completed
                }
            }
        }
    }
    private func recordCommittedDirectory(_ directory: URL, run: UUID) {
        // A successful exclusive rename is the commit point. Cancellation can
        // race its return to MainActor; never turn a committed report into a
        // false "not saved" state or suggest an impossible same-ID overwrite.
        if runID == run, !closed { savedDirectory = directory; saveError = nil }
    }
    private func cancelPreviews() {
        previewID = UUID(); for task in previewTasks.values { task.cancel() }
        displayedImage = nil; overlayPoint = nil; frameError = nil; isLoadingFrame = false
    }
    static func sourceTime(_ frame: IndependentLocalVideoFrameResult) throws -> CMTime {
        let t = frame.time
        guard t.timeBaseNumerator > 0, t.timeBaseDenominator > 0 else { throw IndependentVideoLabError(message: courtText("原始帧时间无效。")) }
        let rational = CMTimeMultiply(CMTime(value: t.sourcePTS, timescale: t.timeBaseDenominator), multiplier: t.timeBaseNumerator)
        let raw = frame.presentationTime.mediaTime
        guard rational.isNumeric, !rational.flags.contains(.hasBeenRounded), raw.isNumeric, raw.epoch == 0, CMTimeCompare(rational,raw) == 0 else {
            throw IndependentVideoLabError(message: courtText("原始帧时间不一致，无法精确显示。"))
        }
        return raw
    }
    public func selectFrame(index: Int) {
        guard !closed, let result, result.frames.indices.contains(index), let url = selectedURL, let identity = originalIdentity else { return }
        cancelPreviews(); selectedFrameIndex = index
        let id = previewID, sourceRun = runID, frame = result.frames[index], dependencies = self.dependencies
        isLoadingFrame = true
        previewTasks[id] = Task { [self] in
            let scope = IndependentVideoLabScope(url: url, dependencies: dependencies)
            defer {
                withExtendedLifetime(scope) {}; previewTasks[id] = nil
                if previewID == id { isLoadingFrame = false }
            }
            do {
                try Task.checkCancellation()
                let time = try Self.sourceTime(frame)
                guard try await dependencies.identity(url) == identity else { throw IndependentVideoLabServices.sourceChanged() }
                let sample = try await dependencies.image(url, time, result.metadata.trackID)
                try Task.checkCancellation()
                guard try await dependencies.identity(url) == identity else { throw IndependentVideoLabServices.sourceChanged() }
                guard sample.actualTime.isNumeric, CMTimeCompare(sample.actualTime,time) == 0,
                      sample.image.width == result.metadata.naturalWidth, sample.image.height == result.metadata.naturalHeight,
                      frame.transform.originalWidth == sample.image.width, frame.transform.originalHeight == sample.image.height else {
                    throw IndependentVideoLabError(message: courtText("无法精确取出原始这一帧，暂不显示画面或球点。"))
                }
                guard previewID == id, runID == sourceRun, !closed else { return }
                displayedImage = sample.image
                if let candidate = frame.candidate, candidate.originalXY.count == 2,
                   (0..<sample.image.width).contains(candidate.originalXY[0]), (0..<sample.image.height).contains(candidate.originalXY[1]) {
                    overlayPoint = CGPoint(x: CGFloat(candidate.originalXY[0]), y: CGFloat(candidate.originalXY[1]))
                }
            } catch is CancellationError { }
            catch { if previewID == id, runID == sourceRun, !closed { frameError = Self.message(error); displayedImage = nil; overlayPoint = nil } }
        }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? IndependentVideoLabError { return error.message }
        if let error = error as? IndependentLocalVideoError {
            if case .invalid(let reason) = error, reason.contains("requires nominal 60 fps") {
                return courtText("当前实验需要60fps视频，请重新选择。")
            }
            return courtText("视频未能完成独立分析，请检查格式和所选时间段后重试。")
        }
        if let error = error as? IndependentVideoReaderError {
            switch error {
            case .unsupportedTransform: return courtText("暂不支持带旋转信息的视频。")
            case .invalidTimeRange: return courtText("所选时间段超出视频范围，请调整起始位置或时长。")
            default: return courtText("视频未能完成读取，请检查文件后重试。")
            }
        }
        return courtText("视频未能完成独立分析，请检查格式和所选时间段后重试。")
    }
}
