import XCTest
@testable import CourtApp

@MainActor
final class CalibrationGeometryTests: XCTestCase {
    func testPortraitContainerRejectsLetterboxesAndMapsImageCoordinates() {
        let container = CGSize(width: 320, height: 600)
        // A 1920×1080 frame appears 320×180, between y=210 and y=390.
        XCTAssertNil(CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 160, y: 100), imageWidth: 1920, imageHeight: 1080, container: container))
        XCTAssertNil(CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 160, y: 450), imageWidth: 1920, imageHeight: 1080, container: container))
        let center = CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 160, y: 300), imageWidth: 1920, imageHeight: 1080, container: container)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.000001)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.000001)
        let nearLeft = CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 32, y: 372), imageWidth: 1920, imageHeight: 1080, container: container)
        XCTAssertEqual(nearLeft?.x ?? -1, 0.1, accuracy: 0.000001)
        XCTAssertEqual(nearLeft?.y ?? -1, 0.9, accuracy: 0.000001)
    }

    func testWideContainerRejectsSidePillarsWithoutStretchingPoints() {
        let container = CGSize(width: 800, height: 300)
        // A square frame is 300×300, centered from x=250 to x=550.
        XCTAssertNil(CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 100, y: 150), imageWidth: 1080, imageHeight: 1080, container: container))
        let point = CourtCalibrationSheet.normalizedPoint(at: CGPoint(x: 325, y: 225), imageWidth: 1080, imageHeight: 1080, container: container)
        XCTAssertEqual(point?.x ?? -1, 0.25, accuracy: 0.000001)
        XCTAssertEqual(point?.y ?? -1, 0.75, accuracy: 0.000001)
        XCTAssertNil(CourtCalibrationSheet.normalizedPoint(at: .zero, imageWidth: 0, imageHeight: 1080, container: container))
    }
}
