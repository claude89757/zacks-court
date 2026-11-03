import Foundation
import AVFoundation
import Network
import CourtCore
import VideoToolbox

/// court-probe (protocol v2)
///
///   court-probe                        wrong-key rejection + camera↔display loopback self-test
///   court-probe stream TICKET [SECS]   synthetic camera (labelled, no tennis facts) for a paired app
///   court-probe file TICKET VIDEO      prerecorded video replayed as a camera, analysed on this Mac
///   court-probe web [VIDEO]            this Mac as a camera serving the browser display (synthetic
///                                      frames, or VIDEO replayed and analysed); runs until stopped
///   court-probe live VIDEO OUT.json [singles|doubles]
///                                      VIDEO replayed as a camera with no display: the camera starts
///                                      its own session with line calls on for the whole court, and
///                                      writes the rows and how late each call came
///   court-probe import VIDEO DIR       the App's 「导入视频」 on this Mac: VIDEO through the camera
///                                      pipeline and the in-house live lane (needs COURT_PROBE_INDEPENDENT),
///                                      saved as a finished record in sessions folder DIR
///   court-probe demo-session DIR       writes one labelled session of made-up shots into DIR (an
///                                      app's `Zacks Court/Sessions` folder) for screenshots
///
/// The camera modes run the same `CameraSessionController` + `CameraMediaPipeline` as the app's
/// camera role, so the display sees the real v2 message flow. None of this is a field test.
/// `COURT_PROBE_INDEPENDENT=DIR` (the staged `tracknetv3-base-fp16-v1` folder) analyses a VIDEO with
/// the in-house live chain, as the app's 自研 camera does, instead of the S家 models.
@main struct CourtProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "file":
                guard arguments.count == 3 else { throw CourtError.message("Usage: court-probe file TICKET_FILE VIDEO_PATH") }
                try await runCamera(ticket: try loadTicket(arguments[1]), video: URL(fileURLWithPath: arguments[2]), seconds: nil)
            case "web":
                try await runWebCamera(video: arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : nil)
            case "live":
                guard arguments.count >= 3 else { throw CourtError.message("Usage: court-probe live VIDEO OUT.json [singles|doubles]") }
                let format = arguments.count > 3 ? HawkEyeFormat(rawValue: arguments[3]) ?? .singles : .singles
                try await runLiveCalls(video: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]), format: format)
            case "import":
                guard arguments.count == 3 else { throw CourtError.message("Usage: COURT_PROBE_INDEPENDENT=FP16_DIR court-probe import VIDEO SESSIONS_DIR") }
                try await runImport(video: URL(fileURLWithPath: arguments[1]), directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
            case "demo-session":
                guard arguments.count == 2 else { throw CourtError.message("Usage: court-probe demo-session SESSIONS_DIR") }
                try writeDemoSession(directory: URL(fileURLWithPath: arguments[1], isDirectory: true))
            case "stream":
                guard arguments.count >= 2 else { throw CourtError.message("Usage: court-probe stream TICKET_FILE [SECONDS]") }
                try await runCamera(ticket: try loadTicket(arguments[1]), video: nil, seconds: arguments.count > 2 ? Double(arguments[2]) ?? 15 : 15)
                print("Synthetic camera finished. This is not an iPhone or field test.")
            default:
                try await rejectWrongPairingKey()
                try await selfTest()
            }
        } catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func loadTicket(_ path: String) throws -> PairingTicket {
        try PairingTicket.parse(try String(contentsOfFile: path, encoding: .utf8))
    }

    static func rejectWrongPairingKey() async throws {
        let server = CourtServer()
        let ticket = try PairingTicket(name: "Authentication verification")
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let gate = CompletionGate()
            let finish: (Result<Void, Error>) -> Void = { if gate.take() { continuation.resume(returning: $0) } }
            server.onError = { finish(.failure(CourtError.message($0))) }
            server.onConnected = { finish(.failure(CourtError.message("Server accepted a wrong pairing key"))) }
            let rejected: (NWError) -> Void = { error in
                if case .tls = error { finish(.success(())) }
                else { finish(.failure(CourtError.message("Expected TLS rejection, got \(error)"))) }
            }
            server.onConnectionFailure = rejected
            server.onListening = { resolved in
                do {
                    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved)) as! [String: Any]
                    object["host"] = "127.0.0.1"
                    object["key"] = Data(repeating: 0x55, count: 32).base64EncodedString()
                    let wrong = try JSONDecoder().decode(PairingTicket.self, from: JSONSerialization.data(withJSONObject: object))
                    let connection = CourtConnection(NWConnection(to: wrong.endpoint(), using: wrong.parameters()), queue: server.queue)
                    // Retain the client until its terminal callback; all access stays on this queue.
                    connection.onReady = { finish(.failure(CourtError.message("Client authenticated with wrong key"))) }
                    connection.onFailure = rejected
                    connection.onClose = { reason in
                        connection.onClose = nil
                        finish(.failure(CourtError.message("Closed before TLS rejection: \(reason)")))
                    }
                    server.queue.asyncAfter(deadline: .now() + 10) { connection.close() }
                    connection.start()
                } catch { finish(.failure(error)) }
            }
            server.start(ticket: ticket)
            server.queue.asyncAfter(deadline: .now() + 10) { finish(.failure(CourtError.message("Authentication test timed out"))) }
        }
        server.stop()
        try result.get()
        print("PASS: TLS rejects a client with the wrong pairing key")
    }

    /// Camera controller with synthetic frames ↔ a minimal display over real TLS on localhost:
    /// handshake, display-started session adopted by the camera, 3 s recorded on the camera,
    /// low-resolution preview decoded on the display, capture end pauses, display finishes.
    @MainActor static func selfTest() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/probe-\(UUID().uuidString)")
        let display = ProbeDisplay()
        let ticket = try PairingTicket(name: "Loopback verification")
        let listening: PairingTicket = try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate()
            display.server.onListening = { if gate.take() { continuation.resume(returning: $0) } }
            display.server.onError = { if gate.take() { continuation.resume(throwing: CourtError.message($0)) } }
            display.server.start(ticket: ticket)
        }
        var local = listening; local.host = "127.0.0.1"
        let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.probe.camera", qos: .userInitiated))
        let camera = CameraSessionController(storageDirectory: folder, configuration: nil,
                                             identity: CameraIdentity(device: "合成测试机位（非 iPhone）", hardware: "court-probe", app: "court-probe"),
                                             pipeline: pipeline)
        let source = SyntheticFrameSource(pipeline: pipeline, seconds: 3)
        camera.pair(local)
        try await wait("camera hello", timeout: 10) { display.hello != nil }
        let started = CourtSession(title: "Loopback verification")
        display.sendHello(session: nil)
        var preview = WireControl(.preview); preview.enabled = true
        display.send(.control, preview)
        var start = WireControl(.start, sessionID: started.id); start.session = started
        display.send(.control, start)
        try await wait("camera adopts the display session", timeout: 5) { display.session?.id == started.id && display.session?.state == .active }
        source.start()
        try await wait("paused with one saved recording", timeout: 20) {
            display.session?.state == .paused && display.session?.recordings.count == 1 && !camera.isBusy
        }
        display.send(.control, WireControl(.finish, sessionID: started.id))
        try await wait("finished session", timeout: 10) { display.session?.state == .completed }
        await camera.shutdown()
        display.server.stop()

        let session = try XCTUnwrapLike(display.session, "session")
        let recording = try XCTUnwrapLike(session.recordings.first, "recording")
        let decoded = try await decodeMovie(folder.appendingPathComponent(recording.filename))
        let previews = display.previewSamples()
        let previewDecoded = try decodeCount(previews)
        guard session.capturedOn == "合成测试机位（非 iPhone）", recording.frames == 180, decoded.frames == 180,
              abs(decoded.duration - 3) < 0.02, abs(recording.firstPTS - 2000) < 0.001 else {
            throw CourtError.message("Recording check failed: frames=\(recording.frames) decoded=\(decoded.frames) duration=\(decoded.duration) firstPTS=\(recording.firstPTS)")
        }
        guard previews.count >= 20, previewDecoded == previews.count else {
            throw CourtError.message("Preview check failed: received=\(previews.count) decoded=\(previewDecoded)")
        }
        guard display.statusCount >= 2 else { throw CourtError.message("Expected camera status heartbeats, got \(display.statusCount)") }
        let summary: [String: Any] = ["test": "protocol v2 camera↔display TLS loopback", "source": "synthetic, not iPhone",
            "camera_recorded_frames": recording.frames, "camera_decoded_frames": decoded.frames,
            "duration_seconds": decoded.duration, "source_pts_start": recording.firstPTS,
            "preview_frames_received": previews.count, "preview_frames_decoded": previewDecoded,
            "status_messages": display.statusCount, "session_state": session.state.rawValue,
            "field_accuracy_tested": false]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
    }

    /// Runs as a camera for a paired display: capture starts at once, the display (or this
    /// tool, never) starts the session; the camera records and analyses whatever it adopts.
    @MainActor static func runCamera(ticket: PairingTicket, video: URL?, seconds: Double?) async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/probe-camera-\(UUID().uuidString)")
        let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.probe.camera", qos: .userInitiated))
        let models = AnalysisModelLocator.directory ?? {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/AnalysisModels")
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
        }()
        let independent = video == nil ? nil : independentAnalyzer()
        let configuration = video == nil || independent != nil ? nil : models.map { TennisAnalysisConfiguration(modelDirectory: $0) }
        let name = video == nil ? "合成测试机位（非 iPhone）" : "录像回放机位（非实时摄像头）"
        let camera = CameraSessionController(storageDirectory: folder, configuration: configuration,
                                             identity: CameraIdentity(device: name, hardware: "court-probe", app: "court-probe"), pipeline: pipeline,
                                             analyzer: independent)
        camera.pair(ticket)
        try await wait("display connection", timeout: 20) { camera.linkState == .connected }
        if video != nil, configuration == nil, independent == nil { print("No analysis models found: replay records only.") }
        let finished = CompletionFlag()
        if let video {
            let source = try await FileFrameSource(pipeline: pipeline, video: video)
            source.onFinished = { failure in finished.set(failure) }
            print("File replay: source \(String(format: "%.3f", source.nominalFPS)) fps, \(String(format: "%.3f", source.duration)) s. Source timestamps are preserved.")
            source.start()
            try await wait("replay end", timeout: max(45, source.duration * 2 + 30)) { finished.isSet }
        } else {
            let source = SyntheticFrameSource(pipeline: pipeline, seconds: seconds)
            source.onFinished = { finished.set(nil) }
            source.start()
            try await wait("synthetic end", timeout: (seconds ?? 15) + 30) { finished.isSet }
        }
        if let failure = finished.failure { throw CourtError.message(failure) }
        // Capture end pauses an open session; give the display time to finish it, then leave.
        let deadline = Date().addingTimeInterval(20)
        while camera.hasOpenSession && camera.linkState == .connected && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))
        await camera.shutdown()
        print("Camera simulator done: shots=\(camera.session?.tennisEvents?.count ?? 0) state=\(camera.session?.state.rawValue ?? "none"). Prerecorded or synthetic input, not a field test.")
    }

    /// Camera for browser displays only (docs/web-display.md). The QR URL and PIN are written to a
    /// 0600 file, never printed, because they unlock the camera.
    @MainActor static func runWebCamera(video: URL?) async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/probe-web-\(UUID().uuidString)")
        let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.probe.camera", qos: .userInitiated))
        let models = AnalysisModelLocator.directory ?? {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/AnalysisModels")
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
        }()
        let independent = video == nil ? nil : independentAnalyzer()
        let configuration = video == nil || independent != nil ? nil : models.map { TennisAnalysisConfiguration(modelDirectory: $0) }
        let name = video == nil ? "合成测试机位（非 iPhone）" : "录像回放机位（非实时摄像头）"
        let camera = CameraSessionController(storageDirectory: folder, configuration: configuration,
                                             identity: CameraIdentity(device: name, hardware: "court-probe", app: "court-probe"), pipeline: pipeline,
                                             analyzer: independent)
        let root = WebDisplayResources.directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/CourtCore/Web")
        camera.startWebDisplay(webRoot: root)
        try await wait("web listener", timeout: 10) { if case .listening = camera.webState { return true }; return false }
        let address = LocalNetwork.ipv4Addresses().first ?? "127.0.0.1"
        let url = try XCTUnwrapLike(camera.webURL(address: address), "url")
        let file = folder.appendingPathComponent("web-pairing.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("\(url)\n\(camera.webCredentials?.pin ?? "")\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        if case .listening(let port) = camera.webState {
            print("Browser display listening on http://\(address):\(port)/ — QR URL and PIN in \(file.path) (0600).")
        }
        if video != nil, configuration == nil, independent == nil { print("No analysis models found: replay records only.") }
        // Sources are kept alive for the whole run.
        var sources: [AnyObject] = []
        if let video {
            let source = try await FileFrameSource(pipeline: pipeline, video: video)
            print("File replay: \(String(format: "%.1f", source.duration)) s. Prerecorded input, not a field test.")
            source.start(); sources.append(source)
        } else {
            let source = SyntheticFrameSource(pipeline: pipeline, seconds: nil)
            source.start(); sources.append(source)
            print("Synthetic frames: no tennis facts. Not an iPhone or field test.")
        }
        while !sources.isEmpty { try await Task.sleep(for: .seconds(3600)) }
    }

    /// Camera alone, as on court with no display joined: records VIDEO at its own clock, judges every
    /// bounce, and notes when each call first appeared against the moment the bounce was played.
    @MainActor static func runLiveCalls(video: URL, output: URL, format: HawkEyeFormat) async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/probe-live-\(UUID().uuidString)")
        let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.probe.camera", qos: .userInitiated))
        let independent = independentAnalyzer()
        let models = AnalysisModelLocator.directory ?? {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/AnalysisModels")
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
        }()
        let configuration = independent != nil ? nil : models.map { TennisAnalysisConfiguration(modelDirectory: $0) }
        guard independent != nil || configuration != nil else { throw CourtError.message("No analysis models: set COURT_PROBE_INDEPENDENT or stage .local/AnalysisModels") }
        let camera = CameraSessionController(storageDirectory: folder, configuration: configuration,
                                             identity: CameraIdentity(device: "录像回放机位（非实时摄像头）", hardware: "court-probe", app: "court-probe"),
                                             pipeline: pipeline, analyzer: independent)
        camera.setHawkEye(HawkEyeSettings(enabled: true, format: format, farHalf: true))
        let source = try await FileFrameSource(pipeline: pipeline, video: video)
        let finished = CompletionFlag()
        source.onFinished = { failure in finished.set(failure) }
        print("Live calls: \(String(format: "%.1f", source.duration)) s replayed at its own clock. Prerecorded input, not a field test.")
        source.start()
        let started = Date()
        try await wait("capture", timeout: 20) { camera.streamID != nil }
        camera.startSession(title: "court-probe live calls")
        var firstSeen: [UUID: Double] = [:]
        while !finished.isSet {
            let now = Date().timeIntervalSince(started)
            for row in camera.session?.tennisEvents ?? [] where row.bounce?.hawkEye != nil && firstSeen[row.id] == nil { firstSeen[row.id] = now }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let failure = finished.failure { throw CourtError.message(failure) }
        await camera.finish()
        let rows = camera.session?.tennisEvents ?? []
        var lags: [Double] = []
        var calls: [[String: Any]] = []
        for row in rows {
            guard let b = row.bounce, let call = b.hawkEye else { continue }
            let lag = firstSeen[row.id].map { $0 - b.sourcePTS }
            if let lag { lags.append(lag) }
            calls.append(["hit": row.sourcePTS, "bounce": b.sourcePTS, "call": call.call.rawValue, "far": call.farHalf,
                          "distanceM": call.distanceM, "marginM": call.marginM, "lagSeconds": lag ?? NSNull()])
        }
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let eventsJSON = try JSONSerialization.jsonObject(with: try encoder.encode(rows))
        let report: [String: Any] = ["events": eventsJSON, "calls": calls, "note": "prerecorded video replayed on a Mac; lag is call time minus bounce time on the replay clock"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        lags.sort()
        let median = lags.isEmpty ? Double.nan : lags[lags.count / 2]
        let p90 = lags.isEmpty ? Double.nan : lags[min(lags.count - 1, Int(Double(lags.count) * 0.9))]
        print("Rows \(rows.count), calls \(calls.count) (out \(calls.filter { $0["call"] as? String == "out" }.count), close \(calls.filter { $0["call"] as? String == "close" }.count)); call lag median \(String(format: "%.2f", median)) s, p90 \(String(format: "%.2f", p90)) s")
        await camera.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Same code as the App's video import (`VideoImportRun`), with the staged FP16 model folder.
    @MainActor static func runImport(video: URL, directory: URL) async throws {
        guard let path = ProcessInfo.processInfo.environment["COURT_PROBE_INDEPENDENT"] else {
            throw CourtError.message("Set COURT_PROBE_INDEPENDENT to the staged tracknetv3-base-fp16-v1 folder")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let info = try await VideoImport.inspect(video)
        print("Import: \(info.summary). Prerecorded video on a Mac, not an iPhone or field test.")
        let run = VideoImportRun(storageDirectory: directory, live: IndependentLiveConfiguration(
            loadAssets: { try IndependentBallModelAssets.load(directory: folder, variant: .fp16) }))
        let started = Date()
        var lastPrinted = -10.0
        let session = try await run.run(video: video, info: info, title: VideoImport.title(for: info.filename)) { progress in
            if progress.analyzedSeconds - lastPrinted >= 5 {
                lastPrinted = progress.analyzedSeconds
                print(String(format: "  %.0f / %.0f s, %d shots", progress.analyzedSeconds, progress.totalSeconds, progress.shots))
            }
        }
        let rows = session.tennisEvents ?? []
        print("IMPORT_OK session=\(session.id) title=\(session.title) rows=\(rows.count) speeds=\(rows.filter { $0.speedKPH != nil }.count) bounces=\(rows.filter { $0.bounce != nil }.count) strokes=\(rows.filter { $0.stroke != .unknown }.count) recordings=\(session.recordings.count) frames=\(session.recordings.map(\.frames).reduce(0, +)) wall=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    /// The in-house live chain when `COURT_PROBE_INDEPENDENT` names the staged FP16 model folder.
    static func independentAnalyzer() -> CameraSideAnalyzer? {
        guard let path = ProcessInfo.processInfo.environment["COURT_PROBE_INDEPENDENT"] else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        print("In-house live chain (自研), model folder \(directory.lastPathComponent).")
        return CameraSideAnalyzer(configuration: nil, independent: IndependentLiveConfiguration(
            loadAssets: { try IndependentBallModelAssets.load(directory: directory, variant: .fp16) }))
    }

    @MainActor static func wait(_ condition: String, timeout: Double, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw CourtError.message("Timed out waiting for \(condition)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    static func XCTUnwrapLike<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CourtError.message("Missing \(name)") }
        return value
    }

    static func decodeMovie(_ url: URL) async throws -> (frames: Int, duration: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("No video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); guard reader.startReading() else { throw CourtError.message("Cannot decode recording") }
        var decoded = 0, last = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts > last else { throw CourtError.message("Non-monotonic output timestamps") }
            last = pts; decoded += 1
        }
        guard reader.status == .completed else { throw reader.error ?? CourtError.message("Decode incomplete") }
        return (decoded, duration)
    }

    static func decodeCount(_ samples: [CMSampleBuffer]) throws -> Int {
        guard let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) else { return 0 }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { throw CourtError.message("Cannot create decoder") }
        defer { VTDecompressionSessionInvalidate(session) }
        let lock = NSLock(); var decoded = 0
        for sample in samples {
            _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, image != nil { lock.lock(); decoded += 1; lock.unlock() }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        lock.lock(); defer { lock.unlock() }; return decoded
    }
}

/// Minimal display for the self-test: hello, mirror of the camera's session, preview samples.
@MainActor final class ProbeDisplay {
    let server = CourtServer()
    private(set) var hello: WireHello?
    private(set) var session: CourtSession?
    private(set) var statusCount = 0
    private let assembler = H264SampleAssembler()
    private let lock = NSLock()
    private nonisolated(unsafe) var samples: [CMSampleBuffer] = []

    init() {
        server.onPacket = { [weak self] packet in
            guard let self else { return }
            if packet.header.kind == WireKind.preview.rawValue {
                if let sample = try? self.assembler.sample(from: packet) { self.lock.lock(); self.samples.append(sample); self.lock.unlock() }
                return
            }
            Task { @MainActor in self.receive(packet) }
        }
    }
    private func receive(_ packet: StreamPacket) {
        switch packet.wireKind {
        case .hello: hello = try? packet.decode(WireHello.self)
        case .session: session = try? packet.decode(CourtSession.self)
        case .status: if !packet.payload.isEmpty { statusCount += 1 }
        default: break
        }
    }
    func sendHello(session: CourtSession?) {
        send(.hello, WireHello(role: .display, device: "court-probe 看板", hardware: "court-probe", app: "court-probe", session: session))
    }
    func send<T: Encodable>(_ kind: WireKind, _ body: T) {
        if let packet = try? StreamPacket.message(kind, body) { server.send(packet) }
    }
    nonisolated func previewSamples() -> [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return samples }
}

final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock(); private var completed = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if completed { return false }; completed = true; return true }
}

final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false; private var message: String?
    func set(_ failure: String?) { lock.lock(); if !done { done = true; message = failure }; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return message }
}
