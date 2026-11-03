import Foundation
import CryptoKit
import CourtCore

/// Explicit offline owned-RGB diagnostic. The manifest is a source-bound frame
/// adapter, not a video decoder or proof of camera/capture/annotation accuracy.
enum IndependentFramesDiagnostic {
    struct Input: Decodable {
        let schema_version: Int
        let source_sha256: String
        let source_window: String
        let nominal_fps: Double
        let width: Int, height: Int
        let stack_file: String, stack_sha256: String
        let background_policy: String
        let frame_pts: [Int64]
        let time_base_numerator: Int32, time_base_denominator: Int32
        let roi_xywh: [Int]?
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CourtError.message(message) }
    }
    static func child(_ relative: String, of root: URL) throws -> URL {
        try require(!relative.isEmpty && !relative.hasPrefix("/") && !relative.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }), "Invalid relative artifact path")
        let root = root.standardizedFileURL
        let target = root.appendingPathComponent(relative).standardizedFileURL
        try require(target.path.hasPrefix(root.path+"/"), "Artifact escaped its directory")
        var cursor = root
        for part in relative.split(separator:"/") {
            cursor.appendPathComponent(String(part))
            let values = try cursor.resourceValues(forKeys:[.isSymbolicLinkKey])
            try require(values.isSymbolicLink != true, "Symlink artifacts are not accepted")
        }
        return target
    }
    static func modelURL(_ directory: URL) throws -> (URL, String) {
        let assets = try IndependentBallModelAssets.load(directory: directory)
        return (assets.modelURL, assets.manifestSHA256)
    }
    static func run(_ args: [String]) throws {
        try require(args.count == 4, "Usage: court-analyze independent-frames FRAME_MANIFEST STAGED_MODEL_DIRECTORY NEW_OUTPUT_JSON")
        let inputURL = URL(fileURLWithPath:args[1]), directory = URL(fileURLWithPath:args[2]), output = URL(fileURLWithPath:args[3])
        try require(!FileManager.default.fileExists(atPath:output.path), "Output exists; choose a new path")
        let inputData = try Data(contentsOf:inputURL), input = try JSONDecoder().decode(Input.self,from:inputData)
        try require(input.schema_version == 1 && input.source_sha256.count == 64 && input.source_sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), "Invalid source frame manifest")
        try require(input.frame_pts.count == 8 && input.background_policy == "offline_frozen_native_rgb_median48", "Exactly8 real frames and explicit offline background are required")
        try require(input.width > 0 && input.height > 0 && input.width <= 4096 && input.height <= 4096, "Unsupported frame dimensions")
        let count = input.width*input.height*3
        try require(count*9 <= 512*1024*1024, "Offline RGB stack exceeds the diagnostic memory limit")
        let stackURL = try child(input.stack_file,of:inputURL.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath:stackURL.path)
        try require((attributes[.size] as? NSNumber)?.intValue == count*9, "RGB stack length mismatch")
        let stack = try Data(contentsOf:stackURL)
        try require(sha(stack) == input.stack_sha256, "RGB stack hash mismatch")
        let times = try input.frame_pts.map { try IndependentBallFrameTime(sourcePTS:$0,timeBaseNumerator:input.time_base_numerator,timeBaseDenominator:input.time_base_denominator) }
        let tracker = try IndependentCausalBallTracker(nominalFramesPerSecond:input.nominal_fps)
        // No temporal context is constructed across a source discontinuity.
        let seconds = input.frame_pts.map { Double($0)*Double(input.time_base_numerator)/Double(input.time_base_denominator) }
        for i in 1..<seconds.count {
            try require(seconds[i] > seconds[i-1] && seconds[i]-seconds[i-1] <= 1.5/input.nominal_fps,
                        "The8-frame model input crosses a source discontinuity")
        }
        let roi: IndependentBallROI?
        if let rect = input.roi_xywh {
            try require(rect.count == 4,"ROI must be integer x,y,width,height")
            roi = .init(x:rect[0],y:rect[1],width:rect[2],height:rect[3])
        } else { roi = nil }
        let transform = try IndependentBallImageTransform(originalWidth:input.width,originalHeight:input.height,
            cropX:roi?.x ?? 0,cropY:roi?.y ?? 0,cropWidth:roi?.width,cropHeight:roi?.height)
        func rgb(_ index: Int) throws -> IndependentRGB8Buffer {
            let lower = index*count
            let upper = lower+count
            let chunk = stack.subdata(in:lower..<upper)
            let ownedBytes: [UInt8] = Array(chunk)
            return try IndependentRGB8Buffer(width:input.width,height:input.height,bytesPerRow:input.width*3,bytes:ownedBytes,
                                             pixelFormat:.rgb8,coordinateSpace:.decodedTopLeftUnrotated)
        }
        let frames = try (1...8).map(rgb)
        let tensor = try IndependentBallPreprocessor.makeTensor(background:rgb(0),frames:frames,roi:roi)
        let (package,manifestSHA) = try modelURL(directory)
        let model = try IndependentBallModel(modelURL:package)
        let start = ProcessInfo.processInfo.systemUptime
        let prediction = try model.predict(nchw:tensor)
        let inferenceSeconds = ProcessInfo.processInfo.systemUptime-start
        let (_, afterManifestSHA) = try modelURL(directory)
        try require(afterManifestSHA == manifestSHA, "Model manifest changed during native inference")
        var rows: [[String:Any]] = []
        for index in 0..<8 {
            let heatmap = Array(prediction.heatmaps[index*512*288..<(index+1)*512*288])
            let bank = try IndependentBallCandidateBank.extract(heatmap,transform:transform)
            let choice = try tracker.select(candidates:bank.candidates,time:times[index],sourceID:input.source_sha256,transform:transform)
            let encoded = try JSONEncoder().encode(choice)
            var row = try JSONSerialization.jsonObject(with:encoded) as? [String:Any] ?? [:]
            if choice.candidate == nil { row["candidate"] = NSNull() }
            row["frame_index"] = index; row["source_pts"] = input.frame_pts[index]
            row["candidate_count"] = bank.totalComponents; row["retained_candidates"] = bank.candidates.count
            row["speed_kmh"] = NSNull(); row["speed_unavailable_reason"] = "No qualified camera calibration, collision-free flight and contact-time evidence"
            rows.append(row)
        }
        let tensorData = tensor.withUnsafeBufferPointer { Data(buffer:$0) }
        let heatmapData = prediction.heatmaps.withUnsafeBufferPointer { Data(buffer:$0) }
        let report: [String:Any] = ["schema_version":1,"pipeline":"native_owned_rgb_to_coreml_to_pixel_candidates_to_past_association_v1",
            "production":false,"physical_accuracy_validated":false,"speed_model_accepted":false,
            "input_manifest_sha256":sha(inputData),"source_sha256":input.source_sha256,"source_window":input.source_window,
            "model_manifest_sha256":manifestSHA,"decoded_video_in_this_command":false,
            "background_uses_future_frames":true,"model_input_frames":8,"tensor_sha256":sha(tensorData),"heatmaps_sha256":sha(heatmapData),
            "inference_seconds":inferenceSeconds,"candidate_threshold":0.3,"candidate_tie_rule":"peak_then_box_area_then_raster_seed_v1",
            "opencv_component_id_ties_exactly_reproduced":false,"speed_outputs":0,"frames":rows,
            "limitations":["Owned RGB frame adapter only; JPEG/video decoder equivalence is unverified.","Supplied offline background uses future frames.","No hit-event, calibrated3D or physical speed qualification.","Native past association is a development baseline with a declared raster tie rule."]]
        let bytes = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try bytes.write(to:output,options:.withoutOverwriting)
        print("INDEPENDENT_FRAMES_OK frames=8 speeds=0 output=\(output.path)")
    }
}
