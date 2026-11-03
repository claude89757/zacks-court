import Foundation
import AVFoundation
import CourtCore

/// Explicit whole-source evaluation. The model, preprocessing, background and
/// causal association are exactly the shared App implementation, without clips
/// or artificial state resets. Partial progress survives a failed run.
enum IndependentFullVideoCommand {
    struct Input: Decodable {
        let schema: String
        let videoPath: String
        let sourceSHA256: String
        let expectedFrameCount: Int
        let firstPTS: Int64, lastPTS: Int64
        let timescale: Int32
        /// Optional. When true the source may carry a non-60 nominal rate (for example 59.94 fps
        /// phone video); the analysis still uses every decoded frame's real PTS. Default false.
        let allowNonSixtyNominalFPS: Bool?
    }
    private final class ProgressLog: @unchecked Sendable {
        let output: URL
        let began = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var last = -Double.infinity
        private var phase = ""
        init(_ output: URL) { self.output = output }
        func update(_ value: IndependentLocalVideoProgress) {
            update(phase:value.phase,decodedFrames:value.decodedFrames,inferredFrames:value.inferredFrames,fraction:value.fraction)
        }
        func update(phase nextPhase: String, decodedFrames: Int, inferredFrames: Int, fraction: Double) {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            guard phase != nextPhase || now-last >= 5 else { return }
            phase = nextPhase; last = now
            let row: [String: Any] = ["phase":nextPhase,"decodedFrames":decodedFrames,
                "inferredFrames":inferredFrames,"fraction":fraction,"elapsedSeconds":now-began]
            if let data = try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) {
                try? data.write(to:output.appendingPathComponent("progress.json"),options:.atomic)
            }
            fputs("FULL_VIDEO phase=\(nextPhase) decoded=\(decodedFrames) inferred=\(inferredFrames) percent=\(String(format:"%.2f",fraction*100)) elapsed=\(String(format:"%.1f",now-began))s\n",stderr)
        }
    }
    static func run(_ args: [String]) async throws {
        func require(_ value: Bool, _ reason: String) throws { if !value { throw CourtError.message(reason) } }
        try require(args.count == 4,"Usage: court-analyze independent-full-video PROTOCOL_JSON STAGED_MODEL_DIRECTORY NEW_OUTPUT_DIRECTORY")
        let protocolURL = URL(fileURLWithPath:args[1]), directory = URL(fileURLWithPath:args[2])
        let output = URL(fileURLWithPath:args[3]).standardizedFileURL
        let data = try Data(contentsOf:protocolURL)
        let input = try JSONDecoder().decode(Input.self,from:data)
        try require(input.schema == "independent-full-video-v1" && input.videoPath.hasPrefix("/")
            && input.timescale > 0 && input.firstPTS <= input.lastPTS
            && (1...215_984).contains(input.expectedFrameCount),"Invalid full-source protocol")
        try require(!FileManager.default.fileExists(atPath:output.path),"Output exists; choose a new directory")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try data.write(to:output.appendingPathComponent("input-protocol.json"),options:.withoutOverwriting)
        let progress = ProgressLog(output)
        do {
            let assets = try IndependentBallModelAssets.load(directory:directory)
            let result = try await IndependentLocalVideoAnalyzer.run(request:.init(
                videoURL:URL(fileURLWithPath:input.videoPath),expectedSourceSHA256:input.sourceSHA256,
                requireNominal60FPS:!(input.allowNonSixtyNominalFPS ?? false),
                maximumFrames:input.expectedFrameCount+200,maximumDurationSeconds:3600,limitMode:.offlineFullVideo),
                assets:assets,progress:{ progress.update($0) })
            // A long run must not be lost to a metadata mismatch: keep the report aside before checking.
            func keepUnverified(_ reason: String) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try? encoder.encode(result).write(to:output.appendingPathComponent("report-failed-checks.json"),options:.withoutOverwriting)
                fputs("FULL_VIDEO check failed (\(reason)); report kept as report-failed-checks.json\n",stderr)
            }
            func check(_ value: Bool, _ reason: String) throws { if !value { keepUnverified(reason); throw CourtError.message(reason) } }
            try check(result.frames.count == input.expectedFrameCount,"Whole-source decoded frame count differs from frozen container metadata")
            try check(result.discardedPrerollSampleCount == 0,"Whole-source evaluation unexpectedly discarded preroll")
            try check(result.frames.first.map { CMTimeCompare($0.presentationTime.mediaTime,CMTime(value:input.firstPTS,timescale:input.timescale)) == 0 } == true,
                        "First source PTS differs from frozen protocol")
            try check(result.frames.last.map { CMTimeCompare($0.presentationTime.mediaTime,CMTime(value:input.lastPTS,timescale:input.timescale)) == 0 } == true,
                        "Last source PTS differs from frozen protocol")
            try require(try Data(contentsOf:protocolURL) == data,"Full-source protocol changed during execution")
            progress.update(phase:"saving_report",decodedFrames:result.frames.count,inferredFrames:result.inferredFrames,fraction:1)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(result).write(to:output.appendingPathComponent("report.json"),options:.withoutOverwriting)
            let states = Dictionary(grouping:result.frames,by:{$0.state.rawValue}).mapValues(\.count)
            let summary: [String:Any] = ["schema":"independent-full-video-summary-v1","complete":true,
                "protocolSHA256":try IndependentVideoDiagnostic.shaFile(protocolURL),"sourceSHA256":result.sourceSHA256,
                "modelManifestSHA256":result.modelManifestSHA256,"decodedFrames":result.frames.count,
                "inferredFrames":result.inferredFrames,"coreMLForwards":result.windows.count,"frameStates":states,
                "sourceSegments":Set(result.frames.map(\.segmentIndex)).count,"unflushedTailFrames":result.unflushedTailFrames,
                "inferenceSeconds":result.inferenceSeconds,"wallSecondsExcludingSourceHashAndModelLoad":result.wallSecondsExcludingSourceHashAndModelLoad,
                "assemblerPeakRetainedRGBBytes":result.assemblerPeakRetainedRGBBytes,"speedOutputs":0,
                "formal":false,"human":false,"production":false,"physicalAccuracyValidated":false,
                "twentyPercentAcceptanceEligible":false,"meaning":"Candidate availability is not ball correctness or speed accuracy. No automatic independent hit segmentation/qualified camera is supplied."]
            try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("summary.json"),options:.withoutOverwriting)
            for name in ["report.json","summary.json","input-protocol.json"] {
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.appendingPathComponent(name).path)
            }
            progress.update(phase:"complete",decodedFrames:result.frames.count,inferredFrames:result.inferredFrames,fraction:1)
            print("INDEPENDENT_FULL_VIDEO_OK decoded=\(result.frames.count) inferred=\(result.inferredFrames) forwards=\(result.windows.count) speeds=0 output=\(output.path)")
        } catch {
            let failure: [String:Any] = ["complete":false,"error":error.localizedDescription,"speedOutputs":0]
            if let encoded = try? JSONSerialization.data(withJSONObject:failure,options:[.sortedKeys]) {
                try? encoded.write(to:output.appendingPathComponent("failure.json"),options:.atomic)
            }
            throw error
        }
    }
}
