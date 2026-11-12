import CoreML
import XCTest
import simd
@testable import CourtCore

/// Keypoint starts for the court calibration. Synthetic: they prove the geometry and that keypoints only
/// add starts behind the same refusal checks, not how well the keypoint model does on real courts.
final class IndependentCourtKeypointsTests: XCTestCase {
    static let camera = IndependentCourtCalibratorTests.camera

    static func project(_ camera: IndependentPinholeCamera, noise: Double = 0, seed: UInt64 = 3) -> IndependentCourtKeypoints {
        let P = IndependentProjector(camera)
        var rng = SplitMix(seed: seed)
        func jitter() -> Double { noise * (Double(rng.next() % 2001) / 1000 - 1) }
        return IndependentCourtKeypoints(pixels: IndependentCourtKeypoints.court.map { c in
            let p = P.project(SIMD3(c.x, c.y, 0))
            guard p.u >= 0, p.u < 1920, p.v >= 0, p.v < 1080 else { return nil }
            return SIMD2(p.u + jitter(), p.v + jitter())
        })
    }

    func testKeypointsGiveTheCamera() throws {
        let starts = Self.project(Self.camera).hypotheses()
        let best = try XCTUnwrap(starts.first)
        XCTAssertEqual(best.camera.f, Self.camera.f, accuracy: 0.005 * Self.camera.f)
        XCTAssertLessThan(simd_length(best.camera.C - Self.camera.centre), 0.05)
        XCTAssertLessThan(best.error, 0.01)
    }

    func testOneWrongKeypointIsLeftOut() throws {
        var k = Self.project(Self.camera, noise: 2)
        k.pixels[12] = k.pixels[12].map { $0 + SIMD2(180, -60) }      // near T point far off
        let best = try XCTUnwrap(k.hypotheses().first)
        XCTAssertLessThan(simd_length(best.camera.C - Self.camera.centre), 0.3)
        XCTAssertEqual(best.camera.f, Self.camera.f, accuracy: 0.03 * Self.camera.f)
    }

    func testTooFewKeypointsGiveNothing() {
        var k = Self.project(Self.camera)
        for i in 3..<k.pixels.count { k.pixels[i] = nil }
        XCTAssertTrue(k.hypotheses().isEmpty)
    }

    /// With the line search crippled (one longitudinal line allowed, so no 2 x 2 combination exists) the
    /// calibration refuses; noisy keypoints give a start that the line refinement turns into the camera,
    /// passing the same checks.
    func testKeypointStartFindsCourtTheLineSearchMisses() throws {
        let image = try CourtRenderer(camera: Self.camera).render()
        var crippled = IndependentCourtCalibrator.Options()
        crippled.maxLongitudinal = 1
        XCTAssertEqual(IndependentCourtCalibrator.calibrate(image, options: crippled).refusals, [.noPlausibleCombination])
        let result = IndependentCourtCalibrator.calibrate(image, options: crippled, keypoints: Self.project(Self.camera, noise: 4))
        XCTAssertTrue(result.found, "refusals: \(result.refusals)")
        XCTAssertTrue(result.startedFromKeypoints)
        XCTAssertGreaterThan(result.counts.fromKeypoints, 0)
        let (mean, maximum) = IndependentCourtCalibratorTests.referencePointError(try XCTUnwrap(result.camera), Self.camera)
        XCTAssertLessThan(mean, 0.5); XCTAssertLessThan(maximum, 1.5)
    }

    /// Keypoints of another camera position cannot make the calibration return a wrong court: the
    /// refinement either converges onto the painted lines or the start is refused.
    func testWrongKeypointsDoNotGiveAWrongCourt() throws {
        let image = try CourtRenderer(camera: Self.camera).render()
        var crippled = IndependentCourtCalibrator.Options()
        crippled.maxLongitudinal = 1
        let other = IndependentPinholeCamera.lookingAt(SIMD3(1.5, 10, 0), from: SIMD3(2.5, -8, 4.5), f: 1400)
        let result = IndependentCourtCalibrator.calibrate(image, options: crippled, keypoints: Self.project(other))
        if let cam = result.camera {
            XCTAssertLessThan(IndependentCourtCalibratorTests.referencePointError(cam, Self.camera).1, 1.5)
        }
    }

    /// Heatmap decoding: the 3×3 weighted peak maps back to full-resolution pixels; weak peaks are unseen.
    func testHeatmapDecoding() throws {
        let K = IndependentCourtKeypoints.names.count, H = IndependentCourtKeypointModel.outputHeight, W = IndependentCourtKeypointModel.outputWidth
        let m = try MLMultiArray(shape: [1, NSNumber(value: K), NSNumber(value: H), NSNumber(value: W)], dataType: .float32)
        let p = m.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(K * H * W) { p[i] = 0 }
        // channel 0: symmetric peak at (100, 50) shifted a quarter cell right
        p[0 * H * W + 50 * W + 100] = 0.9; p[0 * H * W + 50 * W + 101] = 0.45; p[0 * H * W + 50 * W + 99] = 0.15
        p[1 * H * W + 10 * W + 10] = 0.1                                   // channel 1: too weak
        let k = IndependentCourtKeypointModel.decode(m, fullWidth: 1920)
        let u = try XCTUnwrap(k.pixels[0])
        let fx: Double = 100 + (0.45 - 0.15) / (0.9 + 0.45 + 0.15)
        XCTAssertEqual(u.x, (fx * 2 + 0.5) * 3.75, accuracy: 1e-3)
        XCTAssertEqual(u.y, (50 * 2 + 0.5) * 3.75, accuracy: 1e-3)
        XCTAssertNil(k.pixels[1])
    }
}
