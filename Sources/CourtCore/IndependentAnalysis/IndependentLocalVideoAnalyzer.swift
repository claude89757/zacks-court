import Foundation
import AVFoundation

public enum IndependentLocalVideoError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// The App keeps its short interactive limit. Offline whole-video evaluation
/// opts in explicitly and uses the same continuous decoder/model/tracker state.
public enum IndependentLocalVideoLimitMode: Sendable, Equatable {
    case interactive
    case offlineFullVideo
    var maximumFrames: Int { self == .interactive ? 7300 : 216_000 }
    var maximumDurationSeconds: Double { self == .interactive ? 120 : 3600 }
}

public struct IndependentLocalVideoRequest: Sendable {
    public let videoURL: URL
    public let expectedSourceSHA256: String?
    public let trackID: CMPersistentTrackID?
    public let timeRange: CMTimeRange?
    public let roi: IndependentBallROI?
    /// A nominal metadata constraint, never proof of physical capture cadence.
    public let requireNominal60FPS: Bool
    public let expectedNominalFPS: Double?
    public let maximumFrames: Int
    public let maximumDurationSeconds: Double
    public let limitMode: IndependentLocalVideoLimitMode
    public init(videoURL: URL, expectedSourceSHA256: String? = nil, trackID: CMPersistentTrackID? = nil,
                timeRange: CMTimeRange? = nil, roi: IndependentBallROI? = nil,
                requireNominal60FPS: Bool = true, expectedNominalFPS: Double? = nil,
                maximumFrames: Int = 7300, maximumDurationSeconds: Double = 120,
                limitMode: IndependentLocalVideoLimitMode = .interactive) {
        self.videoURL = videoURL; self.expectedSourceSHA256 = expectedSourceSHA256; self.trackID = trackID
        self.timeRange = timeRange; self.roi = roi; self.requireNominal60FPS = requireNominal60FPS
        self.expectedNominalFPS = expectedNominalFPS; self.maximumFrames = maximumFrames
        self.maximumDurationSeconds = maximumDurationSeconds
        self.limitMode = limitMode
    }
}

public struct IndependentLocalVideoTime: Codable, Sendable, Equatable {
    public let value: Int64
    public let timescale: Int32
    public let epoch: Int64
    public let flags: UInt32
    public init(_ time: CMTime) { value = time.value; timescale = time.timescale; epoch = time.epoch; flags = time.flags.rawValue }
    public var mediaTime: CMTime { CMTime(value: value, timescale: timescale, flags: CMTimeFlags(rawValue: flags), epoch: epoch) }
}

public enum IndependentLocalVideoFrameState: String, Codable, Sendable {
    case warmup, pendingWindow, tracked, missing, incompleteWindow
}

private enum LocalQualificationKey: String, CodingKey {
    case acceptedCamera, velocity, speedKilometersPerHour, physicalAccuracyValidated, cameraQualified, human, formal, production, nativeEndToEndSpeedAccepted, twentyPercentAcceptanceEligible
    static func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Self.self)
        for key in [Self.acceptedCamera, .velocity, .speedKilometersPerHour] { try c.encodeNil(forKey: key) }
        for key in [Self.physicalAccuracyValidated, .cameraQualified, .human, .formal, .production, .nativeEndToEndSpeedAccepted, .twentyPercentAcceptanceEligible] { try c.encode(false, forKey: key) }
    }
}

/// One actual source frame, including warmup and unfinished groups. A missing
/// selection remains nil; warmup/tail frames are not silently removed.
public struct IndependentLocalVideoFrameResult: Encodable, Sendable {
    public let decodeIndex: Int
    public let time: IndependentBallFrameTime
    public let presentationTime: IndependentLocalVideoTime
    public let duration: IndependentLocalVideoTime
    public let decodeTime: IndependentLocalVideoTime
    public let transform: IndependentBallImageTransform
    public let segmentIndex: UInt64
    public internal(set) var windowIndex: UInt64?
    public internal(set) var state: IndependentLocalVideoFrameState
    public internal(set) var unavailableReason: String?
    public internal(set) var availableAt: IndependentLocalVideoTime?
    public internal(set) var sourceLookaheadSeconds: Double?
    public internal(set) var selection: IndependentBallTrackSelection?
    public internal(set) var candidateBank: IndependentBallCandidateBank?
    public var candidate: IndependentBallGridCandidate? { selection?.candidate }
    public var speedKilometersPerHour: Double? { nil }
    public var physicalAccuracyValidated: Bool { false }
    public var cameraQualified: Bool { false }
    public var human: Bool { false }
    public var formal: Bool { false }
    public var production: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    private enum Key: String, CodingKey {
        case decodeIndex, time, presentationTime, duration, decodeTime, transform, segmentIndex, windowIndex, state, unavailableReason, availableAt, sourceLookaheadSeconds, selection, candidateBank, candidate, speedUnavailableReason
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(decodeIndex, forKey: .decodeIndex); try c.encode(time, forKey: .time)
        try c.encode(presentationTime, forKey: .presentationTime); try c.encode(duration, forKey: .duration); try c.encode(decodeTime, forKey: .decodeTime)
        try c.encode(transform, forKey: .transform); try c.encode(segmentIndex, forKey: .segmentIndex); try c.encode(windowIndex, forKey: .windowIndex)
        try c.encode(state, forKey: .state); try c.encode(unavailableReason, forKey: .unavailableReason); try c.encode(availableAt, forKey: .availableAt)
        try c.encode(sourceLookaheadSeconds, forKey: .sourceLookaheadSeconds); try c.encode(selection, forKey: .selection)
        try c.encode(candidateBank, forKey: .candidateBank); try c.encode(candidate, forKey: .candidate)
        try c.encode("No independent event, qualified camera or physical speed evidence", forKey: .speedUnavailableReason)
        try LocalQualificationKey.encode(to: encoder)
    }
}

public struct IndependentLocalVideoWindowResult: Encodable, Sendable {
    public let windowIndex: UInt64, segmentIndex: UInt64
    public let decodeIndices: [Int]
    public let backgroundTimes: [IndependentBallFrameTime]
    public let backgroundStrategy: String
    public let transform: IndependentBallImageTransform
    public let availableAt: IndependentLocalVideoTime
    public let lookaheadFrames: Int
    public let backgroundSHA256: String, tensorSHA256: String, heatmapsSHA256: String
    public let inferenceSeconds: Double
}

public struct IndependentLocalVideoProgress: Sendable {
    public let phase: String
    public let decodedFrames: Int
    public let inferredFrames: Int
    public let fraction: Double
}

/// Optional synchronous diagnostics on the analysis queue. Consume/write and
/// return promptly; retaining RGB/tensors in a callback defeats caller memory bounds.
public struct IndependentLocalVideoObservers: Sendable {
    public let onDecoded: (@Sendable (Int, IndependentVideoFrame) throws -> Void)?
    public let onWindow: (@Sendable (IndependentLocalVideoWindowResult, IndependentBallPreparedWindow, [Float], [Float]) throws -> Void)?
    public init(onDecoded: (@Sendable (Int, IndependentVideoFrame) throws -> Void)? = nil,
                onWindow: (@Sendable (IndependentLocalVideoWindowResult, IndependentBallPreparedWindow, [Float], [Float]) throws -> Void)? = nil) {
        self.onDecoded = onDecoded; self.onWindow = onWindow
    }
}

public struct IndependentLocalVideoResult: Encodable, Sendable {
    public static let backendIdentifier = "independent-tracknetv3-base-prefix48-causal-v1"
    public let sourceSHA256: String
    public let modelID: String
    public let modelManifestSHA256: String
    public let metadata: IndependentVideoMetadata
    public let frames: [IndependentLocalVideoFrameResult]
    public let windows: [IndependentLocalVideoWindowResult]
    public let decodedSampleCount: Int
    public let discardedPrerollSampleCount: Int
    public let assemblerPeakRetainedRGBBytes: Int
    public let unflushedTailFrames: Int
    public let inferenceSeconds: Double
    public let wallSecondsExcludingSourceHashAndModelLoad: Double
    public var backendID: String { Self.backendIdentifier }
    public var inferredFrames: Int { windows.count*8 }
    public var speedKilometersPerHour: Double? { nil }
    public var physicalAccuracyValidated: Bool { false }
    public var cameraQualified: Bool { false }
    public var human: Bool { false }
    public var formal: Bool { false }
    public var production: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    public var limitations: [String] {
        ["Experimental local-video ball candidates only; no hit/bounce event or qualified 3D speed estimator.",
         "Nominal track FPS is metadata, not measured physical capture cadence.",
         "AVFoundation RGB decode/color equivalence to FFmpeg/Pillow is unverified; nonidentity orientation is rejected.",
         "Prefix48 resize-before-median is distinct from the model catalog's historical offline background.",
         "Eight-frame inference waits for up to seven source frames; warmup and incomplete tails have no predictions.",
         "CPU-only offline work is not iPhone performance, accuracy, camera integration or production acceptance."]
    }
    private enum Key: String, CodingKey {
        case backendID, sourceSHA256, modelID, modelManifestSHA256, frames, windows, decodedSampleCount, discardedPrerollSampleCount, assemblerPeakRetainedRGBBytes, unflushedTailFrames, inferenceSeconds, wallSecondsExcludingSourceHashAndModelLoad, inferredFrames, limitations, trackID, width, height, nominalFPS, requestedStart, requestedDuration
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(backendID, forKey: .backendID); try c.encode(sourceSHA256, forKey: .sourceSHA256)
        try c.encode(modelID, forKey: .modelID); try c.encode(modelManifestSHA256, forKey: .modelManifestSHA256)
        try c.encode(frames, forKey: .frames); try c.encode(windows, forKey: .windows)
        try c.encode(decodedSampleCount, forKey: .decodedSampleCount); try c.encode(discardedPrerollSampleCount, forKey: .discardedPrerollSampleCount)
        try c.encode(assemblerPeakRetainedRGBBytes, forKey: .assemblerPeakRetainedRGBBytes); try c.encode(unflushedTailFrames, forKey: .unflushedTailFrames)
        try c.encode(inferenceSeconds, forKey: .inferenceSeconds); try c.encode(wallSecondsExcludingSourceHashAndModelLoad, forKey: .wallSecondsExcludingSourceHashAndModelLoad)
        try c.encode(inferredFrames, forKey: .inferredFrames); try c.encode(limitations, forKey: .limitations)
        try c.encode(metadata.trackID, forKey: .trackID); try c.encode(metadata.naturalWidth, forKey: .width); try c.encode(metadata.naturalHeight, forKey: .height); try c.encode(metadata.nominalFPS, forKey: .nominalFPS)
        try c.encode(IndependentLocalVideoTime(metadata.requestedTimeRange.start), forKey: .requestedStart); try c.encode(IndependentLocalVideoTime(metadata.requestedTimeRange.duration), forKey: .requestedDuration)
        try LocalQualificationKey.encode(to: encoder)
    }
}

final class IndependentLocalVideoCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

public enum IndependentLocalVideoAnalyzer {
    // Every Core ML object, window/tracker operation and post-open reader
    // next/cancel is confined here; no Core ML object crosses Tasks.
    private final class ReaderTransfer: @unchecked Sendable {
        // One-way ownership transfer after async open. Never read on the sender
        // after construction, and consumed only by the single queued operation.
        let reader: IndependentVideoReader
        init(_ reader: IndependentVideoReader) { self.reader = reader }
    }
    private static let queue = DispatchQueue(label: "court.independent-local-video", qos: .utility)
    public static func run(request: IndependentLocalVideoRequest, assets: IndependentBallModelAssets,
                           observers: IndependentLocalVideoObservers = .init(),
                           progress: (@Sendable (IndependentLocalVideoProgress) -> Void)? = nil) async throws -> IndependentLocalVideoResult {
        try Task.checkCancellation()
        let cancellation = IndependentLocalVideoCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation(); try cancellation.check()
            try validate(request)
            progress?(.init(phase: "verifying_source", decodedFrames: 0, inferredFrames: 0, fraction: 0))
            let source = try IndependentBallModelAssets.shaFile(request.videoURL, checkCancellation: cancellation.check)
            if let expected = request.expectedSourceSHA256 { try require(source == expected, "Source video digest differs from request") }
            let checked = try IndependentBallModelAssets.verify(directory: assets.directory, expectedManifestSHA256: IndependentBallModelAssets.reviewedManifestSHA256, checkCancellation: cancellation.check)
            try require(checked.manifestSHA256 == assets.manifestSHA256, "Independent model asset identity changed")
            let reader = try await IndependentVideoReader.open(video: request.videoURL, trackID: request.trackID,
                timeRange: request.timeRange, limits: .init(maximumDecodedFrames: 1_000_000))
            // No model has been created yet. It is initialized, predicted and
            // released entirely inside the serial queue below, after metadata checks.
            let transfer = ReaderTransfer(reader)
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try process(reader: transfer.reader, request: request, assets: checked, source: source, cancellation: cancellation, observers: observers, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { cancellation.cancel(); task.cancel() })
    }
    static func validate(_ request: IndependentLocalVideoRequest) throws {
        try require(request.videoURL.isFileURL, "Local video analysis does not accept network URLs")
        let attributes = try FileManager.default.attributesOfItem(atPath: request.videoURL.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular, "Local video must be an ordinary file")
        try require((1...request.limitMode.maximumFrames).contains(request.maximumFrames)
                    && request.maximumDurationSeconds.isFinite && request.maximumDurationSeconds > 0
                    && request.maximumDurationSeconds <= request.limitMode.maximumDurationSeconds,
                    "Video request exceeds selected interactive/offline limits")
        if let expected = request.expectedSourceSHA256 { try require(IndependentBallModelAssets.validSHA(expected), "Invalid expected source SHA256") }
        if let fps = request.expectedNominalFPS { try require(fps.isFinite && (1...240).contains(fps), "Invalid expected nominal FPS") }
    }
    private static func process(reader: IndependentVideoReader, request: IndependentLocalVideoRequest,
                                assets: IndependentBallModelAssets, source: String,
                                cancellation: IndependentLocalVideoCancellation, observers: IndependentLocalVideoObservers,
                                progress: (@Sendable (IndependentLocalVideoProgress) -> Void)?) throws -> IndependentLocalVideoResult {
        defer { reader.cancel() }
        try cancellation.check()
        let metadata = reader.metadata, fps = metadata.nominalFPS
        try require(fps.isFinite && (1...240).contains(fps), "Unsupported source nominal track rate")
        try require(!request.requireNominal60FPS || abs(fps-60) < 0.01, "Independent experimental mode requires nominal 60 fps track metadata")
        if let expected = request.expectedNominalFPS { try require(abs(fps-expected) < 0.01, "Native track nominal rate differs from request") }
        try require(metadata.requestedTimeRange.duration.seconds.isFinite && metadata.requestedTimeRange.duration.seconds <= request.maximumDurationSeconds, "Requested source interval exceeds experimental duration limit")
        progress?(.init(phase: "loading_independent_model", decodedFrames: 0, inferredFrames: 0, fraction: 0))
        let model = try autoreleasepool { try IndependentBallModel(modelURL: assets.modelURL) }
        let accumulator = try IndependentLocalVideoAccumulator(source: source, nominalFPS: request.expectedNominalFPS ?? fps, roi: request.roi, maximumFrames: request.maximumFrames,
            predict: { try model.predict(nchw: $0).heatmaps }, observers: observers, checkCancellation: cancellation.check)
        let began = ProcessInfo.processInfo.systemUptime
        var lastProgress = began
        while try autoreleasepool(invoking: { () throws -> Bool in
            try cancellation.check()
            guard let frame = try reader.next(checkCancellation: cancellation.check) else { return false }
            try accumulator.append(frame)
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastProgress >= 0.25 {
                let fraction = CMTimeSubtract(frame.presentationTime, metadata.requestedTimeRange.start).seconds/metadata.requestedTimeRange.duration.seconds
                progress?(.init(phase: "decoding", decodedFrames: accumulator.frames.count, inferredFrames: accumulator.windows.count*8, fraction: min(1,max(0,fraction))))
                lastProgress = now
            }
            return true
        }) { }
        try accumulator.finish()
        let wall = ProcessInfo.processInfo.systemUptime-began
        try cancellation.check()
        let after = try IndependentBallModelAssets.verify(directory: assets.directory, expectedManifestSHA256: assets.manifestSHA256, checkCancellation: cancellation.check)
        try require(after.manifestSHA256 == assets.manifestSHA256, "Independent model changed during analysis")
        try require(try IndependentBallModelAssets.shaFile(request.videoURL, checkCancellation: cancellation.check) == source, "Source video changed during analysis")
        progress?(.init(phase: "completed", decodedFrames: accumulator.frames.count, inferredFrames: accumulator.windows.count*8, fraction: 1))
        return .init(sourceSHA256: source, modelID: assets.modelID, modelManifestSHA256: assets.manifestSHA256, metadata: metadata,
            frames: accumulator.frames, windows: accumulator.windows, decodedSampleCount: reader.decodedSampleCount, discardedPrerollSampleCount: reader.discardedPrerollSampleCount,
            assemblerPeakRetainedRGBBytes: accumulator.peakRetainedBytes, unflushedTailFrames: accumulator.assembler.state.pendingFrameCount,
            inferenceSeconds: accumulator.windows.reduce(0) { $0+$1.inferenceSeconds }, wallSecondsExcludingSourceHashAndModelLoad: wall)
    }
    private static func require(_ value: Bool, _ reason: String) throws { if !value { throw IndependentLocalVideoError.invalid(reason) } }
}

/// Shared state machine used by production orchestration and controlled tests.
/// Its injectable predictor is internal; public callers can only use verified assets.
final class IndependentLocalVideoAccumulator {
    let assembler: IndependentBallWindowAssembler
    private let tracker: IndependentCausalBallTracker
    private let source: String, roi: IndependentBallROI?, maximumFrames: Int
    private let predict: ([Float]) throws -> [Float]
    private let observers: IndependentLocalVideoObservers
    private let checkCancellation: () throws -> Void
    private var pending: [Int] = []
    private var ended = false
    private(set) var frames: [IndependentLocalVideoFrameResult] = []
    private(set) var windows: [IndependentLocalVideoWindowResult] = []
    private(set) var peakRetainedBytes = 0
    init(source: String, nominalFPS: Double, roi: IndependentBallROI?, maximumFrames: Int,
         predict: @escaping ([Float]) throws -> [Float], observers: IndependentLocalVideoObservers = .init(),
         checkCancellation: @escaping () throws -> Void = {}) throws {
        self.source = source; self.roi = roi; self.maximumFrames = maximumFrames; self.predict = predict; self.observers = observers
        self.checkCancellation = checkCancellation
        assembler = try .init(nominalFramesPerSecond: nominalFPS); tracker = try .init(nominalFramesPerSecond: nominalFPS)
    }
    func append(_ frame: IndependentVideoFrame) throws {
        try checkCancellation()
        guard !ended, frames.count < maximumFrames else { throw IndependentLocalVideoError.invalid("Video frame limit exceeded or run already finished") }
        let index = frames.count, oldState = assembler.state, oldSegment = assembler.state.segmentIndex
        try observers.onDecoded?(index, frame)
        let time = try IndependentBallFrameTime(sourcePTS: frame.presentationTime.value, timeBaseDenominator: frame.presentationTime.timescale)
        let transform = try IndependentBallImageTransform(originalWidth: frame.rgb.width, originalHeight: frame.rgb.height, cropX: roi?.x ?? 0, cropY: roi?.y ?? 0, cropWidth: roi?.width, cropHeight: roi?.height)
        let prepared = try assembler.append(image: frame.rgb, time: time, sourceID: source, roi: roi)
        let state = assembler.state
        peakRetainedBytes = max(peakRetainedBytes, state.retainedImageBytes)
        if oldSegment != state.segmentIndex {
            let reason = state.lastResetReason ?? "segment_reset"
            abandonPending(reason: "incomplete_window_discarded_" + reason); tracker.reset()
            if !oldState.backgroundReady {
                for i in frames.indices where frames[i].segmentIndex == oldSegment && frames[i].state == .warmup {
                    frames[i].unavailableReason = "incomplete_background_discarded_" + reason
                }
            }
        }
        let warming = prepared == nil && state.pendingFrameCount == 0
        frames.append(.init(decodeIndex: index, time: time, presentationTime: .init(frame.presentationTime), duration: .init(frame.duration), decodeTime: .init(frame.decodeTime), transform: transform,
            segmentIndex: state.segmentIndex, windowIndex: nil, state: warming ? .warmup : .pendingWindow,
            unavailableReason: warming ? "background_warmup_\(state.warmupFrameCount)_of_48" : "awaiting_complete_eight_frame_window", availableAt: nil, sourceLookaheadSeconds: nil, selection: nil, candidateBank: nil))
        guard let prepared else { if !warming { pending.append(index) }; return }
        pending.append(index)
        guard pending.count == 8 else { throw IndependentLocalVideoError.invalid("Window/source frame identity mismatch") }
        try checkCancellation()
        let tensor = try IndependentBallPreprocessor.makeTensor(background: prepared.background, frames: prepared.frames)
        let start = ProcessInfo.processInfo.systemUptime
        let heatmaps = try predict(tensor), inference = ProcessInfo.processInfo.systemUptime-start
        try checkCancellation()
        guard heatmaps.count == IndependentBallModel.outputCount else { throw IndependentLocalVideoError.invalid("Predictor heatmap dimensions differ") }
        func floatSHA(_ values: [Float]) -> String { values.withUnsafeBufferPointer { IndependentBallModelAssets.sha(Data(buffer: $0)) } }
        let window = IndependentLocalVideoWindowResult(windowIndex: prepared.windowIndex, segmentIndex: prepared.segmentIndex, decodeIndices: pending,
            backgroundTimes: prepared.backgroundTimes, backgroundStrategy: prepared.backgroundStrategy, transform: prepared.transform,
            availableAt: .init(frame.presentationTime), lookaheadFrames: prepared.lookaheadFrames,
            backgroundSHA256: IndependentBallModelAssets.sha(Data(prepared.background.bytes)), tensorSHA256: floatSHA(tensor), heatmapsSHA256: floatSHA(heatmaps), inferenceSeconds: inference)
        try observers.onWindow?(window, prepared, tensor, heatmaps)
        for offset in 0..<8 {
            try checkCancellation()
            let bank = try IndependentBallCandidateBank.extract(Array(heatmaps[offset*512*288..<(offset+1)*512*288]), transform: prepared.transform)
            let choice = try tracker.select(candidates: bank.candidates, time: prepared.times[offset], sourceID: source, transform: prepared.transform)
            let row = pending[offset]
            guard frames[row].time == prepared.times[offset] else { throw IndependentLocalVideoError.invalid("Prepared PTS do not match actual decoded frame") }
            frames[row].windowIndex = prepared.windowIndex; frames[row].availableAt = .init(frame.presentationTime)
            frames[row].sourceLookaheadSeconds = CMTimeSubtract(frame.presentationTime, frames[row].presentationTime.mediaTime).seconds
            frames[row].selection = choice; frames[row].candidateBank = bank
            frames[row].state = choice.candidate == nil ? .missing : .tracked
            frames[row].unavailableReason = choice.missingReason
        }
        windows.append(window); pending.removeAll(keepingCapacity: true)
    }
    func finish() throws {
        try checkCancellation()
        guard !ended else { return }; ended = true
        abandonPending(reason: "incomplete_eight_frame_tail")
        if !assembler.state.backgroundReady {
            for i in frames.indices where frames[i].segmentIndex == assembler.state.segmentIndex && frames[i].state == .warmup {
                frames[i].unavailableReason = "insufficient_48_frame_background"
            }
        }
    }
    private func abandonPending(reason: String) {
        for i in pending { frames[i].state = .incompleteWindow; frames[i].unavailableReason = reason }
        pending.removeAll(keepingCapacity: true)
    }
}
