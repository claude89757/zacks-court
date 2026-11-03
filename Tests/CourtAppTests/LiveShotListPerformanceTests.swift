#if os(macOS)
import XCTest
import SwiftUI
import CourtCore
@testable import CourtApp

/// A two-hour record can hold hundreds of shots. The live page draws a fixed few rows in a plain
/// stack (a LazyVStack nested in the page scroll froze the simulator once) and offers the rest in a
/// `List` of its own. This renders the live overview offscreen with a long synthetic ledger and
/// compares it with drawing every row in a plain stack, which is what an uncapped list would cost.
/// Synthetic rows only: this measures layout work, not analysis.
@MainActor
final class LiveShotListPerformanceTests: XCTestCase {
    private func ledger(_ count: Int) -> [TennisShotEvent] {
        let stream = UUID()
        let strokes: [TennisStrokeKind] = [.forehand, .backhand, .serve, .groundstroke, .volley]
        return (0..<count).map { (index: Int) -> TennisShotEvent in
            let speed: Double? = index % 3 == 0 ? nil : 80 + Double(index % 60)
            return TennisShotEvent(streamID: stream, sourcePTS: Double(index) * 4, stroke: strokes[index % strokes.count],
                                   confidence: 0.8, speedKPH: speed)
        }
    }

    /// Seconds to lay out and draw `view` at a phone width.
    private func renderSeconds<V: View>(_ view: V) throws -> Double {
        let renderer = ImageRenderer(content: view.frame(width: 393).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        let start = ProcessInfo.processInfo.systemUptime
        _ = try XCTUnwrap(renderer.cgImage)
        return ProcessInfo.processInfo.systemUptime - start
    }

    func testLiveOverviewCostDoesNotGrowWithTheRecord() throws {
        let short = ledger(24), long = ledger(600)
        // Warm up fonts and symbols so the first measurement is not the slowest by accident.
        _ = try renderSeconds(TennisAnalysisOverview(events: short))
        let capped = try renderSeconds(TennisAnalysisOverview(events: long, allShotCount: long.count, openAllShots: {}))
        let cappedShort = try renderSeconds(TennisAnalysisOverview(events: short, allShotCount: short.count, openAllShots: {}))
        let everyRow = try renderSeconds(
            VStack(spacing: CourtStyle.Space.s) {
                ForEach(long) { TennisShotRow(event: $0, selected: .constant(nil)) }
            }
        )
        print(String(format: "Live overview, 24 shots: %.3f s; 600 shots (8 rows drawn): %.3f s; 600 rows in a plain stack: %.3f s",
                     cappedShort, capped, everyRow))
        // Loose bounds: CI machines vary. The point is that the page stays a fixed size of work.
        XCTAssertLessThan(capped, 2.0, "The live overview must not draw every shot of a long record")
        XCTAssertLessThan(capped, everyRow, "Capped rows cost less than drawing the whole ledger")
    }
}
#endif
