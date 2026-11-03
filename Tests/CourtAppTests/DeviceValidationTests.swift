#if os(macOS)
import XCTest
import Foundation
import AVFoundation
import CourtCore
@testable import CourtApp

/// Opt-in physical-device check: this Mac acts as the display (real `WorkspaceModel`), a
/// physical iPhone runs the app's camera autopilot (`COURT_AUTOPILOT=1`). The pairing ticket is
/// written to a 0600 file under `.local/` and never printed.
///
///   COURT_DEVICE_DISPLAY=1 swift test --filter DeviceValidationTests
///
/// It records what the display saw (liveness, analysis delay, data and preview rates, rows, the
/// link path), fetches one 5 s clip while the camera records, then pulls the first recording and
/// lets the receiver verify its SHA-256. One indoor run on one device: not a field, heat, battery
/// or accuracy result.
final class DeviceValidationTests: XCTestCase {
    @MainActor func testDisplayMirrorsPhysicalCamera() async throws {
        guard ProcessInfo.processInfo.environment["COURT_DEVICE_DISPLAY"] == "1" else {
            throw XCTSkip("Set COURT_DEVICE_DISPLAY=1 and launch the iPhone autopilot to run the device check.")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = repository.appendingPathComponent(".local/device-run-\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        display.selectRole(.server)
        try await waitFor("ticket", timeout: 15) { !display.pairingURL.isEmpty }
        let ticketFile = root.appendingPathComponent("pairing.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: ticketFile.path, contents: Data(display.pairingURL.utf8), attributes: [.posixPermissions: 0o600]))
        print("DEVICE_RUN ticket_file=\(ticketFile.path) addresses=\(display.addresses.count)")
        try await waitFor("camera connection", timeout: 300) { display.connected && display.cameraStatus != nil }
        let connectedAt = Date()
        display.previewVisible(true)
        var samples: [[String: Any]] = [], liveSeconds = 0, notLiveAfterLive = 0, wasLive = false
        var delays: [Double] = [], rates: [Double] = [], previews: [Double] = []
        // Phase 3: one clip of the last 5 s, fetched while the camera records (no shots are needed;
        // the camera cuts by stream and time).
        var clip: [String: Any] = ["requested": false]
        let deadline = Date().addingTimeInterval(900)
        while display.session?.state != .completed || !display.cameraOwnsSession {
            guard Date() < deadline else { throw CourtError.message("No completed camera session within 15 minutes") }
            try await Task.sleep(for: .seconds(1))
            let status = display.cameraStatus
            if display.isLive { liveSeconds += 1; wasLive = true } else if wasLive && display.hasActiveSession { notLiveAfterLive += 1 }
            if let gap = display.analysisProgressGap { delays.append(gap) }
            if display.connected { rates.append(display.linkStats.kilobytesPerSecond) }
            if status?.previewing == true { previews.append(display.linkStats.previewFPS) }
            if clip["requested"] as? Bool == false, display.isRecording, (status?.recordingSeconds ?? 0) > 15,
               let session = display.session?.id, let stream = status?.analysis.streamID, let latest = status?.analysis.latestPTS {
                clip["requested"] = true
                let shot = TennisShotEvent(streamID: stream, sourcePTS: latest - 3, stroke: .unknown, confidence: 0)
                let started = Date(), rowsBefore = display.dashboardEvents.count
                let url = await display.fetchClip(session: session, shot: shot)
                clip["seconds"] = Date().timeIntervalSince(started)
                clip["error"] = display.clip?.progress.error ?? NSNull()
                clip["live_after"] = display.isLive
                clip["rows_before"] = rowsBefore
                if let url {
                    clip["bytes"] = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
                    clip["frames"] = (try? await Self.decodedFrames(url)) ?? -1
                }
            }
            samples.append(["t": Date().timeIntervalSince(connectedAt), "live": display.isLive, "rows": display.dashboardEvents.count,
                            "sessionRows": display.session?.tennisEvents?.count ?? 0, "kbps": display.linkStats.kilobytesPerSecond,
                            "previewFPS": display.linkStats.previewFPS, "delay": display.analysisProgressGap ?? -1,
                            "fps": status?.fps ?? 0, "captureDrops": status?.captureDrops ?? 0, "thermal": status?.device.thermal ?? "",
                            "battery": status?.device.battery ?? -1, "shed": status?.shed ?? -1, "screen": status?.device.screen ?? ""])
        }
        display.previewVisible(false)
        let session = try XCTUnwrap(display.session)
        let recording = try XCTUnwrap(session.recordings.first)
        let transferStart = Date()
        display.transferRecording(session, recording)
        try await waitFor("recording transfer", timeout: 600) { display.transfer?.done == true || display.transfer?.error != nil }
        let transferSeconds = Date().timeIntervalSince(transferStart)
        XCTAssertNil(display.transfer?.error)
        let transferred = display.storageDirectory.appendingPathComponent(recording.filename)
        let size = (try? FileManager.default.attributesOfItem(atPath: transferred.path))?[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 0, "The transferred recording must be in the display's session folder")
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return -1 }
            let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let report: [String: Any] = [
            "test": "physical camera autopilot → Mac display over local network", "field_accuracy_tested": false,
            "camera": display.deviceName, "session_rows": session.tennisEvents?.count ?? 0, "recordings": session.recordings.count,
            "recording_frames": recording.frames, "recording_seconds": recording.duration,
            "live_seconds": liveSeconds, "not_live_while_session_open": notLiveAfterLive,
            "analysis_delay_p50": percentile(delays, 0.5), "analysis_delay_p95": percentile(delays, 0.95), "analysis_delay_max": delays.max() ?? -1,
            "link_kb_per_s_p50": percentile(rates, 0.5), "link_kb_per_s_max": rates.max() ?? -1,
            "preview_fps_p50": percentile(previews, 0.5),
            "transfer_bytes": size, "transfer_seconds": transferSeconds,
            "transfer_mb_per_s": transferSeconds > 0 ? Double(size) / 1_048_576 / transferSeconds : -1,
            "transfer_verified_sha256": display.transfer?.done == true,
            "link_path": display.linkPath?.rawValue ?? "unknown", "peer_to_peer_listening": display.peerToPeerEnabled,
            "clip_while_recording": clip,
            "samples": samples]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("display-report.json"))
        try? FileManager.default.removeItem(at: ticketFile)
        print("DEVICE_RUN report=\(root.appendingPathComponent("display-report.json").path)")
        await display.shutdown()
    }

    private static func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { return -1 }
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        return reader.status == .completed ? count : -1
    }

    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CourtError.message("Timed out waiting for \(condition)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
