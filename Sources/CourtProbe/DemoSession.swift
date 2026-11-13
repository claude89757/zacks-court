import Foundation
import CourtCore

/// `court-probe demo-session DIR`: writes one finished session of made-up shots into DIR (a
/// `Zacks Court/Sessions` folder), for App Store and README screenshots. The title, device name,
/// model label and marker are the canonical phrases in `CourtCopy.storedPhrases`. Screens translate
/// those phrases and still say the record is demo data, not a measurement. The shots follow the
/// court frame of `TennisBounceEstimate`, and the line calls come from `HawkEye.annotate`.
extension CourtProbe {
    static func writeDemoSession(directory: URL) throws {
        var random = DemoRandom(seed: 20261103)
        let stream = UUID()
        let start = Date().addingTimeInterval(-3 * 3600)
        var session = CourtSession(title: "示例记录 · 演示数据，非实测", kind: .training, startedAt: start)
        session.setCapturedOn("演示数据")
        var events: [TennisShotEvent] = []
        var pts = 4.0
        var nearServes = true
        for point in 0..<14 {
            var nearHits = point % 4 < 2 ? nearServes : !nearServes
            if point == 7 { nearServes.toggle() }
            let rallyLength = [3, 5, 2, 6, 4, 1, 5, 3, 4, 2, 6, 3, 5, 4][point]
            for shot in 0..<rallyLength {
                let stroke: TennisStrokeKind
                if shot == 0 { stroke = .serve }
                else if shot >= 3 && random.next() < 0.2 { stroke = .volley }
                else { stroke = random.next() < 0.58 ? .forehand : .backhand }
                let speed: Double? = {
                    switch stroke {
                    case .serve: return 138 + random.next() * 40
                    case .forehand: return 82 + random.next() * 34
                    case .backhand: return 72 + random.next() * 28
                    default: return 55 + random.next() * 25
                    }
                }()
                // The last shot of a rally lands out or in the net now and then; one in six has no speed.
                let last = shot == rallyLength - 1
                let toFar = nearHits
                var x: Double, y: Double
                if stroke == .serve {
                    let box = point % 2 == 0 ? 1.0 : -1.0   // deuce / ad box, seen from the server
                    x = HawkEye.centreX + box * (toFar ? -1 : 1) * (0.4 + random.next() * 3.4)
                    y = toFar ? HawkEye.netY + 2.2 + random.next() * 4.0 : HawkEye.netY - 2.2 - random.next() * 4.0
                } else {
                    x = 1.6 + random.next() * 7.8
                    let depth = 3.5 + random.next() * 8.0
                    y = toFar ? HawkEye.netY + depth : HawkEye.netY - depth
                }
                if last && point % 3 == 1 { y = toFar ? HawkEye.length + 0.35 : -0.35 }
                if last && point % 5 == 3 { x = toFar ? 0.9 : 10.1 }
                let hitX = stroke == .serve ? HawkEye.centreX + (point % 2 == 0 ? 1.0 : -1.0) * 1.2 : 2 + random.next() * 7
                let hitY = nearHits ? -0.4 + random.next() * 1.5 : HawkEye.length + 0.4 - random.next() * 1.5
                let flight = stroke == .serve ? 0.75 : 1.05 + random.next() * 0.4
                var row = TennisShotEvent(streamID: stream, sourcePTS: pts, endPTS: pts + flight + 0.2, stroke: stroke,
                                          confidence: 0.7 + random.next() * 0.25, speedKPH: speed, sampleCount: 18)
                if random.next() < 0.17 { row.speedKPH = nil; row.speedReason = "没看清球"; row.speedReasonCode = .ballNotSeen }
                var bounce = TennisBounceEstimate(sourcePTS: pts + flight * 0.7, xMeters: x, yMeters: y, confidence: 0.8, reason: nil)
                bounce.sigmaXMeters = 0.06 + random.next() * 0.06
                bounce.sigmaYMeters = 0.09 + random.next() * 0.1
                row.bounce = bounce
                row.hit = TennisCourtPoint(x: hitX, y: hitY, z: stroke == .serve ? 2.7 : 0.9)
                events.append(HawkEye.annotate(row, settings: HawkEyeSettings(enabled: true, format: .singles, farHalf: true)))
                pts += flight + 0.6 + random.next() * 0.5
                nearHits.toggle()
            }
            pts += 18 + random.next() * 14
            if point % 5 == 4 { session.addMarker("精彩", at: start.addingTimeInterval(pts - 10), sourcePTS: pts - 10, streamID: stream) }
        }
        let calibration = TennisCourtCalibrationState(isAvailable: true, landmarkCount: 12, validationErrorMeters: 0.08, reason: nil)
        session.mergeRemoteTennisEvents(events, calibration: calibration, modelVersion: "演示数据")
        session.finish(at: start.addingTimeInterval(pts + 5))
        let store = try SessionStore(directory: directory)
        try store.save(session)
        print("Wrote demo session \(session.id.uuidString) with \(events.count) made-up shots to \(directory.path). Not a measurement.")
    }
}

/// Fixed-seed generator so the demo screens are the same each time.
private struct DemoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
