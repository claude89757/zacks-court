import Foundation
import CoreMedia

public enum IndependentBallWindowAssemblyError: Error, Equatable {
    case invalidConfiguration, invalidSourceIdentity, nonMonotonicTimestamp
}

/// A complete, non-overlapping group of eight real source frames. The frozen
/// background uses only the 48 preceding warmup frames in this segment.
public struct IndependentBallPreparedWindow: Sendable {
    public let background: IndependentRGB8Buffer
    public let frames: [IndependentRGB8Buffer]
    public let times: [IndependentBallFrameTime]
    public let transform: IndependentBallImageTransform
    public let sourceID: String
    public let segmentIndex: UInt64
    public let windowIndex: UInt64
    public let backgroundTimes: [IndependentBallFrameTime]
    public let backgroundStrategy: String
    /// Frame zero waits for seven actual subsequent frames, at the source rate.
    public let lookaheadFrames: Int
}

public struct IndependentBallWindowAssemblyState: Sendable {
    public let segmentIndex: UInt64
    /// Reaches 48 and remains 48 while the frozen background is available.
    public let warmupFrameCount: Int
    public let pendingFrameCount: Int
    public let backgroundReady: Bool
    /// Images retained by the assembler, excluding windows handed to the caller
    /// and the transient resize/median result during append.
    public let retainedImageCount: Int
    public let retainedImageBytes: Int
    public let lastResetReason: String?
}

/// Synchronous owned-RGB work for an offline/analysis queue, never the capture
/// callback. This object is confined to that queue and owns no CVPixelBuffers.
///
/// `prefix_median48_resized_rgb` first crops/resizes each real frame with the
/// Pillow-compatible RGB8 preprocessor, then takes the per-byte even median.
/// It is intentionally distinct from median-in-native-RGB then resize, and
/// does not claim equivalence to a training background strategy. After 48
/// continuous warmup frames the background freezes. Each following group of
/// eight continuous frames is emitted once, with seven frames of lookahead;
/// there is no padding, interpolation, sliding overlap, or tail flush.
public final class IndependentBallWindowAssembler {
    public static let backgroundStrategy = "prefix_median48_resized_rgb"
    public static let warmupFrameCount = 48
    public static let windowFrameCount = 8
    public static let resizedImageBytes = 512 * 288 * 3

    private let maximumInterval: Double
    private var sourceID: String?
    private var transform: IndependentBallImageTransform?
    private var roi: IndependentBallROI?
    private var previousTime: CMTime?
    private var warmup: [IndependentRGB8Buffer] = []
    private var warmupTimes: [IndependentBallFrameTime] = []
    private var background: IndependentRGB8Buffer?
    private var pending: [IndependentRGB8Buffer] = []
    private var pendingTimes: [IndependentBallFrameTime] = []
    private var segmentIndex: UInt64 = 0
    private var windowIndex: UInt64 = 0
    private var lastResetReason: String?

    /// Accepts source rates from 1 through 240 fps, inclusive. Continuity permits
    /// at most 1.5 source periods; the component never resamples source timing.
    public init(nominalFramesPerSecond: Double = 60) throws {
        guard nominalFramesPerSecond.isFinite, (1...240).contains(nominalFramesPerSecond) else {
            throw IndependentBallWindowAssemblyError.invalidConfiguration
        }
        maximumInterval = 1.5 / nominalFramesPerSecond
    }

    public var state: IndependentBallWindowAssemblyState {
        let count = warmup.count + pending.count + (background == nil ? 0 : 1)
        return .init(segmentIndex: segmentIndex, warmupFrameCount: warmupTimes.count,
                     pendingFrameCount: pending.count, backgroundReady: background != nil,
                     retainedImageCount: count, retainedImageBytes: count * Self.resizedImageBytes,
                     lastResetReason: lastResetReason)
    }

    /// Drops warmup, frozen background and incomplete window together.
    public func reset(reason: String = "explicit_reset") {
        sourceID = nil; transform = nil; roi = nil; previousTime = nil
        warmup.removeAll(keepingCapacity: false); warmupTimes.removeAll(keepingCapacity: false)
        background = nil
        pending.removeAll(keepingCapacity: false); pendingTimes.removeAll(keepingCapacity: false)
        segmentIndex &+= 1; windowIndex = 0; lastResetReason = reason
    }

    /// Invalid input throws after clearing all temporal state. Valid source,
    /// dimensions, ROI or gap changes reset and count this frame as warmup #1.
    /// Returned images are already cropped/resized; call makeTensor with no ROI.
    public func append(image: IndependentRGB8Buffer, time: IndependentBallFrameTime,
                       sourceID: String, roi: IndependentBallROI? = nil) throws -> IndependentBallPreparedWindow? {
        do {
            return try appendValidated(image: image, time: time, sourceID: sourceID, roi: roi)
        } catch {
            reset(reason: error as? IndependentBallWindowAssemblyError == .nonMonotonicTimestamp
                  ? "non_monotonic_timestamp" : "invalid_input")
            throw error
        }
    }

    private func appendValidated(image: IndependentRGB8Buffer, time: IndependentBallFrameTime,
                                 sourceID: String, roi: IndependentBallROI?) throws -> IndependentBallPreparedWindow? {
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndependentBallWindowAssemblyError.invalidSourceIdentity
        }
        // FrameTime is Codable; revalidate even if its initializer was bypassed.
        let now = try time.mediaTime()
        let resized = try IndependentBallPreprocessor.resizeRGB8(image, roi: roi)
        let mapping = try IndependentBallImageTransform(originalWidth: image.width, originalHeight: image.height,
            cropX: roi?.x ?? 0, cropY: roi?.y ?? 0, cropWidth: roi?.width, cropHeight: roi?.height)

        var reason: String?
        if let oldSource = self.sourceID, oldSource != sourceID { reason = "source_changed" }
        else if let old = transform, old.originalWidth != image.width || old.originalHeight != image.height {
            reason = "dimensions_changed"
        } else if self.sourceID != nil, self.roi != roi { reason = "roi_changed" }
        else if let previousTime {
            guard CMTimeCompare(now, previousTime) > 0 else {
                throw IndependentBallWindowAssemblyError.nonMonotonicTimestamp
            }
            let delta = CMTimeSubtract(now, previousTime).seconds
            if !delta.isFinite || delta > maximumInterval { reason = "source_gap" }
        }
        if let reason { reset(reason: reason) }
        self.sourceID = sourceID; transform = mapping; self.roi = roi; previousTime = now

        if background == nil {
            warmup.append(resized); warmupTimes.append(time)
            if warmup.count == Self.warmupFrameCount {
                background = try Self.median(warmup)
                warmup.removeAll(keepingCapacity: false)
            }
            return nil
        }
        pending.append(resized); pendingTimes.append(time)
        guard pending.count == Self.windowFrameCount, let background else { return nil }
        let result = IndependentBallPreparedWindow(background: background, frames: pending, times: pendingTimes,
            transform: mapping, sourceID: sourceID, segmentIndex: segmentIndex, windowIndex: windowIndex,
            backgroundTimes: warmupTimes, backgroundStrategy: Self.backgroundStrategy, lookaheadFrames: 7)
        // Array value ownership transfers to the result; no emitted frame remains
        // in the assembler. Only one frozen image and the next <=7 frames persist.
        pending = []; pendingTimes = []; windowIndex &+= 1
        return result
    }

    private static func median(_ images: [IndependentRGB8Buffer]) throws -> IndependentRGB8Buffer {
        var output = [UInt8](repeating: 0, count: resizedImageBytes)
        var scratch = [UInt8](repeating: 0, count: warmupFrameCount)
        // Scope every source pointer inside its owning Array's borrow. No pointer
        // escapes, and scratch is reused for every byte rather than allocated per pixel.
        var pointers: [UnsafePointer<UInt8>] = []
        func borrow(_ index: Int) {
            if index < images.count {
                images[index].bytes.withUnsafeBufferPointer { bytes in
                    pointers.append(bytes.baseAddress!)
                    borrow(index + 1)
                    pointers.removeLast()
                }
                return
            }
            output.withUnsafeMutableBufferPointer { destination in
                scratch.withUnsafeMutableBufferPointer { values in
                    for byte in 0..<resizedImageBytes {
                        for frame in 0..<warmupFrameCount { values[frame] = pointers[frame][byte] }
                        let lower = selectMiddle(values)
                        var upper = values[24]
                        for i in 25..<warmupFrameCount { upper = min(upper, values[i]) }
                        destination[byte] = UInt8((Int(lower) + Int(upper)) / 2)
                    }
                }
            }
        }
        borrow(0)
        return try IndependentRGB8Buffer(width: 512, height: 288, bytesPerRow: 512 * 3,
            bytes: output, pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
    }

    /// Three-way selection handles equal-valued pixels without quadratic scans.
    /// On return positions 24...47 contain the upper half (including ties).
    private static func selectMiddle(_ values: UnsafeMutableBufferPointer<UInt8>) -> UInt8 {
        let target = 23
        var low = 0, high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var less = low, current = low, greater = high
            while current <= greater {
                if values[current] < pivot {
                    values.swapAt(less, current); less += 1; current += 1
                } else if values[current] > pivot {
                    values.swapAt(current, greater); greater -= 1
                } else { current += 1 }
            }
            if target < less { high = less - 1 }
            else if target > greater { low = greater + 1 }
            else { return values[target] }
        }
        return values[target]
    }
}
