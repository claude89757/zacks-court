import Foundation
import AVFoundation
import CryptoKit
import CourtCore

/// Explicit development-only source-video adapter. It has no S家 dependency,
/// contact detector, qualified camera calibration or physical speed output.
enum IndependentVideoDiagnostic {
    struct Stamp: Decodable {
        let value: Int64
        let timescale: Int32
        func time() throws -> CMTime {
            try check(timescale > 0, "Invalid protocol timescale")
            let result = CMTime(value: value, timescale: timescale)
            try check(result.isNumeric && result.seconds.isFinite, "Invalid protocol timestamp")
            return result
        }
    }
    struct Input: Decodable {
        let schema_version: Int
        let video_path: String
        let source_sha256: String
        let source_window: String
        let nominal_fps: Double
        let decode_start: Stamp
        let decode_end: Stamp
        let expected_warmup_times: [Stamp]
        let expected_inference_times: [Stamp]
        let roi_xywh: [Int]?
        let export_resized_rgb: Bool
    }
    static func check(_ condition: Bool, _ message: String) throws {
        try IndependentFramesDiagnostic.require(condition, message)
    }
    static func sha(_ data: Data) -> String { IndependentFramesDiagnostic.sha(data) }
    static func shaFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        // FileHandle may return autoreleased backing storage. Drain each chunk
        // here so hashing a multi-GB source does not retain the entire file.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount:4*1024*1024), !data.isEmpty else { return false }
            digest.update(data:data)
            return true
        }) { }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func stamp(_ time: CMTime) -> [String: Any] {
        ["value":time.value, "timescale":time.timescale, "epoch":time.epoch,
         "flags":time.flags.rawValue, "seconds":time.isNumeric ? time.seconds as Any : NSNull()]
    }
    static func stamp(_ time: IndependentBallFrameTime) -> [String: Any] {
        ["value":time.sourcePTS,"time_base_numerator":time.timeBaseNumerator,
         "timescale":time.timeBaseDenominator]
    }
    static func color(_ value: IndependentVideoColorMetadata) -> [String: Any] {
        ["primaries":value.primaries.map { $0 as Any } ?? NSNull(),
         "transfer_function":value.transferFunction.map { $0 as Any } ?? NSNull(),
         "ycbcr_matrix":value.yCbCrMatrix.map { $0 as Any } ?? NSNull(),
         "full_range_video":value.fullRangeVideo.map { $0 as Any } ?? NSNull()]
    }
    static func json(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            .write(to:url,options:.withoutOverwriting)
    }
    /// Mutated only by synchronous callbacks on the shared serial analysis queue;
    /// read after run() has returned. No RGB/tensor/heatmap is retained here.
    private final class CollectedDiagnostics: @unchecked Sendable {
        var decodedRows: [[String:Any]] = []
        var windows: [[String:Any]] = []
    }
    static func run(_ args: [String]) async throws {
        try check(args.count == 4, "Usage: court-analyze independent-video PROTOCOL_JSON STAGED_MODEL_DIRECTORY NEW_OUTPUT_DIRECTORY")
        let protocolURL = URL(fileURLWithPath:args[1]), modelDirectory = URL(fileURLWithPath:args[2])
        let destination = URL(fileURLWithPath:args[3]).standardizedFileURL
        try check(!FileManager.default.fileExists(atPath:destination.path), "Output exists; choose a new directory")
        let protocolData = try Data(contentsOf:protocolURL)
        let input = try JSONDecoder().decode(Input.self,from:protocolData)
        try check(input.schema_version == 1 && !input.source_window.isEmpty && input.video_path.hasPrefix("/"), "Invalid source-video protocol")
        try check(input.source_sha256.count == 64 && input.source_sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), "Invalid source SHA256")
        try check(input.nominal_fps.isFinite && (1...240).contains(input.nominal_fps), "Invalid nominal FPS")
        let startTime = try input.decode_start.time(), endTime = try input.decode_end.time()
        let duration = CMTimeSubtract(endTime,startTime)
        try check(duration.isNumeric && duration.seconds > 0 && duration.seconds <= 120, "Diagnostic range must be finite, positive and at most120 seconds")
        let expected = try input.expected_inference_times.map { try $0.time() }
        let expectedWarmup = try input.expected_warmup_times.map { try $0.time() }
        try check(expectedWarmup.count == 48,"Exactly48 frozen real warmup PTS are required")
        let allExpected = expectedWarmup+expected
        try check(!expected.isEmpty && expected.count <= 7200 && expected.count.isMultiple(of:8), "Expected inference PTS must contain complete8-frame groups, at most7200 frames")
        for i in allExpected.indices {
            try check(CMTimeCompare(allExpected[i],startTime) >= 0 && CMTimeCompare(allExpected[i],endTime) < 0, "Expected PTS outside decode interval")
            if i > 0 {
                let dt = CMTimeSubtract(allExpected[i],allExpected[i-1]).seconds
                try check(dt > 0 && dt <= 1.5/input.nominal_fps, "Expected model input crosses a discontinuity")
            }
        }
        let roi: IndependentBallROI?
        if let r = input.roi_xywh {
            try check(r.count == 4,"ROI requires integer x,y,width,height")
            roi = .init(x:r[0],y:r[1],width:r[2],height:r[3])
        } else { roi = nil }
        let video = URL(fileURLWithPath:input.video_path)
        let assets = try IndependentBallModelAssets.load(directory: modelDirectory)
        let modelSHA = assets.manifestSHA256
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".independent-video-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at:temporary) } }
        let rgbDirectory = temporary.appendingPathComponent("resized-rgb")
        if input.export_resized_rgb { try FileManager.default.createDirectory(at:rgbDirectory,withIntermediateDirectories:false) }
        let collected = CollectedDiagnostics()
        let observers = IndependentLocalVideoObservers(onDecoded: { index, frame in
            try check(index < allExpected.count && CMTimeCompare(frame.presentationTime,allExpected[index]) == 0,
                      "Native decoded PTS does not match frozen warmup/target source PTS")
            var row: [String:Any] = ["decode_index":index,"presentation_time":stamp(frame.presentationTime),
                "sample_duration":stamp(frame.duration),"decode_time":stamp(frame.decodeTime),
                "decoded_color":color(frame.decodedColor),"owned_native_rgb_sha256":sha(Data(frame.rgb.bytes))]
            if input.export_resized_rgb {
                let resized = try IndependentBallPreprocessor.resizeRGB8(frame.rgb,roi:roi)
                let data = Data(resized.bytes), file = String(format:"frame-%05d.rgb",index)
                try data.write(to:rgbDirectory.appendingPathComponent(file),options:.withoutOverwriting)
                row["resized_rgb_file"] = "resized-rgb/"+file; row["resized_rgb_sha256"] = sha(data)
            }
            collected.decodedRows.append(row)
        }, onWindow: { window, prepared, tensor, heatmaps in
            var row: [String:Any] = ["window_index":window.windowIndex,"segment_index":window.segmentIndex,
                "background_strategy":window.backgroundStrategy,"background_times":window.backgroundTimes.map(stamp),
                "background_sha256":window.backgroundSHA256,"tensor_sha256":window.tensorSHA256,"heatmaps_sha256":window.heatmapsSHA256,
                "inference_seconds":window.inferenceSeconds,"available_at_pts":stamp(window.availableAt.mediaTime),"lookahead_frames":window.lookaheadFrames]
            if collected.windows.isEmpty {
                try tensor.withUnsafeBufferPointer { try Data(buffer:$0).write(to:temporary.appendingPathComponent("first-window.tensor.f32le"),options:.withoutOverwriting) }
                try heatmaps.withUnsafeBufferPointer { try Data(buffer:$0).write(to:temporary.appendingPathComponent("first-window.heatmaps.f32le"),options:.withoutOverwriting) }
                try Data(prepared.background.bytes).write(to:temporary.appendingPathComponent("first-background.rgb"),options:.withoutOverwriting)
                row["tensor_file"] = "first-window.tensor.f32le"; row["heatmaps_file"] = "first-window.heatmaps.f32le"
            }
            collected.windows.append(row)
            fputs("INDEPENDENT_VIDEO frames=\(collected.windows.count*8) decoded=\(collected.decodedRows.count) speeds=0\n",stderr)
        })
        let result = try await IndependentLocalVideoAnalyzer.run(request: .init(videoURL:video, expectedSourceSHA256:input.source_sha256,
            timeRange:CMTimeRange(start:startTime,duration:duration), roi:roi, requireNominal60FPS:false, expectedNominalFPS:input.nominal_fps), assets:assets, observers:observers)
        let decodedRows = collected.decodedRows, windows = collected.windows
        var outputRows: [[String:Any]] = []
        for frame in result.frames {
            guard let choice = frame.selection, let bank = frame.candidateBank, let window = frame.windowIndex, let available = frame.availableAt else { continue }
            let outputIndex = outputRows.count
            try check(outputIndex < expected.count && CMTimeCompare(frame.presentationTime.mediaTime,expected[outputIndex]) == 0,
                      "Native inferred PTS does not match frozen target PTS")
            var row = try JSONSerialization.jsonObject(with:JSONEncoder().encode(choice)) as? [String:Any] ?? [:]
            if choice.candidate == nil { row["candidate"] = NSNull() }
            row["frame_index"] = outputIndex; row["window_index"] = window; row["segment_index"] = frame.segmentIndex
            row["available_at_pts"] = stamp(available.mediaTime); row["source_lookahead_seconds"] = frame.sourceLookaheadSeconds
            row["candidate_bank"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(bank))
            row["speed_kmh"] = NSNull(); row["speed_unavailable_reason"] = "No qualified camera calibration, flight segmentation or contact-time evidence"
            outputRows.append(row)
        }
        try check(outputRows.count == expected.count,"Missing frozen target PTS; warmup or decode interval is incomplete")
        try check(decodedRows.count == expected.count+48 && result.unflushedTailFrames == 0,
                  "Protocol must supply exactly48 preceding warmup frames and its complete frozen target interval")
        let metadata = result.metadata, transform = metadata.preferredTransform
        let report: [String:Any] = ["schema_version":1,"pipeline":"native_video_rgb_prefix48_coreml_past_association_v1",
            "production":false,"speed_model_accepted":false,"physical_accuracy_validated":false,"app_capture_integrated":false,
            "source_window":input.source_window,"source_sha256":input.source_sha256,"protocol_sha256":sha(protocolData),
            "model_manifest_sha256":modelSHA,"nominal_fps":input.nominal_fps,"width":metadata.naturalWidth,"height":metadata.naturalHeight,
            "track_id":metadata.trackID,"track_time_range":["start":stamp(metadata.trackTimeRange.start),"duration":stamp(metadata.trackTimeRange.duration)],
            "requested_time_range":["start":stamp(startTime),"end":stamp(endTime)],
            "preferred_transform":[transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty],
            "source_formats":metadata.sourceFormats.map { ["media_subtype":$0.mediaSubType,"width":$0.width,"height":$0.height,"color":color($0.color)] as [String:Any] },
            "decoding_boundary":metadata.decodingBoundary,"decoded_video_in_this_command":true,
            "range_decoding_strategy":metadata.rangeDecodingStrategy,
            "total_decoded_samples_including_preroll":result.decodedSampleCount,
            "discarded_preroll_samples":result.discardedPrerollSampleCount,
            "background_strategy":IndependentBallWindowAssembler.backgroundStrategy,"background_uses_future_inference_frames":false,
            "model_lookahead_frames":7,"candidate_threshold":0.3,"candidate_tie_rule":"peak_then_box_area_then_raster_seed_v1",
            "decoded_frames":decodedRows.count,"inferred_frames":outputRows.count,"speed_outputs":0,
            "warmup_frames_per_segment":48,"unflushed_tail_frames":result.unflushedTailFrames,
            "assembler_peak_retained_rgb_bytes":result.assemblerPeakRetainedRGBBytes,"inference_seconds":result.inferenceSeconds,
            "wall_seconds_excluding_source_hash_and_model_load":result.wallSecondsExcludingSourceHashAndModelLoad,
            "decoded_inputs":decodedRows,"windows":windows,"frames":outputRows,
            "limitations":["Development-only: no hit-event or qualified3D speed estimator.",
                "AVFoundation color/decode differs from previous FFmpeg/JPEG inputs; equivalence is unverified.",
                "Resize-before-prefix-median is a new policy and differs from the historical offline background.",
                "Eight-frame model has up to seven frames of lookahead; CPU offline wall time is not phone performance.",
                "No camera capture, App default-backend replacement, human accuracy or final acceptance is established."]]
        try json(report,to:temporary.appendingPathComponent("report.json"))
        try protocolData.write(to:temporary.appendingPathComponent("input-protocol.json"),options:.withoutOverwriting)
        try FileManager.default.moveItem(at:temporary,to:destination)
        published = true
        print("INDEPENDENT_VIDEO_OK decoded=\(decodedRows.count) frames=\(outputRows.count) speeds=0 output=\(destination.path)")
    }
}
