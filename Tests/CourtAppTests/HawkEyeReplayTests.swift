import XCTest
import SwiftUI
import simd
@testable import CourtCore
@testable import CourtApp

/// Challenge replay geometry: the drawn flight goes through the hit and the bounce, the overhead shot
/// frames the gap below the verdict and measures what the verdict says, and ground polygons clip at the
/// camera. Rendering is only
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

    /// 2026-11-06: a fitted contact far outside the court cannot drive the replay arc (the in-house chain
    /// fits such points on more than half of its rows), so the replay falls back to the bounce alone.
    func testAnImpossibleHitPointDoesNotDrawAFlight() throws {
        let good = TennisCourtPoint(x: 5, y: 22.5, z: 1.0)
        XCTAssertNotNil(HawkEyeReplayScene(event: shot(bounce: (4, -0.2), hit: good))?.flight)
        for bad in [TennisCourtPoint(x: 5 + 8, y: 22.5, z: 1.0),      // far past the doubles sideline
                    TennisCourtPoint(x: 5, y: 60, z: 1.0),            // behind the back fence
                    TennisCourtPoint(x: 5, y: 22.5, z: 9)] {          // nine metres up
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: shot(bounce: (4, -0.2), hit: bad)))
            XCTAssertNil(scene.flight, "no arc from \(bad)")
            XCTAssertEqual(scene.bounce.y, -0.2, accuracy: 1e-9, "the bounce is still replayed")
        }
    }

    private func judged(_ x: Double, _ y: Double, hit: TennisCourtPoint, sx: Double = 0.045, sy: Double = 0.2, serve: Bool = false) -> TennisShotEvent {
        var e = TennisShotEvent(streamID: UUID(), sourcePTS: 10, stroke: serve ? .serve : .forehand, confidence: 0)
        e.hit = hit
        e.bounce = TennisBounceEstimate(sourcePTS: 10.9, xMeters: x, yMeters: y, confidence: 0)
        e.bounce?.sigmaXMeters = sx; e.bounce?.sigmaYMeters = sy
        return HawkEye.annotate(e, settings: HawkEyeSettings(enabled: true, format: .singles, farHalf: true))
    }
    private var cases: [TennisShotEvent] {
        let c = HawkEye.centreX, s = HawkEye.singlesHalfWidth, net = HawkEye.netY
        return [
            judged(c + s + 0.15, 3.2, hit: TennisCourtPoint(x: c - 1, y: 23, z: 1)),             // out, sideline
            judged(c - s + 0.25, 4.0, hit: TennisCourtPoint(x: c + 1, y: 23, z: 1)),             // in, sideline
            judged(c + 1.3, 0.06, hit: TennisCourtPoint(x: c - 0.5, y: 23, z: 1)),               // close, baseline
            judged(c - 1.2, -0.55, hit: TennisCourtPoint(x: c + 1, y: 23, z: 1)),                // out, baseline
            judged(c + 1.5, 6.5, hit: TennisCourtPoint(x: c - 2, y: 23, z: 1)),                  // in by metres
            judged(c - s - 0.35, 19, hit: TennisCourtPoint(x: c + 1, y: 0.5, z: 1), sx: 0.06, sy: 0.5),  // far, out
            judged(c + 1, HawkEye.length + 0.6, hit: TennisCourtPoint(x: c, y: 1, z: 1), sy: 0.4),       // far baseline
            judged(c + s + 0.3, -0.4, hit: TennisCourtPoint(x: c - 1, y: 23, z: 1)),             // past the corner
            judged(c + 0.2, net - 3, hit: TennisCourtPoint(x: c - 1.2, y: 24.2, z: 2.7), sx: 0.04, serve: true),  // centre line, in
        ]
    }

    /// The overhead shot keeps the line, the footprint and the bar in the lower part of the picture, clear
    /// of the verdict across the top, on wide and tall screens alike; the opening view has the hit and
    /// the bounce in frame.
    func testOverheadShotFramesTheGapBelowTheVerdict() throws {
        for event in cases {
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: event)), j = scene.judgement
            for aspect in [2.5, 16.0 / 9, 0.75] {
                let w = 600 * aspect, h = 600.0, cam = scene.measureCamera(aspect: aspect)
                var points = [scene.bounce, scene.lineAnchor]
                if let m = scene.measure { points += [m.from, m.to] }
                for p in points {
                    let q = try XCTUnwrap(cam.project(p, width: w, height: h))
                    XCTAssertTrue((0.08 * w...0.92 * w).contains(q.x) && (0.28 * h...0.97 * h).contains(q.y), "\(j.call) \(j.line) at \(aspect): \(q)")
                }
                // out is up the picture, the line runs across it
                let a = try XCTUnwrap(cam.project(scene.lineAnchor, width: w, height: h))
                let o = try XCTUnwrap(cam.project(scene.lineAnchor + scene.outward * 0.1, width: w, height: h))
                XCTAssertLessThan(o.y, a.y); XCTAssertLessThan(abs(o.x - a.x), abs(o.y - a.y))
            }
            let open = scene.openingCamera
            for p in [scene.flight!.first!, scene.bounce] {
                let q = try XCTUnwrap(open.project(p, width: 1000, height: 600))
                XCTAssertTrue((0...1000).contains(q.x) && (0...600).contains(q.y), "Opening view: \(q)")
            }
        }
    }

    /// The bar is as long as the number on the verdict, from the edge of the line the eye compares with.
    func testMeasureMatchesTheVerdict() throws {
        for event in cases {
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: event)), j = scene.judgement
            guard let m = scene.measure else {
                XCTAssertTrue(j.call == .close || j.visibleGapM == 0, "\(j)"); continue
            }
            XCTAssertEqual(simd_distance(m.from, m.to), m.metres, accuracy: 1e-9)
            XCTAssertEqual(m.metres, try XCTUnwrap(j.visibleGapM), accuracy: 1e-9, "\(j.call) \(j.line)")
            let edge = simd_dot((j.call == .out ? m.from : m.to) - scene.lineAnchor, scene.outward)
            XCTAssertEqual(edge, j.call == .out ? 0 : -j.line.paintedWidth, accuracy: 1e-9)
            XCTAssertTrue(j.detailText.contains("\(Int((m.metres * 100).rounded())) 厘米"), j.detailText)
        }
    }

    func testInCallsGiveTheGapTheEyeSees() {
        let c = HawkEye.centreX, s = HawkEye.singlesHalfWidth
        let wide = judged(c - s + 0.25, 4.0, hit: TennisCourtPoint(x: c + 1, y: 23, z: 1)).lineCall!
        XCTAssertEqual(wide.call, .in)
        XCTAssertEqual(wide.distanceM, -0.283, accuracy: 1e-9, "The call still measures to the footprint's far side")
        XCTAssertEqual(wide.visibleGapM!, 0.25 - 0.033 - 0.05, accuracy: 1e-9)
        XCTAssertEqual(wide.detailText, "界内 · 距边线约 17 厘米")
        let touching = judged(c + s - 0.06, 6.0, hit: TennisCourtPoint(x: c - 2, y: 23.5, z: 1), sx: 0.02).lineCall!
        XCTAssertEqual(touching.call, .in); XCTAssertEqual(touching.visibleGapM, 0)
        XCTAssertEqual(touching.detailText, "界内 · 球印压在边线上")
    }

    /// A serve judged against the centre line: the outer edge is the side facing the other box, whether
    /// the ball stayed in its box or crossed over.
    func testCentreLineFacesTheOtherBox() throws {
        let c = HawkEye.centreX, net = HawkEye.netY, server = TennisCourtPoint(x: c - 1.2, y: 24.2, z: 2.7)  // to the right box
        for x in [c + 0.2, c - 0.3] {
            let scene = try XCTUnwrap(HawkEyeReplayScene(event: judged(x, net - 3, hit: server, sx: 0.04, serve: true)))
            XCTAssertEqual(scene.judgement.line, .centreLine)
            XCTAssertEqual(scene.lineAnchor.x, c - HawkEye.centreLineHalfWidth, accuracy: 1e-9)
            XCTAssertEqual(scene.outward, SIMD3(-1, 0, 0))
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
            for (label, t) in [("1-flight", timing.title + 1.2), ("2-landed", timing.settled), ("3-overhead", timing.total)] {
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
