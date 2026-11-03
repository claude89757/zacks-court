import Foundation
import XCTest
@testable import CourtCore

/// Opt-in: line calls from an in-house replay (`court-analyze independent-replay` output) against
/// S家 App's exported 界内/出界 for the same video. Agreement says the two programs reach the same
/// call, not which one is right.
///
/// `COURT_HAWKEYE_COMPARE="RUN.json|TEACHER.json|singles;RUN2.json|TEACHER2.json|doubles"`, where
/// TEACHER is a JSON object whose `teacher` list has `anchor` (seconds) and `result`.
final class HawkEyeReferenceComparisonTests: XCTestCase {
    private struct Run: Decodable { let events: [TennisShotEvent] }
    private struct Teacher: Decodable { let teacher: [Row] }
    private struct Row: Decodable { let anchor: Double?; let result: String?; let type: String? }

    private struct Tally {
        var paired = 0, judged = 0, agree = 0, close = 0, geometric = 0, geometricAgree = 0, referenceOut = 0, outAgree = 0
        var disagreements: [String] = []
        var line: String {
            "paired \(paired), close \(close), judged \(judged), agree \(agree)/\(judged) (S家 out \(outAgree)/\(referenceOut)); no margin \(geometricAgree)/\(geometric)"
        }
    }

    func testInHouseCallsAgainstReference() throws {
        guard let spec = ProcessInfo.processInfo.environment["COURT_HAWKEYE_COMPARE"] else {
            throw XCTSkip("Set COURT_HAWKEYE_COMPARE to compare replay line calls with S家 App")
        }
        for item in spec.split(separator: ";") {
            let parts = item.split(separator: "|").map(String.init)
            XCTAssertEqual(parts.count, 3, "RUN|TEACHER|format")
            guard parts.count == 3, let format = HawkEyeFormat(rawValue: parts[2]) else { continue }
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let run = try decoder.decode(Run.self, from: Data(contentsOf: URL(fileURLWithPath: parts[0])))
            // the teacher files are written by Python's json, which spells non-finite numbers NaN and Infinity
            let text = try String(contentsOf: URL(fileURLWithPath: parts[1]), encoding: .utf8)
                .replacingOccurrences(of: #"-?\bInfinity\b|\bNaN\b"#, with: "null", options: .regularExpression)
            let teacher = try JSONDecoder().decode(Teacher.self, from: Data(text.utf8))
            let settings = HawkEyeSettings(enabled: true, format: format, farHalf: true)
            var near = Tally(), far = Tally()
            var used = Set<Int>()
            var referenceCalls = 0
            for row in teacher.teacher {
                guard let anchor = row.anchor, let result = row.result, result == "界内" || result == "出界" else { continue }
                referenceCalls += 1
                // nearest unused in-house row within 0.7 s of S家's hit
                let candidates = run.events.indices.filter { !used.contains($0) && abs(run.events[$0].sourcePTS - anchor) <= 0.7 }
                guard let i = candidates.min(by: { abs(run.events[$0].sourcePTS - anchor) < abs(run.events[$1].sourcePTS - anchor) })
                else { continue }
                used.insert(i)
                let event = HawkEye.annotate(run.events[i], settings: settings)
                guard let j = event.bounce?.hawkEye else { continue }
                let referenceOut = result == "出界"
                func count(_ t: inout Tally) {
                    t.paired += 1
                    t.geometric += 1
                    if (j.distanceM > 0) == referenceOut { t.geometricAgree += 1 }
                    if j.call == .close { t.close += 1; return }
                    t.judged += 1
                    if referenceOut { t.referenceOut += 1; if j.call == .out { t.outAgree += 1 } }
                    if (j.call == .out) == referenceOut { t.agree += 1 } else {
                        t.disagreements.append(String(format: "%.2f s %@ %@ ours %@ %.2f m (margin %.2f, %@)", anchor,
                                                      row.type ?? "", result, j.call.rawValue, j.distanceM, j.marginM, j.line.rawValue))
                    }
                }
                if j.farHalf { count(&far) } else { count(&near) }
            }
            print("HAWKEYE \(URL(fileURLWithPath: parts[0]).lastPathComponent) \(format.rawValue): S家 calls \(referenceCalls), ours \(near.paired + far.paired)")
            print("HAWKEYE   near: \(near.line)")
            print("HAWKEYE   far:  \(far.line)")
            for d in near.disagreements { print("HAWKEYE   near differs \(d)") }
            for d in far.disagreements { print("HAWKEYE   far differs \(d)") }
        }
    }
}
