#if os(macOS)
import XCTest
import Foundation
import AVFoundation
@testable import CourtCore
@testable import CourtApp

/// Phase 3 per-shot clips over real TLS on localhost: the display asks the in-process camera for a
/// few seconds around a shot; the camera cuts them without re-encoding from memory (segment being
/// recorded) or from the finished MOV, and sends them like a recording. Synthetic frames and
/// injected shot rows: this proves the clip path, not tennis accuracy.
final class CameraClipTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    @MainActor func testClipsCutFromMemoryWhileRecordingAndFromTheFinishedMovie() async throws {
        let root = makeRoot("court-clips")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        // A short memory window, so an older shot of the open segment can be checked quickly.
        rig.pipeline.liveClipSeconds = 6
        do {
            display.selectRole(.server)
            try await waitFor("ticket", timeout: 10) { !display.pairingURL.isEmpty }
            var ticket = try PairingTicket.parse(display.pairingURL); ticket.host = "127.0.0.1"
            rig.camera.pair(ticket)
            try await waitFor("connected", timeout: 10) { display.connected && rig.camera.linkState == .connected }
            XCTAssertTrue(display.canFetchClips, "The camera lists clips in its hello")
            rig.source.start()
            display.sessionTitle = "片段测试"; display.startSession()
            // Waits follow the capture clock, so a runner below 60 fps only takes longer.
            try await waitFor("camera records", timeout: 30) { (rig.camera.counters.recordingSeconds ?? 0) > 5 }
            let owner = try XCTUnwrap(display.session?.id)
            let stream = try XCTUnwrap(rig.camera.streamID)
            let begin = try XCTUnwrap(rig.camera.counters.latestPTS) - (rig.camera.counters.recordingSeconds ?? 0)
            let early = TennisShotEvent(streamID: stream, sourcePTS: begin + 0.5, stroke: .forehand, confidence: 0.7)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [early]))
            try await waitFor("row mirrored", timeout: 5) { display.session?.tennisEvents?.count == 1 }

            // While recording: the window ends 3 s after the hit, half a second past the newest
            // frame, so the camera briefly waits for it (its wait is capped in wall time), then cuts
            // from memory. The clip starts on a keyframe and decodes completely.
            let live = TennisShotEvent(streamID: stream, sourcePTS: try XCTUnwrap(rig.camera.counters.latestPTS) - 2.5, stroke: .backhand, confidence: 0.6)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [early, live]))
            try await waitFor("second row", timeout: 5) { display.session?.tennisEvents?.count == 2 }
            XCTAssertEqual(display.shotReplay(session: display.session, shot: live), .fetchable)
            let fetchedLive = await display.fetchClip(session: owner, shot: live)
            let liveClip = try XCTUnwrap(fetchedLive, display.clip?.progress.error ?? "no clip")
            XCTAssertEqual(rig.camera.session?.state, .active, "Clips are cut while the camera keeps recording")
            XCTAssertTrue(rig.camera.counters.recording)
            let liveFrames = try await decodeMovie(liveClip)
            // 2 s before to 3 s after the hit, from the keyframe (every second) at or before the start.
            XCTAssertGreaterThanOrEqual(liveFrames, 5 * 60 - 2)
            XCTAssertLessThanOrEqual(liveFrames, 6 * 60 + 2)
            let liveStartsOnKeyframe = try await firstSampleIsKeyframe(liveClip)
            XCTAssertTrue(liveStartsOnKeyframe)
            XCTAssertEqual(display.shotReplay(session: display.session, shot: live), .clip(liveClip))

            // The earlier shot has left the 6 s memory window of the open segment: refused with the reason.
            try await waitFor("early shot leaves memory", timeout: 40) { (rig.camera.counters.latestPTS ?? 0) > early.sourcePTS + 9 }
            let refused = await display.fetchClip(session: owner, shot: early)
            XCTAssertNil(refused)
            XCTAssertTrue(display.clip?.progress.error?.contains("暂停或结束本段录像后") == true, display.clip?.progress.error ?? "")
            XCTAssertEqual(display.shotReplay(session: display.session, shot: early), .failed(display.clip?.progress.error ?? ""))
            // A session the camera does not have.
            let unknown = await display.fetchClip(session: UUID(), shot: early)
            XCTAssertNil(unknown)

            // Pause closes the first segment; resume starts a new one (and a new memory buffer).
            display.pauseOrResume()
            try await waitFor("first segment saved", timeout: 10) { display.session?.recordings.count == 1 && display.session?.state == .paused }
            display.pauseOrResume()
            try await waitFor("recording again", timeout: 30) { rig.camera.session?.state == .active && (rig.camera.counters.recordingSeconds ?? 0) > 3.4 }
            // A shot in the first second of the new segment: its window starts before the segment,
            // so the memory clip starts at the segment's first frame instead of being refused. The
            // whole window is already captured.
            let segmentStart = try XCTUnwrap(rig.camera.counters.latestPTS) - (rig.camera.counters.recordingSeconds ?? 0)
            let opening = TennisShotEvent(streamID: stream, sourcePTS: segmentStart + 0.3, stroke: .serve, confidence: 0.6)
            let fetchedOpening = await display.fetchClip(session: owner, shot: opening)
            let openingClip = try XCTUnwrap(fetchedOpening, display.clip?.progress.error ?? "no clip")
            let openingFrames = try await decodeMovie(openingClip)
            XCTAssertGreaterThanOrEqual(openingFrames, Int(3.3 * 60) - 6)
            XCTAssertLessThanOrEqual(openingFrames, Int(3.3 * 60) + 6)
            // Now the early shot comes from the finished movie.
            let recording = try XCTUnwrap(display.session?.recordings.first)
            let fetchedFile = await display.fetchClip(session: owner, shot: early)
            let fromFile = try XCTUnwrap(fetchedFile, display.clip?.progress.error ?? "no clip")
            let fileFrames = try await decodeMovie(fromFile)
            // The window starts before the recording, so it is clamped to the recording's first frame.
            XCTAssertGreaterThanOrEqual(fileFrames, Int((early.sourcePTS + 3 - recording.firstPTS) * 60) - 2)
            XCTAssertLessThanOrEqual(fileFrames, 6 * 60 + 2)
            let fileStartsOnKeyframe = try await firstSampleIsKeyframe(fromFile)
            XCTAssertTrue(fileStartsOnKeyframe)
            XCTAssertEqual(fromFile, display.clipURL(session: owner, shot: early.id))

            await display.finishSession()
            try await waitFor("completed", timeout: 15) { display.session?.state == .completed }
            display.reloadHistory()
            let saved = try XCTUnwrap(display.history.first { $0.id == owner })
            XCTAssertEqual(display.shotReplay(session: saved, shot: live), .clip(liveClip), "Fetched clips stay available in history")
            XCTAssertNil(display.error)
            XCTAssertNil(rig.camera.error)
            // The camera keeps no clip files once they are sent.
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("CourtClips").path)) ?? []
            XCTAssertFalse(leftovers.contains(liveClip.lastPathComponent))
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    @MainActor func testClipWindowAroundAShot() {
        let stream = UUID()
        var shot = TennisShotEvent(streamID: stream, sourcePTS: 100, stroke: .forehand, confidence: 0.5)
        var window = ClipExport.window(for: shot)
        XCTAssertEqual(window.start, 98, accuracy: 1e-9); XCTAssertEqual(window.end, 103, accuracy: 1e-9)
        shot.bounce = TennisBounceEstimate(sourcePTS: 102, confidence: 0.5)
        window = ClipExport.window(for: shot)
        XCTAssertEqual(window.end, 103.5, accuracy: 1e-9)
        shot.bounce = TennisBounceEstimate(sourcePTS: 140, confidence: 0.5)
        window = ClipExport.window(for: shot)
        XCTAssertEqual(window.end - window.start, ClipExport.maxSeconds, accuracy: 1e-9)
        XCTAssertNoThrow(try ClipExport.validate(filename: ClipExport.filename(for: UUID())))
        XCTAssertThrowsError(try ClipExport.validate(filename: "clip-../x.mov"))
        XCTAssertThrowsError(try ClipExport.validate(filename: "Court-20261028.mov"))
    }

    // MARK: Helpers

    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CourtError.message("Timed out waiting for \(condition)") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func firstSampleIsKeyframe(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); reader.startReading()
        defer { reader.cancelReading() }
        return try ClipExport.isSync(XCTUnwrap(output.copyNextSampleBuffer()))
    }
    private func decodeMovie(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CourtError.message("decode") }
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        guard reader.status == .completed else { throw reader.error ?? CourtError.message("decode") }
        return count
    }
}
#endif
