import XCTest
import SwiftUI
@testable import CourtApp
@testable import CourtCore

/// The court map's VoiceOver wording and stroke marks (docs/design-system.md, 无障碍).
final class CourtMapAccessibilityTests: XCTestCase {
    private func shot(_ stroke: TennisStrokeKind, speed: Double?, x: Double?, y: Double?) -> TennisShotEvent {
        TennisShotEvent(streamID: UUID(), sourcePTS: 1, endPTS: 2, stroke: stroke, confidence: 0.8, speedKPH: speed,
                        bounce: TennisBounceEstimate(sourcePTS: 1.5, xMeters: x, yMeters: y, confidence: 0.7))
    }

    func testSpokenDescriptionNamesShotStrokeSpeedAndArea() {
        let text = shot(.forehand, speed: 112.4, x: 3.24, y: 18.04).courtMapSpokenDescription(number: 7)
        XCTAssertEqual(text, "第 7 拍，正手，约 112 千米每小时，远端半场发球区，约横 3.2 米、纵 18.0 米")
    }

    func testUnknownSpeedIsSaidNotZero() {
        let text = shot(.serve, speed: nil, x: 5, y: 2).courtMapSpokenDescription(number: 1)
        XCTAssertTrue(text.contains("暂无球速"), text)
        XCTAssertFalse(text.contains("0 千米"), text)
        XCTAssertTrue(text.contains("近端半场后场"), text)
    }

    func testCourtZones() {
        XCTAssertEqual(TennisShotEvent.courtZone(x: 5.4, y: 8), "近端半场发球区")
        XCTAssertEqual(TennisShotEvent.courtZone(x: 5.4, y: 1), "近端半场后场")
        XCTAssertEqual(TennisShotEvent.courtZone(x: 0.5, y: 20), "远端半场双打边线区")
        XCTAssertEqual(TennisShotEvent.courtZone(x: 12, y: 20), "场外")
        XCTAssertEqual(TennisShotEvent.courtZone(x: 5, y: -1), "场外")
    }

    /// Every stroke has its own non-empty mark of about the requested size, so shape (not only color)
    /// tells strokes apart on the map.
    func testEveryStrokeHasADistinctFilledMark() {
        let center = CGPoint(x: 50, y: 50)
        var boxes: [CGRect] = []
        for kind in TennisStrokeKind.allCases {
            let path = kind.courtMarkPath(center: center, radius: 6.5)
            let box = path.boundingRect
            XCTAssertFalse(path.isEmpty, "\(kind)")
            XCTAssertGreaterThanOrEqual(box.width, 10, "\(kind) mark is at least about 6 pt in radius")
            XCTAssertLessThanOrEqual(box.width, 20, "\(kind)")
            XCTAssertTrue(path.contains(center), "\(kind) is filled at its center")
            boxes.append(box)
        }
        // The cross is the plus turned 45°: same area, different corners covered.
        let plus = TennisStrokeKind.feed.courtMarkPath(center: center, radius: 6.5)
        let cross = TennisStrokeKind.groundstroke.courtMarkPath(center: center, radius: 6.5)
        XCTAssertTrue(plus.contains(CGPoint(x: 50, y: 43)) && !cross.contains(CGPoint(x: 50, y: 43)))
        XCTAssertTrue(cross.contains(CGPoint(x: 45, y: 45)) && !plus.contains(CGPoint(x: 45, y: 45)))
    }
}
