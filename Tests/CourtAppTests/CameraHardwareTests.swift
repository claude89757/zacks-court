import XCTest
import CourtCore

/// Which iPhones can be the camera: iPhone 13 and later (iPhone14,x and up).
final class CameraHardwareTests: XCTestCase {
    func testIPhone13AndLaterQualify() {
        for id in ["iPhone14,4", "iPhone14,5", "iPhone14,2", "iPhone14,3", "iPhone14,6", "iPhone15,2", "iPhone16,2",
                   "iPhone17,5", "iPhone18,2", "iPhone18,4", "iPhone19,3"] {
            XCTAssertTrue(CameraHardware.isSupported(id), id)
        }
        XCTAssertTrue(CameraHardware.isSupported("iPhone21,7"), "a model newer than the table qualifies without a code change")
        XCTAssertEqual(CameraHardware.name("iPhone21,7"), "iPhone21,7")
    }

    func testOlderPhonesAndOtherDevicesDoNot() {
        for id in ["iPhone13,4", "iPhone13,1", "iPhone12,8", "iPhone10,3", "iPad14,1", "Mac16,1", "simulator", "arm64",
                   "iPhone", "iPhone14", "iPhone14,", "iPhoneX,1", ""] {
            XCTAssertFalse(CameraHardware.isSupported(id), id)
        }
    }

    func testNamesAndMeasuredModels() {
        XCTAssertEqual(CameraHardware.name("iPhone14,4"), "iPhone 13 mini")
        XCTAssertEqual(CameraHardware.name("iPhone17,5"), "iPhone 16e")
        XCTAssertEqual(CameraHardware.name("iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertTrue(CameraHardware.isMeasured("iPhone18,2"))
        XCTAssertFalse(CameraHardware.isMeasured("iPhone14,5"), "only Phase 0-measured models count as measured")
        XCTAssertTrue(CameraHardware.measured.allSatisfy(CameraHardware.isSupported))
        XCTAssertTrue(CameraHardware.names.keys.allSatisfy(CameraHardware.isSupported), "every named model qualifies")
    }

    func testLensPresetsOfOlderTripleAndDualCameras() throws {
        // 13 Pro / 14 Pro: 3× telephoto (switch-over at device factor 6 on a 0.5 multiplier).
        let thirteenPro = try XCTUnwrap(CameraZoomRange(formatMaximum: 123, displayMultiplier: 0.5, switchOvers: [2, 6]))
        XCTAssertEqual(thirteenPro.presets, [0.5, 1, 2, 3, 6])
        // 15 Pro Max / 16 Pro: 5× telephoto.
        let fiveTimes = try XCTUnwrap(CameraZoomRange(formatMaximum: 123, displayMultiplier: 0.5, switchOvers: [2, 10]))
        XCTAssertEqual(fiveTimes.presets, [0.5, 1, 2, 5, 10])
        // 13 / 14 / 15 / 16: ultra-wide + main.
        XCTAssertEqual(CameraZoomRange(formatMaximum: 123, displayMultiplier: 0.5, switchOvers: [2])?.presets, [0.5, 1, 2])
        // SE (3rd gen), 16e, Air: one rear camera.
        XCTAssertEqual(CameraZoomRange(formatMaximum: 123)?.presets, [1, 2])
    }
}
