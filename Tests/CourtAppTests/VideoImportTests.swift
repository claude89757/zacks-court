import XCTest
@testable import CourtCore

/// 「导入视频」: which videos the live lane can take, and that a failed run leaves no record behind.
/// The full run with the real models is `court-probe import` (docs/verification.md).
final class VideoImportTests: XCTestCase {
    private func reason(_ width: Double, _ height: Double, fps: Double = 60, seconds: Double = 40) -> String? {
        do { _ = try VideoImport.check(filename: "a.mov", duration: seconds, width: width, height: height, frameRate: fps); return nil }
        catch { return error.localizedDescription }
    }

    func testAcceptsLandscapeSixtyFramesFromSevenTwentyUp() throws {
        XCTAssertNil(reason(1920, 1080, fps: 59.94))
        XCTAssertNil(reason(1280, 720))
        XCTAssertNil(reason(3840, 2160, fps: 60))
        let info = try VideoImport.check(filename: "IMG_0001.MOV", duration: 42.4, width: 1920, height: 1080, frameRate: 59.94)
        XCTAssertEqual(info.summary, "1920×1080 · 60 帧/秒 · 0:42")
        XCTAssertEqual(VideoImport.title(for: info.filename), "导入 · IMG_0001")
    }

    func testRejectsWithReasonsUsersCanActOn() {
        XCTAssertTrue(reason(1080, 1920)?.contains("竖屏") == true)
        XCTAssertTrue(reason(1440, 1080)?.contains("16:9") == true)
        XCTAssertTrue(reason(640, 360)?.contains("720p") == true)
        XCTAssertTrue(reason(1920, 1080, fps: 30)?.contains("这段是 30 帧/秒") == true)
        XCTAssertTrue(reason(1920, 1080, fps: 240)?.contains("慢动作") == true)
        XCTAssertTrue(reason(1920, 1080, seconds: 1)?.contains("太短") == true)
        XCTAssertTrue(reason(1920, 1080, seconds: 601)?.contains("太长") == true)
        XCTAssertNotNil(reason(1920, 1080, fps: .nan))
    }

    /// An imported record lasts as long as its video, not as long as the analysis took.
    func testImportedDurationOnlyForFinishedRecords() {
        var session = CourtSession(title: "导入 · a", startedAt: Date(timeIntervalSinceNow: -300))
        session.setImportedDuration(40)
        XCTAssertGreaterThan(session.elapsed(), 200, "an open record keeps its clock")
        session.finish()
        session.setImportedDuration(40)
        XCTAssertEqual(session.elapsed(), 40, accuracy: 0.001)
    }

    func testInspectReadsTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await VideoExportTests.writeMovie(url, seconds: 1)   // 320×180, 30 fps
        do { _ = try await VideoImport.inspect(url); XCTFail("320×180 must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("320×180"), error.localizedDescription) }
    }

    /// Cancelling mid-run removes the unfinished record and its recording. Needs the staged FP16
    /// model (`scripts/prepare-independent-app-models.sh`); skipped without it.
    @MainActor func testCancelMidRunLeavesNoRecord() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1", isDirectory: true)
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Staged FP16 in-house model not found")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mov")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await VideoExportTests.writeMovie(video, seconds: 20)
        let run = VideoImportRun(storageDirectory: folder, live: IndependentLiveConfiguration(
            loadAssets: { try IndependentBallModelAssets.load(directory: models, variant: .fp16) }))
        let info = VideoImport.Info(filename: "clip.mov", duration: 20, width: 1920, height: 1080, frameRate: 60)
        var analysed = 0.0
        let task = Task { @MainActor in
            try await run.run(video: video, info: info, title: "t") { analysed = $0.analyzedSeconds }
        }
        let deadline = Date().addingTimeInterval(60)
        while analysed < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(analysed, 1, "analysis never started")
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try await Task.sleep(for: .seconds(1))   // a late recording callback must not bring the record back
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left.filter { ($0.hasSuffix(".json") && $0 != "hawk-eye.json") || $0.hasPrefix("Court-") }, [], "\(left)")
    }

    /// Models that fail to load stop the run before a record opens; nothing is left in the folder.
    @MainActor func testModelFailureLeavesNoRecord() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let run = VideoImportRun(storageDirectory: folder, live: IndependentLiveConfiguration(
            loadAssets: { throw CourtError.message("no models in this test") }))
        let info = VideoImport.Info(filename: "a.mov", duration: 10, width: 1920, height: 1080, frameRate: 60)
        var stages: [VideoImportRun.Stage] = []
        do {
            _ = try await run.run(video: folder.appendingPathComponent("a.mov"), info: info, title: "t") { stages.append($0.stage) }
            XCTFail("expected a model failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("自研模型未能载入"), error.localizedDescription) }
        XCTAssertEqual(stages, [.loadingModel])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertTrue(left.filter { $0.hasSuffix(".json") || $0.hasSuffix(".mov") }.isEmpty, "\(left)")
    }
}
