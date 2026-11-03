import Foundation
import AVFoundation

public struct RecordingResult {
    public let url: URL
    public let frames: Int
    public let duration: Double
}

/// Use only from the caller's serial media queue. Never silently skip dependent encoded frames.
public final class MovieRecorder {
    public let url: URL
    public private(set) var frames = 0
    public private(set) var firstPTS: Double?
    private var lastPTS: Double?
    private var lastDuration = 0.0
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var log: FileHandle?
    private var ended = false

    public init(directory: URL, prefix: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        url = directory.appendingPathComponent(name).appendingPathExtension("mov")
    }

    deinit {
        try? log?.close()
        if !ended { writer?.cancelWriting() }
    }

    public func append(_ sample: CMSampleBuffer, header: StreamHeader) throws {
        guard !ended else { throw CourtError.message("录像已经结束。") }
        if writer == nil {
            guard header.keyframe == true, let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CourtError.message("无法建立录像文件。") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CourtError.message("录像启动失败。") }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            self.writer = writer; self.input = input
            let logURL = url.deletingPathExtension().appendingPathExtension("jsonl")
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw CourtError.message("无法创建时间戳记录。") }
            log = try FileHandle(forWritingTo: logURL)
        }
        guard let writer, let input else { return }
        guard input.isReadyForMoreMediaData else { throw CourtError.message("磁盘写入跟不上视频，录像已停止。") }
        guard input.append(sample) else { throw writer.error ?? CourtError.message("录像帧写入失败。") }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts; lastDuration = CMSampleBufferGetDuration(sample).seconds; frames += 1
        var line = try JSONEncoder().encode(header); line.append(10)
        try log?.write(contentsOf: line)
    }

    public func finish(_ completion: @escaping (Result<RecordingResult, Error>) -> Void) {
        guard !ended else { completion(.failure(CourtError.message("录像已关闭。"))); return }
        ended = true
        try? log?.close(); log = nil
        guard let writer, let input, frames > 0 else {
            self.writer?.cancelWriting()
            completion(.failure(CourtError.message("没有收到可保存的视频帧。"))); return
        }
        input.markAsFinished()
        let result = RecordingResult(url: url, frames: frames, duration: max(0, (lastPTS ?? 0) - (firstPTS ?? 0) + lastDuration))
        writer.finishWriting {
            if writer.status == .completed { completion(.success(result)) }
            else { completion(.failure(writer.error ?? CourtError.message("录像未完成。"))) }
        }
    }
}
