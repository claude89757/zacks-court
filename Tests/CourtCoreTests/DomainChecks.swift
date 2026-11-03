import Foundation
import CourtCore
import CoreVideo
import CoreMedia
import VideoToolbox

/// Invoked by court-check's existing entry point.
func runDomainChecks() throws {
    checkTracking()
    try checkSessionStorage()
    try checkPersonOnlyAnalyzer()
    try checkCameraMediaPipeline()
    print("PASS: tracking expiry/discontinuity, session recovery and safe persistence, person-only analyzer drain")
}

private func checkTracking() {
    let tracker = PersonTracker(), stream = UUID()
    func detection(_ x: Double = 0.2) -> PersonDetection {
        PersonDetection(box: NormalizedBox(x: x, y: 0.2, width: 0.1, height: 0.4), confidence: 0.9)
    }
    var snapshot = tracker.update(detections: [detection()], streamID: stream, pts: 1)
    let firstID = snapshot.people[0].id
    expectEqual(snapshot.people[0].trail[0].y, 0.6000000000000001)
    snapshot = tracker.update(detections: [detection(0.23)], streamID: stream, pts: 1.2)
    expectEqual(snapshot.people[0].id, firstID)
    snapshot = tracker.update(detections: [], streamID: stream, pts: 1.4); expectEqual(snapshot.people.count, 0)
    snapshot = tracker.update(detections: [detection(0.25)], streamID: stream, pts: 1.6)
    expectEqual(snapshot.people[0].id, firstID); expectEqual(snapshot.people[0].isMoving, true)
    _ = tracker.update(detections: [], streamID: stream, pts: 2.5)
    snapshot = tracker.update(detections: [detection()], streamID: stream, pts: 2.6)
    precondition(snapshot.people[0].id != firstID)
    let secondID = snapshot.people[0].id
    snapshot = tracker.update(detections: [detection()], streamID: stream, pts: 0.2)
    precondition(snapshot.people[0].id != secondID); expectEqual(snapshot.sampleCount, 1)
    let thirdID = snapshot.people[0].id
    snapshot = tracker.update(detections: [detection()], streamID: UUID(), pts: 0.4)
    precondition(snapshot.people[0].id != thirdID); expectEqual(snapshot.heatmap.reduce(0, +), 1)
    snapshot = tracker.update(detections: [detection()], streamID: stream, pts: .nan)
    expectEqual(snapshot.people.count, 0); expectEqual(snapshot.sampleCount, 0)
    let invalid = PersonDetection(box: NormalizedBox(x: -1, y: 0, width: 0.2, height: 0.3), confidence: 1)
    snapshot = tracker.update(detections: [invalid], streamID: stream, pts: 3)
    expectEqual(snapshot.people.count, 0)
}

private func checkSessionStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(directory: root)
    let start = Date(timeIntervalSince1970: 1_000)
    var session = CourtSession(title: "Practice", kind: .training, startedAt: start)
    session.pause(at: start.addingTimeInterval(10)); expectEqual(session.elapsed(at: start.addingTimeInterval(40)), 10)
    session.resume(at: start.addingTimeInterval(50)); expectEqual(session.elapsed(at: start.addingTimeInterval(60)), 20)
    session.addMarker("Backhand", at: start.addingTimeInterval(60), sourcePTS: 4.2)
    try session.addRecording(StoredRecording(filename: "clip.mov", frames: 30, duration: 1, firstPTS: 3.2))
    try store.save(session, at: start.addingTimeInterval(65))
    let restored = try store.loadAll()[0]
    expectEqual(restored.state, .interrupted); expectEqual(restored.elapsed(), 25)
    expectEqual(restored.events.first(where: { $0.kind == .marker })?.sourcePTS, 4.2)
    expectEqual(restored.recordings[0].filename, "clip.mov")
    expectEqual(try store.loadAll()[0].events.filter { $0.kind == .interruption }.count, 1)
    var finished = restored; finished.resume(at: start.addingTimeInterval(80)); finished.finish(at: start.addingTimeInterval(85))
    expectEqual(finished.elapsed(), 30); try store.save(finished)
    expectEqual(try store.loadAll()[0].state, .completed)
    expectThrows(try store.recordingURL(filename: "../clip.mov"))
    expectThrows(try store.recordingURL(filename: "/tmp/clip.mov"))
    let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.mov"), withDestinationURL: outside)
    expectThrows(try store.recordingURL(filename: "escape.mov"))
    let mismatchedURL = store.sessionFileURL(id: UUID())
    try JSONEncoder().encode(finished).write(to: mismatchedURL)
    expectThrows(try store.loadAll())
    try FileManager.default.removeItem(at: mismatchedURL)
    try Data("broken".utf8).write(to: store.sessionFileURL(id: session.id), options: .atomic)
    expectThrows(try store.loadAll())
}

/// Camera-side analyzer without tennis models still runs real Vision person detection at 1 Hz
/// and emits nothing after finish. This is not a detection-accuracy claim.
private func checkPersonOnlyAnalyzer() throws {
    let analyzer = CameraSideAnalyzer(configuration: nil)
    let deadline = Date().addingTimeInterval(20)
    while !analyzer.currentMetrics.ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    precondition(analyzer.currentMetrics.ready, "analyzer never became ready")
    let lock = NSLock(); var samples = 0
    analyzer.onPeople = { _ in lock.lock(); samples += 1; lock.unlock() }
    let stream = UUID()
    for index in 0..<130 {
        var image: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        analyzer.submit(image!, pts: Double(index) / 60, streamID: stream)
        if index % 6 == 5 {
            let wait = Date().addingTimeInterval(10)
            while analyzer.currentMetrics.pendingFrames > 0 && Date() < wait { Thread.sleep(forTimeInterval: 0.002) }
        }
    }
    let done = DispatchSemaphore(value: 0)
    analyzer.finish { _, _ in done.signal() }
    precondition(done.wait(timeout: .now() + 30) == .success, "analyzer did not drain")
    lock.lock(); let counted = samples; lock.unlock()
    expectEqual(counted, 3)
    var late: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &late)
    analyzer.submit(late!, pts: 5, streamID: stream)
    Thread.sleep(forTimeInterval: 0.3)
    lock.lock(); let after = samples; lock.unlock()
    precondition(after == counted, "finished analyzer emitted a stale callback")
}

/// Real 1080p frames through the camera media pipeline: 8 Mbps local recording of every frame
/// while recording, and a 640×360 preview that survives wire framing and decodes.
private func checkCameraMediaPipeline() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("court-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let queue = DispatchQueue(label: "court.check.media")
    let pipeline = CameraMediaPipeline(queue: queue)
    let lock = NSLock()
    var previews: [StreamPacket] = [], recordings: [CameraMediaPipeline.Recording] = [], failure: String?
    pipeline.onPreview = { packet in
        guard let wire = try? packet.encoded() else { return false }
        var decoder = PacketDecoder()
        guard let decoded = try? decoder.append(wire), decoded.count == 1 else { return false }
        lock.lock(); previews.append(decoded[0]); lock.unlock(); return true
    }
    pipeline.onRecording = { result in
        lock.lock()
        switch result { case .success(let clip): recordings.append(clip); case .failure(let error): failure = error.localizedDescription }
        lock.unlock()
    }
    pipeline.onError = { message in lock.lock(); failure = message; lock.unlock() }
    var pool: CVPixelBufferPool?
    let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
    precondition(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess)
    let stream = queue.sync { pipeline.begin(width: 1920, height: 1080, fps: 60) }
    pipeline.setPreview(true)
    pipeline.startRecording(directory: folder, prefix: "check", owner: stream)
    for index in 0..<120 {
        var image: CVPixelBuffer?
        precondition(CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &image) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(image!, [])
        memset(CVPixelBufferGetBaseAddress(image!), Int32(index % 255), CVPixelBufferGetDataSize(image!))
        CVPixelBufferUnlockBaseAddress(image!, [])
        queue.sync { pipeline.submit(image!, pts: CMTime(value: Int64(6000 + index), timescale: 60)) }
        Thread.sleep(forTimeInterval: 1.0 / 120)
    }
    let stopped = DispatchSemaphore(value: 0)
    pipeline.stopRecording { stopped.signal() }
    precondition(stopped.wait(timeout: .now() + 20) == .success, "recording did not finish")
    pipeline.setPreview(false)
    queue.sync { pipeline.end() }
    Thread.sleep(forTimeInterval: 0.3)
    lock.lock(); let packets = previews, clips = recordings, error = failure; lock.unlock()
    precondition(error == nil, error ?? "")
    expectEqual(clips.count, 1)
    expectEqual(clips[0].frames, 120); expectEqual(clips[0].streamID, stream)
    precondition(packets.count >= 20, "only \(packets.count) preview frames for 120 source frames")
    precondition(packets.allSatisfy { $0.header.kind == "preview" && $0.header.width == 640 && $0.header.height == 360 })
    precondition(packets[0].header.keyframe == true, "preview must start at a keyframe")
    let assembler = H264SampleAssembler()
    let samples = try packets.compactMap { try assembler.sample(from: $0) }
    expectEqual(samples.count, packets.count)
    expectEqual(try decodeCount(samples), samples.count)
    print("PASS: camera media pipeline 120×1080p recorded, \(packets.count) preview frames 640×360 framed and decoded")
}

private func decodeCount(_ samples: [CMSampleBuffer]) throws -> Int {
    guard let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) else { return 0 }
    var session: VTDecompressionSession?
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                       imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
          let session else { throw CourtError.message("Cannot create decoder") }
    defer { VTDecompressionSessionInvalidate(session) }
    let lock = NSLock(); var decoded = 0
    for sample in samples {
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, image != nil { lock.lock(); decoded += 1; lock.unlock() }
        }
        guard status == noErr else { throw CourtError.message("Decode failed: \(status)") }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    lock.lock(); defer { lock.unlock() }; return decoded
}
