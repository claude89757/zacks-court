import Foundation
import AVFoundation
import CourtCore

/// Developer-only device check, opted in with `COURT_AUTOPILOT=1` in the launch environment.
///
/// The camera role pairs from `Documents/autopilot-pairing.txt` (copied in with devicectl and
/// deleted right after reading; the secret is never logged), starts capture, records one short
/// session, finishes it, then stays connected for `linger` seconds so the display can pull the
/// recording. Everything goes to `Documents/Autopilot/`, never the user's own history.
public struct CameraAutopilot: Sendable {
    public let seconds: Double
    public let linger: Double
    public let run: URL

    public static let requested: CameraAutopilot? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COURT_AUTOPILOT"] == "1" else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return CameraAutopilot(seconds: min(600, Double(environment["COURT_AUTOPILOT_SECONDS"] ?? "") ?? 90),
                               linger: min(600, Double(environment["COURT_AUTOPILOT_LINGER"] ?? "") ?? 120),
                               run: documents.appendingPathComponent("Autopilot/\(formatter.string(from: Date()))", isDirectory: true))
    }()

    /// Separate session folder for the autopilot run.
    public var storage: URL { run.appendingPathComponent("Sessions", isDirectory: true) }

    @MainActor public func start(_ workspace: WorkspaceModel) async {
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let log = AutopilotLog(url: run.appendingPathComponent("log.jsonl"))
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ticketURL = documents.appendingPathComponent("autopilot-pairing.txt")
        let raw = try? String(contentsOf: ticketURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: ticketURL)
        log.add("start", ["seconds": seconds, "linger": linger, "ticket": raw != nil, "hardware": CameraModel.hardware])
        workspace.selectRole(.camera)
        guard let controller = workspace.camera.controller else { log.add("error", ["message": "no controller"]); return }
        if let raw { workspace.camera.pair(raw) }
        let started = Date()
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(200)) }
            return true
        }
        let paired = raw == nil ? false : await wait(60) { controller.linkState == .connected }
        log.add("link", ["connected": paired, "state": "\(controller.linkState)", "seconds": Date().timeIntervalSince(started)])
        await workspace.camera.startForMeasurement()
        let capturing = await wait(15) { workspace.camera.streaming && controller.capturing }
        let ready = await wait(60) { controller.metrics.ready }
        log.add("capture", ["capturing": capturing, "modelsReady": ready, "tennis": controller.metrics.tennisAvailable,
                            "loadSeconds": controller.metrics.loadSeconds ?? -1, "error": workspace.camera.error ?? ""])
        guard capturing else { await finish(workspace, log: log, note: "capture did not start"); return }
        // Zoom: the format's range, a 2× change before recording, and the lock while recording.
        // The user's saved factor is put back at the end.
        let camera = workspace.camera, savedZoom = camera.zoomFactor
        _ = await wait(3) { camera.zoomRange != nil }
        log.add("zoom-range", ["minimum": camera.zoomRange?.minimum ?? -1, "maximum": camera.zoomRange?.maximum ?? -1,
                               "multiplier": camera.zoomRange?.displayMultiplier ?? -1,
                               "lenses": camera.zoomRange?.lenses ?? [],
                               "presets": camera.zoomRange?.presets ?? [], "saved": savedZoom])
        // Each lens the camera offers: 0.5× ultra-wide, 4× telephoto (frames keep coming at 60 fps).
        for lens in (camera.zoomRange?.lenses ?? []) where abs(lens - 1) > 0.01 {
            camera.commitZoom(lens)
            let applied = await wait(3) { controller.status.zoom == lens }
            let delivered = controller.counters.delivered
            try? await Task.sleep(for: .seconds(2))
            log.add("zoom-lens", ["lens": lens, "applied": applied, "status": controller.status.zoom ?? -1,
                                  "framesIn2s": controller.counters.delivered - delivered, "error": camera.error ?? ""])
        }
        if camera.zoomRange != nil {
            camera.commitZoom(2)
            let zoomed = await wait(3) { controller.status.zoom == 2 }
            let delivered = controller.counters.delivered
            try? await Task.sleep(for: .seconds(2))
            log.add("zoom-set", ["applied": zoomed, "status": controller.status.zoom ?? -1,
                                 "framesIn2s": controller.counters.delivered - delivered, "error": camera.error ?? ""])
        }
        controller.startSession(title: "AUTOPILOT 机位验证")
        if camera.zoomRange != nil {
            _ = await wait(3) { camera.zoomLocked }
            camera.commitZoom(1.5)
            try? await Task.sleep(for: .seconds(1))
            log.add("zoom-locked", ["locked": camera.zoomLocked, "factor": camera.zoomFactor])
        }
        let sessionStart = Date()
        while Date().timeIntervalSince(sessionStart) < seconds {
            try? await Task.sleep(for: .seconds(5))
            log.status(controller.status, link: "\(controller.linkState)", rows: controller.session?.tennisEvents?.count ?? 0)
        }
        await controller.finish()
        camera.commitZoom(savedZoom)
        log.add("finished", ["recordings": controller.session?.recordings.count ?? 0, "rows": controller.session?.tennisEvents?.count ?? 0,
                             "gaps": controller.session?.analysisGaps?.count ?? 0])
        // Stay connected so the display can request the recording.
        let lingerStart = Date()
        while Date().timeIntervalSince(lingerStart) < linger, controller.linkState == .connected {
            try? await Task.sleep(for: .seconds(5))
            log.status(controller.status, link: "\(controller.linkState)", rows: controller.session?.tennisEvents?.count ?? 0)
        }
        await finish(workspace, log: log, note: nil)
    }

    @MainActor private func finish(_ workspace: WorkspaceModel, log: AutopilotLog, note: String?) async {
        let controller = workspace.camera.controller
        var summary: [String: Any] = ["hardware": CameraModel.hardware, "seconds": seconds,
                                      "field_accuracy_tested": false, "note": note ?? ""]
        if let controller {
            let metrics = controller.metrics, counters = controller.counters
            summary["session"] = controller.session?.id.uuidString ?? ""
            summary["rows"] = controller.session?.tennisEvents?.count ?? 0
            summary["recordings"] = controller.session?.recordings.map { ["file": $0.filename, "frames": $0.frames, "duration": $0.duration] } ?? []
            summary["captureDrops"] = counters.captureDrops
            summary["delivered"] = counters.delivered
            summary["previewSent"] = counters.previewSent; summary["previewDropped"] = counters.previewDropped
            summary["pairs"] = metrics.pairs; summary["restarts"] = metrics.restarts; summary["poolExhausted"] = metrics.poolExhausted
            summary["queueOverflows"] = metrics.queueOverflows; summary["personSamples"] = metrics.personSamples
            summary["bounceRequests"] = metrics.bounceRequests; summary["bounceResolved"] = metrics.bounceResolved
            summary["shedLevel"] = controller.shed.level
            summary["thermal"] = controller.status.device.thermal
            summary["battery"] = controller.status.device.battery ?? -1
        }
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: run.appendingPathComponent("summary.json"))
        }
        log.add("done", ["note": note ?? ""])
        workspace.camera.stop()
    }
}

/// Append-only JSON lines; contains no pairing data.
private final class AutopilotLog: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url; FileManager.default.createFile(atPath: url.path, contents: nil) }
    func add(_ event: String, _ fields: [String: Any]) {
        var object = fields; object["event"] = event; object["t"] = Date().timeIntervalSince1970
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close() }
    }
    func status(_ status: CameraStatus, link: String, rows: Int) {
        guard let data = try? JSONEncoder().encode(status), let object = try? JSONSerialization.jsonObject(with: data) else { return }
        add("status", ["status": object, "link": link, "rows": rows])
    }
}
