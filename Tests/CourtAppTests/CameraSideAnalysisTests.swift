#if os(macOS)
import XCTest
import CoreVideo
@testable import CourtCore

final class CameraSideAnalysisTests: XCTestCase {
    private var models: URL? {
        guard ReferenceChain.isAvailable else { return nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = ProcessInfo.processInfo.environment["COURT_ANALYSIS_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".local/AnalysisModels")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    func testCadenceReadsAnchorAdjacentAndPairFramesOnly() {
        var cadence = TennisFrameCadence(fps: 60)
        let stream = UUID()
        var needed: [Int] = []
        for i in 0..<21 {
            let restarted = cadence.advance(pts: Double(i) / 60, streamID: stream)
            XCTAssertEqual(restarted, i == 0)
            if cadence.needsPixels { needed.append(cadence.ordinal) }
        }
        XCTAssertEqual(needed, [6, 7, 8, 12, 13, 14, 18, 19, 20])
        // One missing 60 fps frame is a temporal break; so is a new stream.
        XCTAssertTrue(cadence.advance(pts: 22.0 / 60, streamID: stream)); XCTAssertEqual(cadence.ordinal, 1)
        XCTAssertFalse(cadence.advance(pts: 23.0 / 60, streamID: stream))
        XCTAssertTrue(cadence.advance(pts: 24.0 / 60, streamID: UUID()))
        cadence.restart(); XCTAssertTrue(cadence.advance(pts: 25.0 / 60, streamID: stream)); XCTAssertEqual(cadence.ordinal, 1)
    }

    func testTicksWithoutPixelsMatchFullFrameAnalysis() throws {
        guard let models else { throw XCTSkip("Prepare real model assets to run camera-side equivalence.") }
        let full = try ReferenceChain.makeEngine(configuration: .init(modelDirectory: models, nominalFPS: 60))
        let ticked = try ReferenceChain.makeEngine(configuration: .init(modelDirectory: models, nominalFPS: 60))
        var cadence = TennisFrameCadence(fps: 60)
        let stream = UUID()
        var fullRows: [String] = [], tickedRows: [String] = []
        // Whole snapshot as JSON, minus wall-clock timing and per-engine random row IDs.
        func row(_ snapshot: TennisAnalysisSnapshot) throws -> String {
            var copy = snapshot; copy.inferenceMilliseconds = 0
            for index in copy.events.indices { copy.events[index].id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))! }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(copy), as: UTF8.self)
        }
        for i in 0..<90 {
            let pixels = try Self.frame(index: i)
            let pts = 10 + Double(i) / 60
            cadence.advance(pts: pts, streamID: stream)
            if let snapshot = try full.process(pixels, pts: pts, streamID: stream) { fullRows.append(try row(snapshot)) }
            if let snapshot = try ticked.process(cadence.needsPixels ? pixels : nil, pts: pts, streamID: stream) { tickedRows.append(try row(snapshot)) }
        }
        XCTAssertEqual(fullRows.count, 14)
        XCTAssertEqual(fullRows, tickedRows)
        XCTAssertEqual(ticked.pixelMisses, 0)
        // A needed frame without pixels restarts the run instead of pairing non-adjacent images.
        let next = 10 + 90.0 / 60
        for offset in 0..<6 { XCTAssertNil(try ticked.process(nil, pts: next + Double(offset) / 60, streamID: stream)) }
        XCTAssertEqual(ticked.pixelMisses, 1)
    }

    func testAnalyzerNeverHoldsCaptureBuffersAndRestartsOnOverflow() throws {
        guard let models else { throw XCTSkip("Prepare real model assets to run the camera-side analyzer.") }
        let analyzer = CameraSideAnalyzer(configuration: .init(modelDirectory: models, nominalFPS: 60),
                                          maximumBuffers: 6, maximumPendingFrames: 24, loadProbeInterval: 0.5)
        try waitUntilReady(analyzer)
        // A source pool of two buffers stands in for AVCaptureVideoDataOutput: if the analyzer
        // retained any source frame, the third allocation would fail.
        let source = try Self.pool(threshold: 2)
        let stream = UUID()
        for i in 0..<240 {
            let pixels = try Self.frame(index: i, pool: source)
            analyzer.submit(pixels, pts: 20 + Double(i) / 60, streamID: stream)
        }
        let finished = expectation(description: "drained")
        var final: CameraSideAnalyzer.Metrics?
        analyzer.finish { _, metrics in final = metrics; finished.fulfill() }
        wait(for: [finished], timeout: 120)
        let metrics = try XCTUnwrap(final)
        XCTAssertEqual(metrics.submittedFrames, 240)
        XCTAssertGreaterThan(metrics.poolExhausted + metrics.queueOverflows, 0, "an unpaced burst must overflow the bounded lanes")
        XCTAssertGreaterThan(metrics.restarts, 1)
        XCTAssertEqual(metrics.pixelMisses, 0, "selector and engine must stay aligned across restarts")
        XCTAssertEqual(metrics.engineErrors, 0)
        XCTAssertGreaterThan(metrics.pairs, 0)
        XCTAssertGreaterThan(metrics.probes, 0)
        XCTAssertEqual(metrics.pendingFrames, 0)
    }

    func testEngineErrorResynchronizesSelectorWithoutPixelMisses() throws {
        guard let models else { throw XCTSkip("Prepare real model assets to run the camera-side analyzer.") }
        let analyzer = CameraSideAnalyzer(configuration: .init(modelDirectory: models, nominalFPS: 60))
        try waitUntilReady(analyzer)
        let source = try Self.pool(threshold: 2), stream = UUID()
        func drainWorker() {
            let deadline = Date().addingTimeInterval(10)
            while analyzer.currentMetrics.pendingFrames > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        for i in 0..<60 { analyzer.submit(try Self.frame(index: i, pool: source), pts: 40 + Double(i) / 60, streamID: stream) }
        drainWorker()
        let before = analyzer.currentMetrics.pairs
        // An invalid timestamp makes the engine throw; the worker resets it and asks the selector to restart.
        analyzer.submit(try Self.frame(index: 60, pool: source), pts: .nan, streamID: stream)
        drainWorker()
        for i in 61..<180 { analyzer.submit(try Self.frame(index: i, pool: source), pts: 40 + Double(i) / 60, streamID: stream); if i % 6 == 0 { drainWorker() } }
        let finished = expectation(description: "drained")
        var final: CameraSideAnalyzer.Metrics?
        analyzer.finish { _, metrics in final = metrics; finished.fulfill() }
        wait(for: [finished], timeout: 60)
        let metrics = try XCTUnwrap(final)
        XCTAssertEqual(metrics.engineErrors, 1)
        XCTAssertEqual(metrics.resyncs, 1)
        XCTAssertEqual(metrics.pixelMisses, 0, "the restart marker must realign selector and engine")
        XCTAssertGreaterThanOrEqual(metrics.pairs - before, 18, "analysis resumes on the next cadence group")
    }

    /// Segment boundary semantics that replaced LiveAnalysisPipeline.finishTennisSegment.
    func testSealDrainsAdmittedFramesAndLateBounceThenRestartsNextSegment() throws {
        guard let models else { throw XCTSkip("Prepare real model assets to run segment sealing.") }
        let analyzer = CameraSideAnalyzer(configuration: .init(modelDirectory: models, nominalFPS: 60))
        try waitUntilReady(analyzer)
        let source = try Self.pool(threshold: 2), stream = UUID()
        let updates = SealState()
        analyzer.onEventUpdate = { rows in updates.add(rows) }
        try feed(analyzer, source: source, stream: stream, frames: 0..<60, base: 50)
        // A bounce job still running at seal time must land before the seal reports.
        let row = TennisShotEvent(streamID: stream, sourcePTS: 50.5, stroke: .groundstroke, confidence: 0.5)
        analyzer.testingQueueBounce(for: row)
        let first = expectation(description: "first seal")
        var firstFinal: TennisAnalysisSnapshot?
        analyzer.seal { final, _ in firstFinal = final; first.fulfill() }
        wait(for: [first], timeout: 60)
        XCTAssertEqual(firstFinal?.processedFrames, 9, "Every admitted frame before the seal is analysed (60 frames → 9 pairs)")
        XCTAssertEqual(updates.rows.first?.id, row.id)
        XCTAssertNotNil(updates.rows.first?.bounce, "The late bounce result reaches the caller after the engine was sealed")
        XCTAssertNotEqual(updates.rows.first?.bounce?.reason, "等待独立队列触地定位")
        let restartsBefore = analyzer.currentMetrics.restarts
        try feed(analyzer, source: source, stream: stream, frames: 60..<120, base: 50)
        let second = expectation(description: "second seal")
        var secondFinal: TennisAnalysisSnapshot?
        analyzer.seal { final, _ in secondFinal = final; second.fulfill() }
        wait(for: [second], timeout: 60)
        XCTAssertEqual(analyzer.currentMetrics.restarts, restartsBefore + 1, "The next segment starts a new temporal run")
        XCTAssertEqual(secondFinal?.processedFrames, 9, "Pair counting restarts instead of bridging the boundary")
        XCTAssertGreaterThan(secondFinal?.pts ?? 0, firstFinal?.pts ?? .infinity)
        XCTAssertEqual(analyzer.currentMetrics.pixelMisses, 0)
    }

    func testPersonDetectionRunsWithoutTennisModels() throws {
        let analyzer = CameraSideAnalyzer(configuration: nil)
        try waitUntilReady(analyzer)
        let people = SealState()
        analyzer.onPeople = { snapshot in people.add([], samples: snapshot.sampleCount) }
        let source = try Self.pool(threshold: 2), stream = UUID()
        try feed(analyzer, source: source, stream: stream, frames: 0..<130, base: 0)
        let done = expectation(description: "drained")
        analyzer.finish { _, _ in done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(people.samples, 3, "One detection per source second: pts 0.08, 1.08 and 2.08 in a 2.15 s feed")
        XCTAssertFalse(analyzer.currentMetrics.tennisAvailable)
    }

    /// Real-time 60 fps feed on this Mac: a correctness check plus a printed timing baseline.
    /// Timing is not asserted; phone feasibility is measured on device (docs/camera-side-analysis.md).
    func testRealTimeFeedBaseline() throws {
        guard let models else { throw XCTSkip("Prepare real model assets to run the camera-side baseline.") }
        let analyzer = CameraSideAnalyzer(configuration: .init(modelDirectory: models, nominalFPS: 60), loadProbeInterval: 1.5)
        try waitUntilReady(analyzer)
        let source = try Self.pool(threshold: 4)
        let stream = UUID(), start = ProcessInfo.processInfo.systemUptime
        for i in 0..<300 {
            let due = start + Double(i) / 60
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            analyzer.submit(try Self.frame(index: i, pool: source), pts: 30 + Double(i) / 60, streamID: stream)
        }
        let finished = expectation(description: "drained")
        var final: CameraSideAnalyzer.Metrics?
        analyzer.finish { _, metrics in final = metrics; finished.fulfill() }
        wait(for: [finished], timeout: 60)
        let metrics = try XCTUnwrap(final), timings = analyzer.drainTimings()
        XCTAssertEqual(metrics.pixelMisses, 0); XCTAssertEqual(metrics.engineErrors, 0)
        func p(_ values: [Double], _ q: Double) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted(); return String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))])
        }
        print("CAMERA_SIDE_BASELINE pairs=\(metrics.pairs) restarts=\(metrics.restarts) pool=\(metrics.poolExhausted) overflow=\(metrics.queueOverflows)",
              "pair_p50=\(p(timings.pair, 0.5)) pair_p95=\(p(timings.pair, 0.95)) anchor_p50=\(p(timings.anchor, 0.5))",
              "copy_p50=\(p(timings.copy, 0.5)) probe_p50=\(p(timings.probe, 0.5)) probe_max=\(p(timings.probe, 1))",
              "busy=\(String(format: "%.2f", metrics.analysisBusySeconds / 5)) probes=\(metrics.probes)")
    }

    private final class SealState: @unchecked Sendable {
        private let lock = NSLock(); private var storedRows: [TennisShotEvent] = []; private var storedSamples = 0
        func add(_ rows: [TennisShotEvent], samples: Int? = nil) {
            lock.lock(); storedRows += rows; if let samples { storedSamples = samples }; lock.unlock()
        }
        var rows: [TennisShotEvent] { lock.lock(); defer { lock.unlock() }; return storedRows }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return storedSamples }
    }

    /// Paced so the bounded lanes never overflow: these tests are about boundaries, not overload.
    private func feed(_ analyzer: CameraSideAnalyzer, source: CVPixelBufferPool, stream: UUID, frames: Range<Int>, base: Double) throws {
        for i in frames {
            analyzer.submit(try Self.frame(index: i, pool: source), pts: base + Double(i) / 60, streamID: stream)
            if i % 6 == 5 {
                let deadline = Date().addingTimeInterval(10)
                while analyzer.currentMetrics.pendingFrames > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            }
        }
    }

    private func waitUntilReady(_ analyzer: CameraSideAnalyzer) throws {
        let deadline = Date().addingTimeInterval(90)
        while !analyzer.currentMetrics.ready {
            if let error = analyzer.currentMetrics.loadError { XCTFail(error); return }
            guard Date() < deadline else { XCTFail("models did not load"); return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func pool(threshold: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw CourtError.message("cannot create source pool")
        }
        objc_setAssociatedObject(pool, &thresholdKey, threshold, .OBJC_ASSOCIATION_RETAIN)
        return pool
    }
    private static var thresholdKey = 0

    /// Moving bright square on a gradient, NV12 video range (the camera's capture format).
    private static func frame(index: Int, pool: CVPixelBufferPool? = nil) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        if let pool {
            let threshold = (objc_getAssociatedObject(pool, &thresholdKey) as? Int) ?? 2
            let aux = [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &output)
            guard status == kCVReturnSuccess else { throw CourtError.message("source pool exhausted (\(status)): a source frame was retained") }
        } else {
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &output) == kCVReturnSuccess else {
                throw CourtError.message("cannot create frame")
            }
        }
        let buffer = try XCTUnwrap(output)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let x0 = (index * 24) % 1700, y0 = 300 + (index * 7) % 400
        for y in 0..<1080 {
            let row = luma + y * stride
            memset(row, Int32(16 + (y * 200) / 1080), 1920)
            if (y0..<(y0 + 40)).contains(y) { memset(row + x0, 235, 40) }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }
}
#endif
