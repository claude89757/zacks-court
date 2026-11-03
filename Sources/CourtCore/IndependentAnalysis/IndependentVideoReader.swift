import Foundation
import AVFoundation

public enum IndependentVideoReaderError: Error, Equatable {
    case localFileRequired, fileUnavailable, noVideoTrack, trackNotFound
    case unsupportedTransform, unsupportedDimensions, invalidTimeRange
    case readerSetupFailed(String), decodingFailed(String), cancelled
    case invalidPresentationTime, nonMonotonicPresentationTime
    case unsupportedPixelFormat, invalidPixelBufferLayout, resourceLimit
}

/// Reported tags, not a claim about the decoder's color conversion. Missing
/// source tags stay nil; decoded RGB storage does not establish a source range.
public struct IndependentVideoColorMetadata: Sendable, Equatable {
    public let primaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let fullRangeVideo: Bool?
}

public struct IndependentVideoFormatMetadata: Sendable, Equatable {
    public let mediaSubType: UInt32
    public let width: Int
    public let height: Int
    public let color: IndependentVideoColorMetadata
}

public struct IndependentVideoTransform: Sendable, Equatable {
    public let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    fileprivate init(_ transform: CGAffineTransform) {
        a = transform.a; b = transform.b; c = transform.c
        d = transform.d; tx = transform.tx; ty = transform.ty
    }
}

public struct IndependentVideoMetadata: Sendable {
    public let trackID: CMPersistentTrackID
    public let naturalWidth: Int
    public let naturalHeight: Int
    /// Informational only. Frame times are never derived from this value.
    public let nominalFPS: Double
    public let preferredTransform: IndependentVideoTransform
    public let trackTimeRange: CMTimeRange
    /// Half-open PTS interval [start, end). Preroll is never returned as input.
    public let requestedTimeRange: CMTimeRange
    public let sourceFormats: [IndependentVideoFormatMetadata]
    public let rangeDecodingStrategy = "Sequential decode from the track beginning, then exact half-open PTS filtering. No seek-start timestamp clipping; memory does not grow with preroll length."
    public let decodingBoundary = "AVFoundation decodes to 32BGRA; explicit byte reordering produces encoded RGB8. No rotation, resizing, linearization or additional color management is applied by IndependentVideoReader. Decoder/color equivalence to FFmpeg or Pillow is unverified."
}

public struct IndependentVideoFrame: Sendable {
    /// An independent, tightly packed RGB8 allocation, top-left and unrotated.
    public let rgb: IndependentRGB8Buffer
    /// Original sample values, including timescale/flags/epoch; never rebased.
    public let presentationTime: CMTime
    /// May be invalid if the source/decoder does not provide a sample duration.
    public let duration: CMTime
    public let decodeTime: CMTime
    public let decodedColor: IndependentVideoColorMetadata
}

/// Bounded, pull-based local-file reader for offline research. This is unrelated
/// to camera capture and does not produce a physical speed measurement. Each
/// next() call owns at most one decoder sample and returns only copied RGB data.
/// Call next()/cancel() serially on an offline queue, never a capture callback.
public final class IndependentVideoReader {
    public struct Limits: Sendable {
        public let maximumDimension: Int
        public let maximumDecodedFrames: Int

        public init(maximumDimension: Int = 4096, maximumDecodedFrames: Int = 1_000_000) {
            self.maximumDimension = maximumDimension
            self.maximumDecodedFrames = maximumDecodedFrames
        }
    }

    public let metadata: IndependentVideoMetadata
    /// Includes discarded preroll and the first sample at/after range end.
    public private(set) var decodedSampleCount = 0
    public private(set) var discardedPrerollSampleCount = 0
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let limits: Limits
    private var previousPTS: CMTime?
    private var ended = false
    private var terminalError: IndependentVideoReaderError?

    /// An omitted track ID selects the first video track. A supplied ID must
    /// identify a video track. A supplied range must be finite, nonempty and
    /// contained in that track's timeline; no silent clamping or time rebasing.
    public static func open(video: URL, trackID: CMPersistentTrackID? = nil,
                            timeRange: CMTimeRange? = nil,
                            limits: Limits = Limits()) async throws -> IndependentVideoReader {
        guard video.isFileURL else { throw IndependentVideoReaderError.localFileRequired }
        let attributes = try? FileManager.default.attributesOfItem(atPath: video.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: video.path) else {
            throw IndependentVideoReaderError.fileUnavailable
        }
        guard (1...4096).contains(limits.maximumDimension), limits.maximumDecodedFrames > 0 else {
            throw IndependentVideoReaderError.resourceLimit
        }
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw IndependentVideoReaderError.noVideoTrack }
        let track: AVAssetTrack
        if let trackID {
            guard let selected = tracks.first(where: { $0.trackID == trackID }) else {
                throw IndependentVideoReaderError.trackNotFound
            }
            track = selected
        } else { track = tracks[0] }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let trackRange = try await track.load(.timeRange)
        let descriptions = try await track.load(.formatDescriptions)
        // Reject even translations/reflections; AVAssetReaderTrackOutput does
        // not normalize preferredTransform and this module never guesses one.
        guard transform.isIdentity else { throw IndependentVideoReaderError.unsupportedTransform }
        guard validDimension(size.width, maximum: limits.maximumDimension),
              validDimension(size.height, maximum: limits.maximumDimension) else {
            throw IndependentVideoReaderError.unsupportedDimensions
        }
        let requested = timeRange ?? trackRange
        guard validRange(trackRange), validRange(requested),
              CMTimeCompare(requested.start, trackRange.start) >= 0,
              CMTimeCompare(CMTimeRangeGetEnd(requested), CMTimeRangeGetEnd(trackRange)) <= 0 else {
            throw IndependentVideoReaderError.invalidTimeRange
        }
        let formats = descriptions.map { description -> IndependentVideoFormatMetadata in
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            func tag(_ key: CFString) -> String? {
                CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
            }
            let color = IndependentVideoColorMetadata(
                primaries: tag(kCMFormatDescriptionExtension_ColorPrimaries),
                transferFunction: tag(kCMFormatDescriptionExtension_TransferFunction),
                yCbCrMatrix: tag(kCMFormatDescriptionExtension_YCbCrMatrix),
                fullRangeVideo: (CMFormatDescriptionGetExtension(description,
                    extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? NSNumber)?.boolValue)
            return IndependentVideoFormatMetadata(mediaSubType: CMFormatDescriptionGetMediaSubType(description),
                width: Int(dimensions.width), height: Int(dimensions.height), color: color)
        }
        guard !formats.isEmpty, formats.allSatisfy({
            $0.width == Int(size.width) && $0.height == Int(size.height)
        }) else { throw IndependentVideoReaderError.unsupportedDimensions }
        let metadata = IndependentVideoMetadata(trackID: track.trackID,
            naturalWidth: Int(size.width), naturalHeight: Int(size.height), nominalFPS: fps,
            preferredTransform: IndependentVideoTransform(transform), trackTimeRange: trackRange,
            requestedTimeRange: requested, sourceFormats: formats)
        let reader = try AVAssetReader(asset: asset)
        // Do not pass requested.start to AVAssetReader.timeRange: when the
        // start falls inside a frame, AVFoundation can clip that sample's PTS
        // to the requested start. Decode sequentially and filter the original
        // times instead. Late ranges cost decode time, not retained frames.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw IndependentVideoReaderError.readerSetupFailed("Cannot add BGRA video output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw IndependentVideoReaderError.readerSetupFailed(reader.error?.localizedDescription ?? "Cannot start decoding")
        }
        return IndependentVideoReader(metadata: metadata, reader: reader, output: output, limits: limits)
    }

    private init(metadata: IndependentVideoMetadata, reader: AVAssetReader,
                 output: AVAssetReaderTrackOutput, limits: Limits) {
        self.metadata = metadata; self.reader = reader; self.output = output; self.limits = limits
    }

    deinit { reader.cancelReading() }

    /// nil means successful EOF/range completion only; failures remain errors on
    /// subsequent calls. Samples outside the requested PTS range are discarded.
    /// Checks also run for every discarded preroll sample. Cancellation is
    /// observed on the calling serial queue; cancel() need not race a read.
    public func next(checkCancellation: () throws -> Void = {}) throws -> IndependentVideoFrame? {
        if let terminalError { throw terminalError }
        guard !ended else { return nil }
        do {
            while true {
                try checkCancellation()
                // Drain ObjC autoreleases for every discarded preroll sample,
                // not merely once per returned frame of a late requested range.
                switch try autoreleasepool(invoking: readNextSample) {
                case .skipped: continue
                case .finished: return nil
                case .frame(let frame): return frame
                }
            }
        } catch is CancellationError {
            terminalError = .cancelled; reader.cancelReading(); throw CancellationError()
        } catch let error as IndependentVideoReaderError {
            terminalError = error; reader.cancelReading(); throw error
        } catch {
            let failure = IndependentVideoReaderError.decodingFailed(error.localizedDescription)
            terminalError = failure; reader.cancelReading(); throw failure
        }
    }

    private enum ReadStep { case skipped, finished, frame(IndependentVideoFrame) }

    private func readNextSample() throws -> ReadStep {
        guard let sample = output.copyNextSampleBuffer() else {
            switch reader.status {
            case .completed: ended = true; return .finished
            case .cancelled: throw IndependentVideoReaderError.cancelled
            default: throw IndependentVideoReaderError.decodingFailed(
                reader.error?.localizedDescription ?? "Decoder ended without completing")
            }
        }
        decodedSampleCount += 1
        guard decodedSampleCount <= limits.maximumDecodedFrames else {
            throw IndependentVideoReaderError.resourceLimit
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        try Self.validatePresentationTime(pts, after: previousPTS)
        previousPTS = pts
        if CMTimeCompare(pts, metadata.requestedTimeRange.start) < 0 {
            discardedPrerollSampleCount += 1
            return .skipped
        }
        if CMTimeCompare(pts, CMTimeRangeGetEnd(metadata.requestedTimeRange)) >= 0 {
            ended = true; reader.cancelReading(); return .finished
        }
        guard CMSampleBufferGetNumSamples(sample) == 1,
              let pixels = CMSampleBufferGetImageBuffer(sample) else {
            throw IndependentVideoReaderError.invalidPixelBufferLayout
        }
        let rgb = try Self.copyRGB(pixels, width: metadata.naturalWidth, height: metadata.naturalHeight)
        return .frame(IndependentVideoFrame(rgb: rgb, presentationTime: pts,
            duration: CMSampleBufferGetDuration(sample),
            decodeTime: CMSampleBufferGetDecodeTimeStamp(sample), decodedColor: Self.colorTags(pixels)))
    }

    /// Cancellation is distinct from EOF. Cancelling an already completed
    /// reader keeps successful EOF; a prior error keeps its original cause.
    public func cancel() {
        guard !ended, terminalError == nil else { return }
        terminalError = .cancelled
        reader.cancelReading()
    }

    static func validatePresentationTime(_ pts: CMTime, after previous: CMTime?) throws {
        guard validTime(pts) else { throw IndependentVideoReaderError.invalidPresentationTime }
        if let previous, CMTimeCompare(pts, previous) <= 0 {
            throw IndependentVideoReaderError.nonMonotonicPresentationTime
        }
    }

    private static func validTime(_ time: CMTime) -> Bool {
        time.isValid && time.isNumeric && time.timescale > 0 && time.epoch == 0
    }

    private static func validRange(_ range: CMTimeRange) -> Bool {
        range.isValid && validTime(range.start) && validTime(range.duration)
            && CMTimeCompare(range.duration, .zero) > 0 && validTime(CMTimeRangeGetEnd(range))
    }

    private static func validDimension(_ dimension: CGFloat, maximum: Int) -> Bool {
        dimension.isFinite && dimension >= 1 && dimension <= CGFloat(maximum) && dimension.rounded(.towardZero) == dimension
    }

    private static func copyRGB(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> IndependentRGB8Buffer {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw IndependentVideoReaderError.unsupportedPixelFormat
        }
        guard !CVPixelBufferIsPlanar(buffer), CVPixelBufferGetWidth(buffer) == width,
              CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetBytesPerRow(buffer) >= width * 4,
              CVPixelBufferGetBytesPerRow(buffer) <= 4096 * 4 + 4096 else {
            throw IndependentVideoReaderError.invalidPixelBufferLayout
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw IndependentVideoReaderError.invalidPixelBufferLayout
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw IndependentVideoReaderError.invalidPixelBufferLayout
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = y * stride + x * 4
                let destination = (y * width + x) * 3
                bytes[destination] = source[sourceIndex + 2]
                bytes[destination + 1] = source[sourceIndex + 1]
                bytes[destination + 2] = source[sourceIndex]
            }
        }
        return try IndependentRGB8Buffer(width: width, height: height, bytesPerRow: width * 3,
            bytes: bytes, pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
    }

    private static func colorTags(_ buffer: CVPixelBuffer) -> IndependentVideoColorMetadata {
        func tag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        // CVPixelBuffer BGRA layout is 8-bit RGB storage, but no source-YUV
        // range is inferred from that layout or from absent color attachments.
        return IndependentVideoColorMetadata(primaries: tag(kCVImageBufferColorPrimariesKey),
            transferFunction: tag(kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: tag(kCVImageBufferYCbCrMatrixKey), fullRangeVideo: nil)
    }
}
