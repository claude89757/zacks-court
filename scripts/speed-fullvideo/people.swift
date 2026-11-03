// Detect people in video frames with Apple Vision.
// usage: swift people.swift VIDEO FRAMES_FILE OUT_JSON [CROPS_JSON]
// FRAMES_FILE: one integer per line, in 1/60 s units of presentation time.
// Output: {"<frame>": [[x0, y0, x1, y1, confidence, fromCrop, cropBottom], ...]} in top-left pixels.
import AVFoundation
import Foundation
import Vision

let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let frames = try! String(contentsOfFile: args[2], encoding: .utf8)
    .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
// optional 4th argument: JSON list of [x, y, w, h] crops (default: crops for the double-test-003 court)
var crops: [(Int, Int, Int, Int)] = [(560, 420, 800, 300), (640, 500, 320, 160), (900, 500, 320, 160), (1100, 500, 320, 160)]
if args.count > 4, let d = FileManager.default.contents(atPath: args[4]),
   let list = try? JSONSerialization.jsonObject(with: d) as? [[Int]] {
    crops = list.map { ($0[0], $0[1], $0[2], $0[3]) }
}
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.appliesPreferredTrackTransform = true
var out: [String: [[Double]]] = [:]
for f in frames {
    let t = CMTime(value: CMTimeValue(f * 10), timescale: 600)
    guard let img = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
    var boxes: [[Double]] = []
    // full frame (near players) and an upscaled far-court crop (far players are ~40x90 px)
    for (cx, cy, cw, ch) in [(0, 0, img.width, img.height)] + crops {
        guard let crop = img.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else { continue }
        let W = Double(crop.width), H = Double(crop.height)
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([req])
        for o in req.results ?? [] {
            let b = o.boundingBox
            boxes.append([Double(cx) + b.minX * W, Double(cy) + (1 - b.maxY) * H, Double(cx) + b.maxX * W, Double(cy) + (1 - b.minY) * H, Double(o.confidence), cw == img.width ? 0 : 1, Double(cy + ch)])
        }
    }
    out[String(f)] = boxes
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try! data.write(to: URL(fileURLWithPath: args[3]))
print("frames", out.count)
