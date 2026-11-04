import XCTest
import CourtCore

final class TennisSessionTests: XCTestCase {
    func testShotUpdatesPreserveOneIdentityAndRespectSegmentBoundary() throws {
        let stream = UUID()
        var session = CourtSession(title: "Analysis")
        var first = TennisShotEvent(streamID: stream, sourcePTS: 12, stroke: .groundstroke, confidence: 0.8, speedReason: "等待首弹地")
        let old = TennisShotEvent(streamID: stream, sourcePTS: 8, stroke: .serve, confidence: 0.9)
        func snapshot(_ events: [TennisShotEvent]) -> TennisAnalysisSnapshot {
            TennisAnalysisSnapshot(streamID: stream, pts: 14, processedFrames: 20, inferenceMilliseconds: 10,
                                   events: events, calibration: .init(), modelVersion: "test", limitations: [])
        }
        session.recordTennisAnalysis(snapshot([old, first]), minimumPTS: 10)
        XCTAssertEqual(session.tennisEvents?.count, 1)
        first.speedKPH = 100; first.speedReason = nil; first.endPTS = 13
        session.recordTennisAnalysis(snapshot([first]), minimumPTS: 10)
        XCTAssertEqual(session.tennisEvents?.count, 1)
        XCTAssertEqual(session.tennisEvents?.first?.speedKPH, 100)
        session.pause()
        first.speedKPH = 110
        session.recordTennisAnalysis(snapshot([first]))
        XCTAssertEqual(session.tennisEvents?.first?.speedKPH, 100, "Paused sessions reject ordinary live callbacks")
        session.recordTennisAnalysis(snapshot([first]), completingPausedSegment: true)
        XCTAssertEqual(session.tennisEvents?.first?.speedKPH, 110, "Only an explicitly sealed tail updates a paused segment")
        session.finish()
        first.speedKPH = 120
        session.recordTennisAnalysis(snapshot([first]), completingPausedSegment: true)
        XCTAssertEqual(session.tennisEvents?.first?.speedKPH, 110)
    }

    /// A store folder whose URL was made before the folder existed has no trailing "/", while the
    /// recording's parent does. Outside /var (no symlink to resolve) that used to refuse every recording.
    func testRecordingURLAcceptsFolderMadeBeforeItExisted() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/test-store-\(UUID().uuidString)")
        XCTAssertFalse(folder.hasDirectoryPath)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SessionStore(directory: folder)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Court-1.mov").path, contents: Data([1]))
        XCTAssertEqual(try store.recordingURL(filename: "Court-1.mov").lastPathComponent, "Court-1.mov")
        XCTAssertThrowsError(try store.recordingURL(filename: "../Court-1.mov"))
    }

    func testPreAnalysisHistoryStillDecodesWithoutInventedShots() throws {
        let session = CourtSession(title: "Old record", kind: .match)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "tennisEvents")
        object.removeValue(forKey: "tennisModelVersion")
        object.removeValue(forKey: "tennisCalibration")
        object["teamA"] = "Old A"; object["teamB"] = "Old B"
        object["events"] = [["id": UUID().uuidString, "kind": "point", "date": 0, "elapsed": 1, "side": "a"]]
        let restored = try JSONDecoder().decode(CourtSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.title, "Old record")
        XCTAssertNil(restored.tennisEvents)
        XCTAssertEqual(restored.events.first?.kind, .point)
        XCTAssertEqual(restored.recordings.count, 0)
    }

    /// A NaN or infinite number in a row (a degenerate fit) becomes unknown, so the record still saves;
    /// a failed save says why once, without 「。。」.
    func testNonFiniteRowValuesBecomeUnknownAndTheRecordSaves() throws {
        let stream = UUID()
        var row = TennisShotEvent(streamID: stream, sourcePTS: 12, stroke: .forehand, confidence: .nan, speedKPH: .infinity)
        row.hit = TennisCourtPoint(x: 1, y: .nan, z: 1)
        row.bounce = TennisBounceEstimate(sourcePTS: 12.6, xMeters: 4, yMeters: 8, confidence: 0)
        row.bounce?.sigmaXMeters = .nan; row.bounce?.sigmaYMeters = 0.2
        row.bounce?.hawkEye = HawkEyeJudgement(call: .in, distanceM: -.infinity, marginM: 0.1, line: .sideline, format: .singles, serve: false, farHalf: false)
        XCTAssertThrowsError(try JSONEncoder().encode(row), "JSON has no NaN")
        let clean = row.finiteOnly
        XCTAssertNil(clean.speedKPH); XCTAssertEqual(clean.speedReasonCode, .speedUnreliable)
        XCTAssertNil(clean.hit); XCTAssertEqual(clean.confidence, 0)
        XCTAssertEqual(clean.bounce?.xMeters, 4, "a finite bounce position stays")
        XCTAssertNil(clean.bounce?.sigmaXMeters); XCTAssertNil(clean.bounce?.hawkEye)
        var session = CourtSession(title: "NaN")
        session.recordTennisAnalysis(TennisAnalysisSnapshot(streamID: stream, pts: 14, processedFrames: 20, inferenceMilliseconds: 10, events: [clean],
                                                            calibration: .init(), modelVersion: "test", limitations: []), minimumPTS: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("court-nan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try SessionStore(directory: directory).save(session))

        let failure = SaveFailure.message(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "未能写入数据，因为它的格式不正确。"]))
        XCTAssertEqual(failure, "记录保存失败：未能写入数据，因为它的格式不正确。检查存储空间后重试。")
        XCTAssertTrue(SaveFailure.isMessage(failure)); XCTAssertFalse(SaveFailure.isMessage("别的提示"))
    }
}
