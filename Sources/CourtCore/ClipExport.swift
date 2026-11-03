import Foundation
import AVFoundation

/// Per-shot clips (Phase 3, docs/camera-side-analysis.md §10). The camera cuts a few seconds of
/// its own 8 Mbps recording without re-encoding: from the in-memory buffer of the segment still
/// being recorded (`CameraMediaPipeline.liveClip`), or from a finished MOV. The clip starts on a
/// keyframe at or before the requested start and is sent with the `file` transfer in small chunks.
public enum ClipExport {
    /// Longest clip the camera cuts.
    public static let maxSeconds = 10.0
    /// The segment being recorded keeps about this many seconds of encoded video in memory
    /// (about 30 MB at 8 Mbps); older parts of an open segment become available once it closes.
    public static let liveWindowSeconds = 30.0
    /// How long the camera waits for the end of a window that has not been captured yet.
    public static let maxWaitSeconds = 4.0
    /// Clips go out in small chunks with a small backlog, so live shot rows sent during a
    /// session wait behind at most one chunk.
    public static let chunkSize = 256 << 10
    public static let backlogLimit = 512 << 10

    public struct Result: Sendable {
        public let url: URL
        public let frames: Int
        public let duration: Double
        /// Source PTS of the clip's first frame.
        public let startPTS: Double
    }

    public static func filename(for id: UUID) -> String { "clip-\(id.uuidString.lowercased()).mov" }

    public static func validate(filename: String) throws {
        guard filename.hasPrefix("clip-"), filename.hasSuffix(".mov"),
              UUID(uuidString: String(filename.dropFirst(5).dropLast(4))) != nil else {
            throw CourtError.message("片段文件名无效。")
        }
    }

    /// Source PTS window for a shot: 2 s before the hit until 1.5 s after the bounce (or the end
    /// of the shot), at least 3 s after the hit and at most `maxSeconds` long.
    public static func window(for shot: TennisShotEvent) -> (start: Double, end: Double) {
        let start = max(0, shot.sourcePTS - 2)
        let last = max(shot.sourcePTS + 3, (shot.bounce?.sourcePTS ?? shot.endPTS ?? shot.sourcePTS) + 1.5)
        return (start, min(start + maxSeconds, last))
    }

    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// From samples in presentation order, the run from the last keyframe at or before `start`
    /// through the last sample at or before `end`.
    static func select(_ samples: [CMSampleBuffer], from start: Double, to end: Double) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        for sample in samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts > end { break }
            if isSync(sample) && (pts <= start || output.isEmpty) { output = [sample] }
            else if !output.isEmpty { output.append(sample) }
        }
        return output
    }

    /// Writes compressed samples into a MOV (or an MP4 for browsers, by extension) without re-encoding. The first sample must be a keyframe.
    /// `sourceOffset` maps sample time to source PTS: 0 for capture samples, the recording's first
    /// PTS for samples read from a MOV.
    public static func write(_ samples: [CMSampleBuffer], to url: URL, sourceOffset: Double = 0) async throws -> Result {
        guard let first = samples.first, isSync(first), let format = CMSampleBufferGetFormatDescription(first) else {
            throw CourtError.message("这段时间没有可用的视频帧。")
        }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CourtError.message("无法建立片段文件。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CourtError.message("片段写入启动失败。") }
        let firstTime = CMSampleBufferGetPresentationTimeStamp(first)
        writer.startSession(atSourceTime: firstTime)
        let feed = Feed(writer: writer, input: input, samples: samples)
        try await feed.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CourtError.message("片段未写完。")
        }
        let last = samples[samples.count - 1]
        let lastDuration = CMSampleBufferGetDuration(last)
        let duration = CMSampleBufferGetPresentationTimeStamp(last).seconds - firstTime.seconds + (lastDuration.isNumeric ? lastDuration.seconds : 0)
        return Result(url: url, frames: samples.count, duration: max(0, duration), startPTS: sourceOffset + firstTime.seconds)
    }

    /// Cuts the movie-time window `from`…`to` of a finished recording into `url`. Movie time 0 is
    /// the recording's first frame (source PTS `firstPTS`).
    public static func cut(_ source: URL, firstPTS: Double, from start: Double, to end: Double, into url: URL) async throws -> Result {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("录像里没有视频轨道。") }
        let samples = try readSamples(asset: asset, track: track, from: start, to: end)
        let selected = select(samples, from: start, to: end)
        guard !selected.isEmpty else { throw CourtError.message("录像里没有这段时间的画面。") }
        return try await write(selected, to: url, sourceOffset: firstPTS)
    }

    private static func readSamples(asset: AVAsset, track: AVAssetTrack, from start: Double, to end: Double) throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset)
        // Passthrough reading does not promise to begin on a keyframe; the recording has one at
        // least every second, so reading from 1.2 s earlier always includes the one before `start`.
        let from = max(0, start - 1.2)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                       end: CMTime(seconds: end + 0.05, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CourtError.message("无法读取录像。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CourtError.message("无法读取录像。") }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            samples.append(sample)
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds > end { break }
        }
        if reader.status == .reading { reader.cancelReading() }
        else if reader.status == .failed { throw reader.error ?? CourtError.message("读取录像失败。") }
        return samples.sorted { CMSampleBufferGetPresentationTimeStamp($0) < CMSampleBufferGetPresentationTimeStamp($1) }
    }

    /// Pull-based feeding of a non-real-time writer input.
    private final class Feed: @unchecked Sendable {
        let writer: AVAssetWriter, input: AVAssetWriterInput, samples: [CMSampleBuffer]
        private let queue = DispatchQueue(label: "court.clip.writer", qos: .utility)
        private var index = 0, finished = false
        init(writer: AVAssetWriter, input: AVAssetWriterInput, samples: [CMSampleBuffer]) {
            self.writer = writer; self.input = input; self.samples = samples
        }
        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData && index < samples.count {
                        guard input.append(samples[index]) else {
                            finished = true; input.markAsFinished()
                            continuation.resume(throwing: writer.error ?? CourtError.message("片段帧写入失败。")); return
                        }
                        index += 1
                    }
                    if index >= samples.count {
                        finished = true; input.markAsFinished(); continuation.resume()
                    }
                }
            }
        }
    }
}
