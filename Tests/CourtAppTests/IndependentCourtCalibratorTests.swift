import XCTest
import simd
@testable import CourtCore

/// Synthetic checks of the automatic court calibration. The court is rendered from a known camera with
/// the same line model the fit uses, so these prove the code path and the geometry, not accuracy on real
/// courts; parity with the Python prototype on real medians is recorded in docs/verification.md.
final class IndependentCourtCalibratorTests: XCTestCase {
    static let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150)

    // MARK: end to end

    func testRecoversRenderedCourtCamera() throws {
        let image = try CourtRenderer(camera: Self.camera).render()
        let result = IndependentCourtCalibrator.calibrate(image)
        XCTAssertTrue(result.found, "refusals: \(result.refusals)")
        XCTAssertEqual(result.quality, .good)
        XCTAssertEqual(Set(result.linesUsed), Set(IndependentCourtLine.fitted))
        let cam = try XCTUnwrap(result.camera)
        XCTAssertEqual(cam.f, Self.camera.f, accuracy: 0.01 * Self.camera.f)
        XCTAssertLessThan(simd_length(cam.centre - Self.camera.centre), 0.05)
        let (mean, maximum) = Self.referencePointError(cam, Self.camera)
        XCTAssertLessThan(mean, 0.5, "mean reference-point error in px")
        XCTAssertLessThan(maximum, 1.5, "max reference-point error in px")
        XCTAssertLessThan(try XCTUnwrap(result.fitRMS), 0.5)
        XCTAssertLessThan(try XCTUnwrap(result.focalLengthSD), 3)
        XCTAssertNil(result.principalOffset, "a centred camera keeps the centred fit")
    }

    /// A phone filming a screen whose picture sits 85 px right of the image centre (iPhone, 2026-11-04):
    /// the centred fit leaves every line a few px off and is refused; stage 6 frees the horizontal
    /// principal coordinate and finds the camera with the same gates.
    func testFindsCameraWithOffCentrePrincipalPoint() throws {
        let c = Self.camera
        let shifted = IndependentPinholeCamera(f: c.f, rvec: c.rvec, tvec: c.tvec, principal: [1045, 540])
        let image = try CourtRenderer(camera: shifted).render()
        var centredOnly = IndependentCourtCalibrator.Options()
        centredOnly.freePrincipalPixels = nil
        XCTAssertFalse(IndependentCourtCalibrator.calibrate(image, options: centredOnly).found)

        let result = IndependentCourtCalibrator.calibrate(image)
        XCTAssertTrue(result.found, "refusals: \(result.refusals)")
        XCTAssertEqual(try XCTUnwrap(result.principalOffset), 85, accuracy: 5)
        let cam = try XCTUnwrap(result.camera)
        XCTAssertEqual(cam.principal[0], 960 + result.principalOffset!, accuracy: 1e-9)
        XCTAssertEqual(cam.f, c.f, accuracy: 0.01 * c.f)
        XCTAssertLessThan(simd_length(cam.centre - c.centre), 0.1)
        let (mean, maximum) = Self.referencePointError(cam, shifted)
        XCTAssertLessThan(mean, 0.5, "mean reference-point error in px")
        XCTAssertLessThan(maximum, 1.5, "max reference-point error in px")
        // refining from the found camera keeps its principal point (the live tracker's path)
        let again = try XCTUnwrap(IndependentCourtCalibrator.refine(image, start: IndependentCourtCalibrator.parameters(cam)))
        XCTAssertEqual(again.camera.principal[0], cam.principal[0], accuracy: 2)
    }

    /// With the near baseline painted over, focal length and distance trade off; the solve must refuse
    /// rather than return a camera (the prototype refuses all five such masked medians).
    func testRefusesWhenNearBaselineIsHidden() throws {
        let result = IndependentCourtCalibrator.calibrate(try Self.renderWithoutNearBaseline(poleSpacing: 480))
        XCTAssertFalse(result.found)
        XCTAssertNil(result.camera)
        XCTAssertNil(result.quality)
        XCTAssertTrue(result.refusals.contains(.onlyOneTransverseLine), "refusals: \(result.refusals)")
        XCTAssertFalse(result.linesUsed.contains(.nearBaseline))
    }

    /// Eight long, parallel poles above the horizon out-vote the shortened sidelines and capture the
    /// vanishing point (a limit of the prototype's vote, kept as is); the solve still refuses.
    func testDenseVerticalClutterStillRefuses() throws {
        let result = IndependentCourtCalibrator.calibrate(try Self.renderWithoutNearBaseline(poleSpacing: 240))
        XCTAssertFalse(result.found)
        XCTAssertNil(result.camera)
        XCTAssertEqual(result.refusals, [.noPlausibleCombination])
        XCTAssertEqual(result.counts.transverseBelowHorizon, 0)
    }

    static func renderWithoutNearBaseline(poleSpacing: Int) throws -> IndependentCourtImage {
        let P = IndependentProjector(camera)
        let left = P.project(SIMD3(-5.46, 0.05, 0)), right = P.project(SIMD3(5.46, 0.05, 0))
        return try CourtRenderer(camera: camera, poleSpacing: poleSpacing).render { x, y in
            let yLine = left.v + (Double(x) - left.u) * (right.v - left.v) / (right.u - left.u)
            return Double(y) > yLine - 25
        }
    }

    func testRejectsOtherImageSizes() throws {
        let plane = [UInt8](repeating: 90, count: 64 * 36)
        let image = try IndependentCourtImage(width: 64, height: 36, blue: plane, green: plane, red: plane)
        let result = IndependentCourtCalibrator.calibrate(image)
        XCTAssertEqual(result.refusals, [.unsupportedImage])
        XCTAssertNil(result.camera)
    }

    func testRefusalsHaveChineseMessages() {
        for r in IndependentCourtCalibration.Refusal.allCases {
            XCTAssertFalse(r.message.isEmpty)
            XCTAssertTrue(r.message.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, r.rawValue)
        }
        XCTAssertEqual(IndependentCourtCalibration.Refusal.onlyOneTransverseLine.message, "近端底线和发球线都要在画面里")
    }

    // MARK: stages

    func testClosedFormCameraFromHomography() {
        let cam = Self.camera
        let H = IndependentCourtSearch.homography(f: cam.f, R: cam.rotation, t: cam.translation, cx: 960, cy: 540)
        let scale = 3.7   // a homography is only defined up to scale
        let p = IndependentCourtSearch.pinhole(H.map { $0 * scale }, cx: 960, cy: 540, gateOnly: false)!
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.f, cam.f, accuracy: 1e-6)
        XCTAssertLessThan(simd_length(p.C - cam.centre), 1e-9)
        XCTAssertLessThan(p.cos, 1e-9)
        XCTAssertTrue(IndependentCourtSearch.passes(p))
        // the opposite sign of H describes the same camera
        let q = IndependentCourtSearch.pinhole(H.map { -$0 }, cx: 960, cy: 540, gateOnly: false)!
        XCTAssertLessThan(simd_length(q.C - cam.centre), 1e-9)
    }

    func testMedianMatchesSortedSelection() throws {
        var rng = SplitMix(seed: 7)
        for n in [1, 2, 3, 4, 5, 8, 9, 25] {
            let frames = try (0..<n).map { _ in
                try IndependentCourtImage(width: 7, height: 5, blue: (0..<35).map { _ in rng.byte() },
                                          green: (0..<35).map { _ in rng.byte() }, red: (0..<35).map { _ in rng.byte() })
            }
            let m = try IndependentCourtMedian.median(of: frames)
            for i in 0..<35 {
                let s = frames.map { Int($0.green[i]) }.sorted()
                let want = n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2   // np.median(...).astype(uint8)
                XCTAssertEqual(Int(m.green[i]), want, "n=\(n) i=\(i)")
            }
        }
        XCTAssertThrowsError(try IndependentCourtMedian.median(of: []))
    }

    /// NumPy's default argsort is not stable; its order on equal keys decides which tied hypothesis is
    /// refined. Reference order from NumPy 2.5 (arm64).
    func testArgsortReproducesNumPyTieOrder() {
        let v: [Double] = [3, 1, 2, 1, 3, 2, 1, 0, 2, 2, 3, 1, 0, 0, 1, 2, 3, 3, 1, 2, 0, 1, 1, 2, 3, 0, 2, 1, 3, 2, 2, 1, 0, 3, 1, 2, 1, 1, 0, 2]
        XCTAssertEqual(NumPy.argsort(v), [12, 20, 38, 13, 32, 7, 25, 34, 36, 31, 11, 22, 3, 14, 6, 21, 27, 18, 37, 1, 35, 30, 26, 29,
                                          19, 39, 23, 15, 9, 8, 5, 2, 17, 28, 16, 10, 33, 4, 24, 0])
        let keys = (0..<500).map { Double(($0 * 7919) % 997) }
        XCTAssertEqual(NumPy.argsort(keys).map { keys[$0] }, keys.sorted())
    }

    /// Direction and sign of NumPy's `svd(...)[2][0]` (LAPACK dgesdd) on centred points.
    func testPrincipalDirectionFollowsLAPACKSign() {
        let c: [SIMD2<Double>] = [SIMD2(-25.0, -7.549685), SIMD2(-18.75, -5.409574), SIMD2(-12.5, -3.561579), SIMD2(-6.25, -2.033585),
                                  SIMD2(0.0, -0.116117), SIMD2(6.25, 1.713), SIMD2(12.5, 3.807422), SIMD2(18.75, 5.557264), SIMD2(25.0, 7.592854)]
        let cases: [([SIMD2<Double>], SIMD2<Double>)] = [
            (c, SIMD2(0.9582035959712435, 0.28608716970143566)),
            (c.map { -$0 }, SIMD2(-0.9582035959712435, -0.28608716970143566)),
            (c.map { SIMD2($0.y, -$0.x) }, SIMD2(0.2860871697014356, -0.9582035959712435)),
            (c.map { SIMD2(-$0.x, $0.y) }, SIMD2(-0.9582035959712435, 0.28608716970143566)),
        ]
        for (points, want) in cases {
            XCTAssertLessThan(simd_length(IndependentCourtRefine.principalDirection(points) - want), 1e-12)
        }
    }

    func testHoughFindsDrawnLines() {
        let w = 200, h = 120
        var img = [UInt8](repeating: 0, count: w * h)
        for x in 20..<180 { img[60 * w + x] = 1 }
        for k in 0..<80 { img[(20 + k) * w + 30 + k] = 1 }
        let segs = IndependentCourtHough.segments(img, width: w, height: h)
        func covers(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            segs.contains { s in
                let p = SIMD2(Double(s.x0), Double(s.y0)), q = SIMD2(Double(s.x1), Double(s.y1))
                return (simd_length(p - a) < 3 && simd_length(q - b) < 3) || (simd_length(p - b) < 3 && simd_length(q - a) < 3)
            }
        }
        XCTAssertTrue(covers(SIMD2(20, 60), SIMD2(179, 60)), "\(segs)")
        XCTAssertTrue(covers(SIMD2(30, 20), SIMD2(109, 99)), "\(segs)")
        XCTAssertEqual(IndependentCourtHough.angleCount(theta: Double(Float(Double.pi / 360))), 360)
    }

    func testEvidenceUsesOpenCVRounding() {
        // INTER_AREA at 2x rounds half up: (a + b + c + d + 2) >> 2
        XCTAssertEqual(IndependentCourtEvidence.halve([1, 1, 0, 0], 2, 2), [1])
        XCTAssertEqual(IndependentCourtEvidence.halve([1, 0, 0, 0], 2, 2), [0])
        XCTAssertEqual(IndependentCourtEvidence.halve([3, 3, 2, 2], 2, 2), [3])
        var v = [UInt8](repeating: 0, count: 1000)
        for i in 995..<1000 { v[i] = 200 }
        XCTAssertEqual(IndependentCourtEvidence.percentile995(v), 200 * 0.005 + 0, accuracy: 1e-3)   // index 994.005 lerps 0 -> 200
        // a thin bright line survives the top-hat; a wide bright patch does not
        let w = 40, h = 40
        var plane = [UInt8](repeating: 50, count: w * h)
        for y in 0..<h { plane[y * w + 10] = 200; plane[y * w + 11] = 200 }
        for y in 0..<h { for x in 20..<40 { plane[y * w + x] = 200 } }
        let th = IndependentCourtEvidence.topHat(plane, w, h, kernel: 11)
        XCTAssertEqual(th[20 * w + 10], 150)
        XCTAssertEqual(th[20 * w + 30], 0)
    }

    // MARK: helpers

    static func referencePointError(_ a: IndependentPinholeCamera, _ b: IndependentPinholeCamera) -> (mean: Double, max: Double) {
        let pa = IndependentProjector(a), pb = IndependentProjector(b)
        var errs = [Double]()
        for (_, X) in IndependentCourtModel.referencePoints {
            let q = pb.project(X)
            guard q.u >= 0, q.u < 1920, q.v >= 0, q.v < 1080 else { continue }
            let p = pa.project(X)
            errs.append(hypot(p.u - q.u, p.v - q.v))
        }
        return (errs.reduce(0, +) / Double(errs.count), errs.max() ?? 0)
    }
}

/// Renders a hard court (painted lines at their ITF widths, 2 x 2 supersampled) seen by a pinhole camera,
/// with a green surround, a sky band with bright poles and rails as clutter above the horizon, and noise.
struct CourtRenderer {
    let camera: IndependentPinholeCamera
    var poleSpacing = 480
    var width = 1920, height = 1080, seed: UInt64 = 1

    func render(masked: ((Int, Int) -> Bool)? = nil) throws -> IndependentCourtImage {
        let R = camera.rotation, t = camera.translation, f = camera.f
        let cx = camera.principal[0], cy = camera.principal[1]
        let H = simd_double3x3(rows: [SIMD3(f * R[0][0] + cx * R[0][2], f * R[1][0] + cx * R[1][2], f * t.x + cx * t.z),
                                      SIMD3(f * R[0][1] + cy * R[0][2], f * R[1][1] + cy * R[1][2], f * t.y + cy * t.z),
                                      SIMD3(R[0][2], R[1][2], t.z)])
        let Hi = H.inverse
        let n = width * height
        var b = [UInt8](repeating: 0, count: n), g = b, r = b
        var rng = SplitMix(seed: seed)
        let court = SIMD3<Double>(150, 110, 70), line = SIMD3<Double>(235, 235, 230), surround = SIMD3<Double>(80, 120, 90)
        let sky = SIMD3<Double>(170, 165, 160), pole = SIMD3<Double>(240, 240, 240)
        for y in 0..<height {
            for x in 0..<width {
                var c = SIMD3<Double>.zero
                for (ox, oy) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                    let p = Hi * SIMD3(Double(x) + ox, Double(y) + oy, 1)
                    if p.z <= 0 {
                        let bright = (x % poleSpacing < 5) || (y % 60 < 3 && y < 300)
                        c += bright ? pole : sky
                        continue
                    }
                    let X = p.x / p.z, Y = p.y / p.z
                    if Self.painted(X, Y) { c += line }
                    else if abs(X) < 9 && Y > -6.5 && Y < 30.3 { c += court }
                    else { c += surround }
                }
                c /= 4
                if let masked, masked(x, y) { c = court }
                let k = y * width + x
                func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v + Double(rng.next() % 13) - 6).rounded()))) }
                b[k] = q(c.x); g[k] = q(c.y); r[k] = q(c.z)
            }
        }
        return try IndependentCourtImage(width: width, height: height, blue: b, green: g, red: r)
    }

    /// Painted lines in court coordinates: baselines 10 cm, other lines 5 cm, centre mark 10 cm long.
    static func painted(_ x: Double, _ y: Double) -> Bool {
        let ax = abs(x)
        if ax <= 5.485 && (abs(y - 0.05) <= 0.05 || abs(y - 23.72) <= 0.05) { return true }
        if ax <= 4.115 && (abs(y - 5.51) <= 0.025 || abs(y - 18.26) <= 0.025) { return true }
        if ax <= 0.025 && ((y >= 5.485 && y <= 18.285) || (y >= 0.1 && y <= 0.2)) { return true }
        if y >= 0 && y <= 23.77 && (abs(ax - 4.09) <= 0.025 || abs(ax - 5.46) <= 0.025) { return true }
        return false
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}
