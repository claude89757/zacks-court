import XCTest
import SwiftUI
import simd
@testable import CourtCore
@testable import CourtApp

/// Challenge replay geometry: the drawn flight goes through the hit and the bounce, the close view looks
/// at the judged line with the mark in frame, and ground polygons clip at the camera. Rendering is only
/// checked by eye (COURT_MAC_SNAPSHOTS=/path writes the frames); the picture is drawn from estimates.
final class HawkEyeReplayTests: XCTestCase {
    private func shot(bounce: (Double, Double), hit: TennisCourtPoint?, call: HawkEyeCall = .out, line: HawkEyeLine = .baseline,
                      distance: Double = 0.12, serve: Bool = false) -> TennisShotEvent {
        var e = TennisShotEvent(streamID: UUID(), sourcePTS: 10, stroke: serve ? .serve : .forehand, confidence: 0)
        e.hit = hit
        e.bounce = TennisBounceEstimate(sourcePTS: 10.9, xMeters: bounce.0, yMeters: bounce.1, confidence: 0)
        e.bounce?.sigmaXMeters = 0.04; e.bounce?.sigmaYMeters = 0.18
        e.bounce?.hawkEye = HawkEyeJudgement(call: call, distanceM: distance, marginM: 0.36, line: line, format: .singles, serve: serve, farHalf: bounce.1 > HawkEye.netY)
        return e
    }

    func testFlightRunsFromHitToBounceAndOn() throws {
        let hit = TennisCourtPoint(x: 5, y: 22.5, z: 1.0)
        let scene = try XCTUnwrap(HawkEyeReplayScene(event: shot(bounce: (4, -0.2), hit: hit)))
        let flight = try XCTUnwrap(scene.flight)
        XCTAssertEqual(flight.first!.y, 22.5, accuracy: 1e-9); XCTAssertEqual(flight.first!.z, 1.0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(flight[scene.bounceIndex], scene.bounce), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(flight.count, scene.bounceIndex + 1, "The ball goes on after the bounce")
        XCTAssertGreaterThan(flight[scene.bounceIndex / 2].z, 1.0, "An arc, not a line")
        XCTAssertTrue(flight.allSatisfy { $0.z >= HawkEye.ballRadius - 1e-9 })
        XCTAssertFalse(scene.fromNear, "Hit on the far half: the wide view looks from the far end")
        XCTAssertEqual(scene.lineAnchor.y, 0); XCTAssertEqual(scene.outward, SIMD3(0, -1, 0))
        XCTAssertNil(HawkEyeReplayScene(event: shot(bounce: (4, -0.2), hit: nil))?.flight, "No hit point: no flight")
        var unjudged = shot(bounce: (4, -0.2), hit: hit); unjudged.bounce?.hawkEye = nil
        XCTAssertNil(HawkEyeReplayScene(event: unjudged))
    }

    func testCloseViewFramesTheMarkAndTheLine() throws {
        let c = HawkEye.centreX
        for (bounce, line) in [((c + HawkEye.singlesHalfWidth + 0.1, 6.0), HawkEyeLine.sideline), ((c - 1, -0.15), .baseline),
                               ((c + 1, 23.9), .baseline), ((c - HawkEye.singlesHalfWidth - 0.1, 18.0), .sideline)] {
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: shot(bounce: bounce, hit: TennisCourtPoint(x: c, y: bounce.1 > 12 ? 1 : 22, z: 1), line: line)))
            let cam = scene.closeCamera
            let mark = try XCTUnwrap(cam.project(scene.bounce, width: 1000, height: 600))
            let anchor = try XCTUnwrap(cam.project(scene.lineAnchor, width: 1000, height: 600))
            for p in [mark, anchor] {
                XCTAssertTrue((100...900).contains(p.x) && (60...540).contains(p.y), "\(line) at \(bounce): \(p)")
            }
            let wide = scene.wideCamera
            for corner in [SIMD3(0.0, 0, 0), SIMD3(HawkEye.width, 0, 0), SIMD3(0, HawkEye.length, 0), SIMD3(HawkEye.width, HawkEye.length, 0)] {
                let p = try XCTUnwrap(wide.project(corner, width: 1000, height: 600))
                XCTAssertTrue((-1...1001).contains(p.x) && (-1...601).contains(p.y), "Whole court in the wide view: \(p)")
            }
        }
    }

    func testGroundPolygonsClipAtTheCamera() {
        let cam = HawkEyeCamera(position: SIMD3(5, 5, 1), target: SIMD3(5, 8, 0), fovDegrees: 40)
        let court = [SIMD3(0.0, 0, 0), SIMD3(10.97, 0, 0), SIMD3(10.97, 23.77, 0), SIMD3(0, 23.77, 0)]
        let clipped = cam.polygon(court, width: 800, height: 450)
        XCTAssertGreaterThanOrEqual(clipped.count, 3, "The part in front of the camera stays")
        XCTAssertTrue(clipped.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let behind = [SIMD3(0.0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 2, 0), SIMD3(0, 2, 0)]
        XCTAssertTrue(cam.polygon(behind, width: 800, height: 450).isEmpty, "Wholly behind: nothing")
    }

    /// Frames of the replay as PNGs, for review only.
    @MainActor func testRenderFrames() throws {
        guard let folder = ProcessInfo.processInfo.environment["COURT_MAC_SNAPSHOTS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw XCTSkip("Set COURT_MAC_SNAPSHOTS=/path to render the replay frames")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let c = HawkEye.centreX
        let cases: [(String, TennisShotEvent)] = [
            ("out-baseline", shot(bounce: (c - 1.2, -0.16), hit: TennisCourtPoint(x: c + 1, y: 23, z: 1.1), distance: 0.127)),
            ("in-sideline", shot(bounce: (c + HawkEye.singlesHalfWidth - 0.35, 4.0), hit: TennisCourtPoint(x: c - 1, y: 22, z: 1), call: .in, line: .sideline, distance: -0.32)),
            ("close-service", shot(bounce: (c - 2, HawkEye.netY - HawkEye.serviceFromNet + 0.02), hit: TennisCourtPoint(x: c + 2, y: 24, z: 2.7), call: .close, line: .serviceLine, distance: -0.05, serve: true)),
        ]
        for (name, event) in cases {
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: event))
            let timing = HawkEyeReplayTiming(hasFlight: scene.flight != nil)
            for (label, t) in [("1-flight", timing.title + 1.2), ("2-zoom", timing.flightEnd + 0.7), ("3-mark", timing.total)] {
                let frame = timing.frame(t, scene: scene)
                let view = Canvas { gc, size in HawkEyeReplayPainter(scene: scene, frame: frame).paint(&gc, size: size) }
                    .frame(width: 960, height: 540)
                let renderer = ImageRenderer(content: view); renderer.scale = 1
                let image = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try image.write(to: folder.appendingPathComponent("hawkeye-\(name)-\(label).png"))
            }
        }
    }
}
