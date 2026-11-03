// Body pose (Apple Vision) at given frames, for stroke-side features (not used by the current rules).
// The second crop is the double-test-003 near court; change it per court.
// usage: swift pose.swift VIDEO FRAMES_FILE OUT_JSON
// FRAMES_FILE: one integer per line, in 1/60 s units of presentation time.
// Output: {"<frame>": [{"box":[x0,y0,x1,y1], "joints":{"rightWrist":[x,y,conf], ...}}, ...]} top-left pixels.
import AVFoundation
import Foundation
import Vision

let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let frames = try! String(contentsOfFile: args[2], encoding: .utf8)
    .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.appliesPreferredTrackTransform = true
let names: [VNHumanBodyPoseObservation.JointName: String] = [
    .leftWrist: "leftWrist", .rightWrist: "rightWrist", .leftElbow: "leftElbow", .rightElbow: "rightElbow",
    .leftShoulder: "leftShoulder", .rightShoulder: "rightShoulder", .leftHip: "leftHip", .rightHip: "rightHip",
    .neck: "neck", .root: "root", .nose: "nose", .leftAnkle: "leftAnkle", .rightAnkle: "rightAnkle",
]
var out: [String: [[String: Any]]] = [:]
for f in frames {
    let t = CMTime(value: CMTimeValue(f * 10), timescale: 600)
    guard let img = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
    var people: [[String: Any]] = []
    for (cx, cy, cw, ch) in [(0, 0, img.width, img.height), (560, 400, 800, 320)] {
        guard let crop = img.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else { continue }
        let W = Double(crop.width), H = Double(crop.height)
        let req = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
        for o in req.results ?? [] {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            var joints: [String: [Double]] = [:]
            var xs: [Double] = [], ys: [Double] = []
            for (k, name) in names {
                guard let p = pts[k], p.confidence > 0.1 else { continue }
                let x = Double(cx) + Double(p.location.x) * W, y = Double(cy) + (1 - Double(p.location.y)) * H
                joints[name] = [x, y, Double(p.confidence)]; xs.append(x); ys.append(y)
            }
            if xs.count < 4 { continue }
            people.append(["box": [xs.min()!, ys.min()!, xs.max()!, ys.max()!], "joints": joints, "crop": cw == img.width ? 0 : 1])
        }
    }
    out[String(f)] = people
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try! data.write(to: URL(fileURLWithPath: args[3]))
print("frames", out.count)
