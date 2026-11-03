import XCTest
import CourtCore

/// Camera zoom: range and presets from the capture format, the status field, and the framing change
/// that restarts analysis. The camera itself is not used (the simulator and Mac have no zoom).
@MainActor
final class CameraZoomTests: XCTestCase {
    func testRangeComesFromTheFormatAndStopsAtTheSystemLimit() throws {
        XCTAssertNil(CameraZoomRange(formatMaximum: 1), "a format without zoom shows no control")
        XCTAssertNil(CameraZoomRange(formatMaximum: .nan))

        let wide = try XCTUnwrap(CameraZoomRange(formatMaximum: 123))
        XCTAssertEqual(wide.maximum, 25, "the system camera's video limit")
        XCTAssertFalse(wide.hasUltraWide)
        XCTAssertEqual(wide.presets, [1, 2])
        XCTAssertEqual(wide.deviceFactor(2), 2)
        XCTAssertEqual(wide.clamp(0.5), 1)
        XCTAssertEqual(wide.clamp(90), 25)
        XCTAssertEqual(wide.clamp(1.234), 1.23)
        XCTAssertEqual(wide.clamp(.infinity), 1)
        XCTAssertFalse(wide.isUpscaled(2))
        XCTAssertTrue(wide.isUpscaled(2.5))

        let short = try XCTUnwrap(CameraZoomRange(formatMaximum: 1.8))
        XCTAssertEqual(short.presets, [1])
        XCTAssertEqual(short.clamp(2), 1.8)
        XCTAssertFalse(short.isUpscaled(1.8))
    }

    func testDualWideCameraStartsAtHalfAndConvertsToDeviceFactors() throws {
        // Dual-wide: device factor 1 is the ultra-wide (0.5×), the main lens takes over at 2.
        let dual = try XCTUnwrap(CameraZoomRange(formatMaximum: 123, displayMultiplier: 0.5, switchOvers: [2]))
        XCTAssertTrue(dual.hasUltraWide)
        XCTAssertEqual(dual.minimum, 0.5)
        XCTAssertEqual(dual.maximum, 25)
        XCTAssertEqual(dual.presets, [0.5, 1, 2])
        XCTAssertEqual(dual.clamp(0.2), 0.5)
        XCTAssertEqual(dual.deviceFactor(0.5), 1)
        XCTAssertEqual(dual.deviceFactor(1), 2)
        XCTAssertEqual(dual.deviceFactor(3), 6)
        XCTAssertEqual(dual.stepped(1, by: 1), 2, "one doubling per drag step")
        XCTAssertEqual(dual.stepped(1, by: -3), 0.5, "stops at the widest lens")

        // Triple camera: the system camera's stops 0.5 / 1 / 2 / 4 / 8.
        let triple = try XCTUnwrap(CameraZoomRange(formatMaximum: 135, displayMultiplier: 0.5, switchOvers: [2, 8]))
        XCTAssertEqual(triple.lenses, [0.5, 1, 4])
        XCTAssertEqual(triple.presets, [0.5, 1, 2, 4, 8])
        XCTAssertEqual(triple.deviceFactor(4), 8)
        XCTAssertTrue(triple.isUpscaled(3), "the main lens past its 2× crop, before the telephoto")
        XCTAssertFalse(triple.isUpscaled(6), "the telephoto crops 2× natively")
        XCTAssertTrue(triple.isUpscaled(12))
        XCTAssertFalse(dual.isUpscaled(0.8), "the ultra-wide range is never upscaled")
        XCTAssertFalse(dual.isUpscaled(2))
        XCTAssertTrue(dual.isUpscaled(2.5))
        XCTAssertEqual(CameraZoomRange.title(0.5), "0.5×")
    }

    func testTitlesDropTrailingZeros() {
        XCTAssertEqual(CameraZoomRange.title(1), "1×")
        XCTAssertEqual(CameraZoomRange.title(1.5), "1.5×")
        XCTAssertEqual(CameraZoomRange.title(2.34), "2.3×")
        XCTAssertEqual(CameraZoomRange.title(2.999), "3×")
        XCTAssertEqual(CameraZoomRange.title(12.4), "12×")
    }

    func testStatusZoomIsOptionalForOlderPeers() throws {
        var status = CameraStatus()
        status.zoom = 2
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(CameraStatus.self, from: data).zoom, 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "zoom")
        let older = try JSONDecoder().decode(CameraStatus.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.zoom, "an older v2 camera has no zoom field")
        XCTAssertNotEqual(older, status, "a zoom change is a status change")
    }

    func testFramingChangeRestartsAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = CameraRig(root: root)
        rig.camera.framingChanged()
        XCTAssertNil(rig.camera.tennisAnalysis, "the temporal run restarts")

        rig.camera.zoomFactor = 2
        XCTAssertNil(rig.camera.status.zoom, "zoom is reported only while capturing")
        await rig.close()
    }
}
