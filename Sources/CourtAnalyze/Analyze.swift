import Foundation
import AVFoundation
import CoreImage
import CoreML
import CourtCore

/// Runs the same streaming engine used by the app on an explicitly selected local video.
/// Outputs are model estimates; no ground-truth accuracy is inferred from a successful run.
@main struct CourtAnalyze {
    static func main() async {
        do { try await run() }
        catch { fputs("ANALYSIS_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "independent-flight" { try IndependentFlightDiagnostic.run(args); return }
        if args.first == "independent-free-flight" { try IndependentFreeFlightCommand.run(args); return }
        if args.first == "independent-flight-candidate" { try IndependentFlightCandidateCommand.run(args); return }
        if args.first == "independent-frames" { try IndependentFramesDiagnostic.run(args); return }
        if args.first == "independent-video" { try await IndependentVideoDiagnostic.run(args); return }
        if args.first == "independent-full-video" { try await IndependentFullVideoCommand.run(args); return }
        if args.first == "independent-shots" { try IndependentShotsCommand.run(args); return }
        if args.first == "independent-live" { try await IndependentLiveCommand.run(args); return }
        if args.first == "independent-replay" { try IndependentReplayCommand.run(args); return }
        if args.first == "court-calibrate" { try CourtCalibrateCommand.run(args); return }
        guard args.count >= 3 else { throw CourtError.message("Usage: court-analyze VIDEO MODEL_DIRECTORY OUTPUT_JSON [MAX_SECONDS] [cpu] [--corners CORNERS_JSON]") }
        let video = URL(fileURLWithPath: args[0]), modelDirectory = URL(fileURLWithPath: args[1])
        let outputURL = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw CourtError.message("Output already exists; choose a new output path.") }
        let limit = args.count > 3 ? Double(args[3]) ?? .infinity : .infinity
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("No video track") }
        let fps = Double(try await track.load(.nominalFrameRate))
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let units: MLComputeUnits = args.contains("cpu") ? .cpuOnly : .all
        var configuration = TennisAnalysisConfiguration(modelDirectory: modelDirectory, nominalFPS: fps, computeUnits: units)
        if let index = args.firstIndex(of: "--corners") {
            guard args.count > index + 1 else { throw CourtError.message("--corners requires a JSON file of four normalized points") }
            configuration.manualCourtCorners = try JSONDecoder().decode([NormalizedPoint].self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 1])))
            try ManualCourtCorners.validate(configuration.manualCourtCorners!)
        }
        let engine = try ReferenceChain.makeEngine(configuration: configuration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CourtError.message("Cannot start video reader") }
        let context = CIContext(options: [.cacheIntermediates: false])
        let stream = UUID(), start = ProcessInfo.processInfo.systemUptime
        var events: [UUID: TennisShotEvent] = [:], snapshots = 0, frames = 0
        var firstPTS: Double?, lastPTS = 0.0, lastSnapshot: TennisAnalysisSnapshot?
        var totalInference = 0.0, maxInference = 0.0
        func consume(_ snapshot: TennisAnalysisSnapshot) {
            snapshots += 1; lastSnapshot = snapshot
            totalInference += snapshot.inferenceMilliseconds; maxInference = max(maxInference, snapshot.inferenceMilliseconds)
            for event in snapshot.events { events[event.id] = event }
        }
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, let pixels = CMSampleBufferGetImageBuffer(sample) else { throw CourtError.message("Invalid decoded frame") }
            if firstPTS == nil { firstPTS = pts }
            if pts - (firstPTS ?? pts) > limit { reader.cancelReading(); break }
            try autoreleasepool {
                let upright: CVPixelBuffer
                if transform == .identity { upright = pixels }
                else {
                    let image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
                    let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    var target: CVPixelBuffer?
                    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                    guard CVPixelBufferCreate(nil, Int(normalized.extent.width), Int(normalized.extent.height), kCVPixelFormatType_32BGRA,
                                              attributes as CFDictionary, &target) == kCVReturnSuccess, let target else {
                        throw CourtError.message("Cannot orient source frame")
                    }
                    context.render(normalized, to: target); upright = target
                }
                if let snapshot = try engine.process(upright, pts: pts, streamID: stream) { consume(snapshot) }
            }
            frames += 1; lastPTS = pts
            if frames % max(1, Int(fps * 5)) == 0 { fputs("ANALYZING source_seconds=\(String(format: "%.1f", pts)) frames=\(frames) shots=\(events.count)\n", stderr) }
        }
        if reader.status == .failed { throw reader.error ?? CourtError.message("Video decode failed") }
        if let final = engine.finish() { consume(final) }
        let report = Report(source: video.lastPathComponent, sourceFPS: fps, sourceDuration: duration,
                            sourceWidth: Double(size.width), sourceHeight: Double(size.height), decodedFrames: frames,
                            analyzedSourceSeconds: max(0, lastPTS - (firstPTS ?? lastPTS)),
                            wallSeconds: ProcessInfo.processInfo.systemUptime - start, snapshots: snapshots,
                            averageInferenceMilliseconds: snapshots > 0 ? totalInference / Double(snapshots) : 0,
                            maximumInferenceMilliseconds: maxInference, lastSnapshot: lastSnapshot,
                            events: events.values.sorted { $0.sourcePTS < $1.sourcePTS })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("ANALYSIS_OK frames=\(frames) snapshots=\(snapshots) events=\(events.count) speeds=\(events.values.filter { $0.speedKPH != nil }.count) landings=\(events.values.filter { $0.bounce?.xMeters != nil }.count) output=\(outputURL.path)")
    }
    struct Report: Encodable {
        let source: String, sourceFPS: Double, sourceDuration: Double, sourceWidth: Double, sourceHeight: Double
        let decodedFrames: Int, analyzedSourceSeconds: Double, wallSeconds: Double, snapshots: Int
        let averageInferenceMilliseconds: Double, maximumInferenceMilliseconds: Double
        let lastSnapshot: TennisAnalysisSnapshot?
        let events: [TennisShotEvent]
        let physicalAccuracyValidated = false
    }
}
