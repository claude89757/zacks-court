#if os(macOS)
import XCTest
import Foundation
import AVFoundation
@testable import CourtCore
@testable import CourtApp

/// Browser display (docs/web-display.md) against the in-process camera on localhost: the test
/// plays the browser with URLSessionWebSocketTask and URLSession. Synthetic frames and injected
/// shot rows prove the software path only, not any phone, tablet, hotspot or tennis accuracy.
final class WebDisplayTests: XCTestCase {
    private var roots: [URL] = []

    /// The browser display is the main way to connect, so it is on until the user turns it off,
    /// and a user's "off" is kept.
    @MainActor func testBrowserDisplayIsOnByDefaultAndRemembersOff() {
        let key = "court.web-display.enabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(CameraModel().webDisplayEnabled, "On when never set")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(CameraModel().webDisplayEnabled, "Off stays off")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(CameraModel().webDisplayEnabled)
    }
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    // MARK: Framing and credentials

    func testHTTPAndWebSocketFraming() throws {
        let head = Data("GET /api/session?id=abc&k=12 HTTP/1.1\r\nHost: x\r\nRange: bytes=10-\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(try WebHTTPRequest.parse(head))
        XCTAssertEqual(parsed.request.path, "/api/session")
        XCTAssertEqual(parsed.request.query["k"], "12")
        XCTAssertEqual(parsed.request.byteRange(size: 100), 10...99)
        XCTAssertNil(try WebHTTPRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)), "Incomplete head waits for more")
        var ranged = parsed.request
        ranged.headers["range"] = "bytes=-20"; XCTAssertEqual(ranged.byteRange(size: 100), 80...99)
        ranged.headers["range"] = "bytes=5-9"; XCTAssertEqual(ranged.byteRange(size: 100), 5...9)
        ranged.headers["range"] = "bytes=200-"; XCTAssertNil(ranged.byteRange(size: 100))
        ranged.headers["range"] = "bytes=0-1,4-5"; XCTAssertNil(ranged.byteRange(size: 100))

        // RFC 6455 §1.3 example.
        XCTAssertEqual(WebSocketFrame.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let mask: [UInt8] = [1, 2, 3, 4], text = Array("hello".utf8)
        var frame = Data([0x81, 0x80 | UInt8(text.count)] + mask)
        frame.append(contentsOf: text.enumerated().map { $1 ^ mask[$0 & 3] })
        var decoder = WebSocketFrame.Decoder()
        XCTAssertTrue(try decoder.append(frame.prefix(4)).isEmpty, "Partial frame waits")
        let frames = try decoder.append(frame.dropFirst(4))
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames.first?.0, .text)
        XCTAssertEqual(frames.first.map { String(decoding: $0.1, as: UTF8.self) }, "hello")
        var unmasked = WebSocketFrame.Decoder()
        XCTAssertThrowsError(try unmasked.append(Data([0x81, 0x01, 0x41])), "Browser frames must be masked")
        XCTAssertEqual(WebSocketFrame.encode(.text, Data(count: 300)).prefix(4), Data([0x81, 126, 0x01, 0x2C]))

        let credentials = WebDisplayCredentials.make()
        XCTAssertTrue(credentials.isValid())
        XCTAssertEqual(credentials.pin.count, 6); XCTAssertTrue(credentials.pin.allSatisfy(\.isNumber))
        XCTAssertGreaterThanOrEqual(credentials.token.count, 43)
        XCTAssertNotEqual(credentials.withNewPIN().pin, credentials.pin)
        // Same HMAC the page computes in JavaScript.
        let known = WebDisplayCredentials(token: "key", pin: "000000", expires: .distantFuture)
        XCTAssertEqual(known.mac(nonce: "The quick brown fox jumps over the lazy dog"),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        XCTAssertFalse(WebDisplayCredentials(token: credentials.token, pin: "123456", expires: Date().addingTimeInterval(-1)).isValid())
    }

    func testDatesAreMillisecondsForBrowsers() throws {
        let session = CourtSession(title: "日期", startedAt: Date(timeIntervalSince1970: 1_800_000_000.5))
        let data = try WebWire.envelope("session", session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "session")
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        XCTAssertEqual(body["startedAt"] as? Double, 1_800_000_000_500)
        var control = WireControl(.marker); control.date = Date(timeIntervalSince1970: 2)
        let incoming = Data(#"{"kind":"control","body":{"id":"\#(control.id.uuidString)","command":"marker","date":2000}}"#.utf8)
        XCTAssertEqual(try WebWire.body(WireControl.self, from: incoming).date, control.date)
    }

    // MARK: Authentication

    @MainActor func testAuthenticationTokenPinAndExpiry() async throws {
        let rig = CameraRig(root: makeRoot("court-web-auth"))
        let saved = SavedCredentials()
        rig.camera.onWebCredentials = { saved.value = $0 }
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let credentials = try XCTUnwrap(rig.camera.webCredentials)
        XCTAssertEqual(saved.value, credentials, "New credentials are handed to the app to persist")
        XCTAssertEqual(rig.camera.webURL(address: "192.168.1.5"), "http://192.168.1.5:\(port)/#t=\(credentials.token)")

        // Wrong token: refused and closed.
        let forged = TestBrowser(port: port)
        let refused = try await forged.authenticate(mac: WebDisplayCredentials(token: String(repeating: "x", count: 43), pin: "000000", expires: .distantFuture))
        XCTAssertFalse(refused.ok); XCTAssertNotNil(refused.message)
        forged.close()

        // Four wrong PINs are counted; the fifth replaces the PIN.
        let guesser = TestBrowser(port: port)
        _ = try await guesser.challenge()
        let wrong = credentials.pin == "000000" ? "111111" : "000000"
        for attempt in 1...WebDisplayServer.maxPINFailures {
            let result = try await guesser.send(pin: wrong)
            XCTAssertFalse(result.ok)
            if attempt < WebDisplayServer.maxPINFailures { XCTAssertTrue(result.message?.contains("还可再试") == true, result.message ?? "") }
        }
        try await waitFor("new PIN", timeout: 5) { rig.camera.webCredentials?.pin != credentials.pin }
        let rotated = try XCTUnwrap(rig.camera.webCredentials)
        XCTAssertEqual(rotated.token, credentials.token, "Wrong PINs change only the PIN")
        XCTAssertEqual(saved.value, rotated)
        let stale = try await guesser.send(pin: credentials.pin)
        XCTAssertFalse(stale.ok, "The old PIN no longer works")
        let correct = try await guesser.send(pin: rotated.pin)
        XCTAssertTrue(correct.ok)
        XCTAssertEqual(correct.token, rotated.token, "A correct PIN hands the page the token")
        XCTAssertNotNil(correct.access)
        guesser.close()

        // Refreshing the pairing disconnects everyone and invalidates the old token.
        let browser = TestBrowser(port: port)
        let joined = try await browser.authenticate(mac: rotated)
        XCTAssertTrue(joined.ok)
        rig.camera.refreshWebCredentials()
        try await waitFor("browser dropped", timeout: 5) { browser.isClosed }
        let old = TestBrowser(port: port)
        let afterRefresh = try await old.authenticate(mac: rotated)
        XCTAssertFalse(afterRefresh.ok)
        old.close()
        await rig.close()
        XCTAssertNil(saved.value, "Leaving the camera role forgets the credentials")
    }

    // MARK: Data, control and catch-up

    @MainActor func testTwoBrowsersControlTheCameraAndCatchUp() async throws {
        let rig = CameraRig(root: makeRoot("court-web-control"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let credentials = try XCTUnwrap(rig.camera.webCredentials)
        let first = TestBrowser(port: port), second = TestBrowser(port: port)
        do {
            for browser in [first, second] {
                let result = try await browser.authenticate(mac: credentials)
                XCTAssertTrue(result.ok); XCTAssertNil(result.token, "The token never travels after a QR login")
                browser.hello()
            }
            try await waitFor("two browsers", timeout: 5) { rig.camera.webClients == 2 }
            try await waitFor("camera hello and status", timeout: 5) { first.count("hello") == 1 && first.count("status") >= 1 }
            XCTAssertEqual(first.last("hello")?["role"] as? String, "camera")
            XCTAssertTrue((first.last("hello")?["capabilities"] as? [String])?.contains("web") == true)

            rig.source.start()
            try await waitFor("capturing", timeout: 10) { rig.camera.capturing && rig.camera.counters.latestPTS != nil }
            // A browser starts with a title only; the camera creates the session.
            let start = first.control("start", ["label": "浏览器开始"])
            try await waitFor("start reply", timeout: 10) { first.reply(to: start) != nil }
            XCTAssertEqual(first.reply(to: start)?["ok"] as? Bool, true)
            XCTAssertNil(second.reply(to: start), "Replies go only to the browser that asked")
            let session = try XCTUnwrap(rig.camera.session)
            XCTAssertEqual(session.title, "浏览器开始")
            try await waitFor("both see the session", timeout: 5) {
                [first, second].allSatisfy { $0.last("session")?["state"] as? String == "active" }
            }

            // Shot rows reach both browsers as deltas.
            let stream = try XCTUnwrap(rig.camera.streamID)
            // The pipeline's own counter: the controller's copy is refreshed once a second and can
            // lag behind the session's start, which filters rows before it.
            let pts = try XCTUnwrap(rig.pipeline.currentCounters.latestPTS)
            let shot = TennisShotEvent(streamID: stream, sourcePTS: pts, stroke: .serve, confidence: 0.8, speedKPH: 150)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [shot]))
            try await waitFor("shot reaches both", timeout: 5) { [first, second].allSatisfy { $0.shotIDs.contains(shot.id.uuidString) } }
            // The camera sends the App's wording, so the page needs no reason table of its own.
            let row = try XCTUnwrap(first.analysis.flatMap { $0["events"] as? [[String: Any]] ?? [] }.last { $0["id"] as? String == shot.id.uuidString })
            XCTAssertNil(row["speedReasonText"], "A shot with a speed has no speed reason")
            XCTAssertEqual(row["placementReasonText"] as? String, TennisReason.noBounceSeen.text)

            // A second start while one is open is refused with the reason; the second browser pauses.
            let again = second.control("start", ["label": "重复"])
            try await waitFor("refused", timeout: 5) { second.reply(to: again) != nil }
            XCTAssertEqual(second.reply(to: again)?["ok"] as? Bool, false)
            XCTAssertTrue((second.reply(to: again)?["message"] as? String)?.contains("浏览器开始") == true)
            let pause = second.control("pause", ["sessionID": session.id.uuidString])
            try await waitFor("paused", timeout: 20) { second.reply(to: pause) != nil && !rig.camera.isBusy }
            XCTAssertEqual(second.reply(to: pause)?["ok"] as? Bool, true)
            XCTAssertEqual(rig.camera.session?.state, .paused)
            try await waitFor("first sees pause", timeout: 5) { first.last("session")?["state"] as? String == "paused" }
            let marker = first.control("marker", ["sessionID": session.id.uuidString, "label": "好球", "date": Date().timeIntervalSince1970 * 1000])
            try await waitFor("marker reply", timeout: 5) { first.reply(to: marker) != nil }

            // Commands that move files over the native link are refused for browsers.
            let transfer = first.control("transfer", ["sessionID": session.id.uuidString, "label": "x.mov"])
            try await waitFor("transfer refused", timeout: 5) { first.reply(to: transfer) != nil }
            XCTAssertEqual(first.reply(to: transfer)?["ok"] as? Bool, false)

            // A browser that joins later gets the session and the full ledger, only for itself.
            let before = first.count("analysis")
            let late = TestBrowser(port: port)
            _ = try await late.authenticate(mac: credentials)
            late.hello()
            try await waitFor("late catch-up", timeout: 5) { late.shotIDs.contains(shot.id.uuidString) && late.last("session") != nil }
            XCTAssertTrue(late.analysis.contains { $0["resync"] as? Bool == true && ($0["sessionID"] as? String) == session.id.uuidString })
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(first.count("analysis"), before, "Catch-up for one browser is not broadcast")
            late.close()
            try await waitFor("late left", timeout: 5) { rig.camera.webClients == 2 }
        } catch { first.close(); second.close(); await rig.close(); throw error }
        first.close(); second.close()
        await rig.close()
        XCTAssertEqual(rig.camera.webState, .off)
    }

    /// Replies say whether the state was reached, and every page learns the camera's session state
    /// (hello, status) so a page that missed an update, or reconnects to a restarted camera, can
    /// correct itself. The page's own repair logic runs in the browser and is checked by hand.
    @MainActor func testRepliesAndStatusReflectTheCameraSessionState() async throws {
        let rig = CameraRig(root: makeRoot("court-web-state"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let credentials = try XCTUnwrap(rig.camera.webCredentials)
        let page = TestBrowser(port: port)
        do {
            _ = try await page.authenticate(mac: credentials)
            page.hello()
            try await waitFor("hello and status", timeout: 5) { page.count("hello") == 1 && page.count("status") >= 1 }
            XCTAssertNil(page.last("hello")?["session"], "No session on the camera: the hello says so")
            XCTAssertNil(page.last("status")?["sessionState"])
            XCTAssertEqual(page.last("status")?["busy"] as? Bool, false)

            // Without a session nothing is applied, and the replies say so.
            for command in ["marker", "pause", "resume", "finish"] {
                let id = page.control(command, ["label": "x"])
                try await waitFor("\(command) reply", timeout: 5) { page.reply(to: id) != nil }
                XCTAssertEqual(page.reply(to: id)?["ok"] as? Bool, false, "\(command) without a session must not report success")
            }

            let start = page.control("start", ["label": "状态同步"])
            try await waitFor("started", timeout: 5) { page.reply(to: start) != nil }
            XCTAssertEqual(page.reply(to: start)?["ok"] as? Bool, true)
            let session = try XCTUnwrap(rig.camera.session)
            try await waitFor("status reports active", timeout: 3) { page.last("status")?["sessionState"] as? String == "active" }
            XCTAssertEqual(page.last("status")?["sessionID"] as? String, session.id.uuidString)

            // Busy reaches the page at once (not on the next 1 s tick) and commands wait.
            let before = page.count("status")
            rig.camera.testingSetBusy(true)
            try await waitFor("busy pushed", timeout: 0.8) { page.count("status") > before && page.last("status")?["busy"] as? Bool == true }
            let refusedStart = page.control("start", ["label": "忙时开始"])
            let refusedPause = page.control("pause", ["sessionID": session.id.uuidString])
            try await waitFor("refusals", timeout: 5) { page.reply(to: refusedStart) != nil && page.reply(to: refusedPause) != nil }
            XCTAssertEqual(page.reply(to: refusedStart)?["ok"] as? Bool, false)
            XCTAssertEqual(page.reply(to: refusedPause)?["ok"] as? Bool, false)
            XCTAssertEqual(rig.camera.session?.state, .active)
            rig.camera.testingSetBusy(false)

            // Pause is idempotent: a second display pressing it too also sees success.
            let pauses = [page.control("pause", ["sessionID": session.id.uuidString]), page.control("pause", ["sessionID": session.id.uuidString])]
            try await waitFor("both pauses answered", timeout: 20) { pauses.allSatisfy { page.reply(to: $0) != nil } }
            XCTAssertTrue(pauses.allSatisfy { page.reply(to: $0)?["ok"] as? Bool == true })
            XCTAssertEqual(rig.camera.session?.events.filter { $0.kind == .pause }.count, 1)
            let marker = page.control("marker", ["sessionID": session.id.uuidString, "label": "暂停中"])
            try await waitFor("marker refused while paused", timeout: 5) { page.reply(to: marker) != nil }
            XCTAssertEqual(page.reply(to: marker)?["ok"] as? Bool, false)

            // A page that (re)joins learns the open session from the hello itself.
            let late = TestBrowser(port: port)
            _ = try await late.authenticate(mac: credentials)
            late.hello()
            try await waitFor("late hello", timeout: 5) { late.count("hello") == 1 }
            let hello = try XCTUnwrap(late.last("hello")?["session"] as? [String: Any])
            XCTAssertEqual(hello["id"] as? String, session.id.uuidString)
            XCTAssertEqual(hello["state"] as? String, "paused")
            late.close()

            let finish = page.control("finish", ["sessionID": session.id.uuidString])
            try await waitFor("finished", timeout: 20) { page.reply(to: finish) != nil }
            XCTAssertEqual(page.reply(to: finish)?["ok"] as? Bool, true)
            try await waitFor("status reports completed", timeout: 3) { page.last("status")?["sessionState"] as? String == "completed" }
            let again = page.control("finish", ["sessionID": session.id.uuidString])
            try await waitFor("second finish", timeout: 5) { page.reply(to: again) != nil }
            XCTAssertEqual(page.reply(to: again)?["ok"] as? Bool, true, "Finishing a finished session is success, not an error")
        } catch { page.close(); await rig.close(); throw error }
        page.close()
        await rig.close()
    }

    // MARK: Preview and still

    @MainActor func testPreviewOnlyWhenAskedAndStillOnlyToTheAsker() async throws {
        let rig = CameraRig(root: makeRoot("court-web-preview"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let credentials = try XCTUnwrap(rig.camera.webCredentials)
        let watcher = TestBrowser(port: port), other = TestBrowser(port: port)
        do {
            for browser in [watcher, other] { _ = try await browser.authenticate(mac: credentials); browser.hello() }
            rig.source.start()
            try await waitFor("capturing", timeout: 10) { rig.camera.capturing }
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(watcher.binaries.isEmpty, "No preview until a browser asks")

            watcher.preview(true)
            try await waitFor("preview frames", timeout: 10) { watcher.binaries.filter { $0.type == 1 }.count >= 3 }
            let frame = try XCTUnwrap(watcher.binaries.first { $0.type == 1 })
            XCTAssertEqual(frame.info["width"] as? Int, 640)
            XCTAssertEqual(frame.info["height"] as? Int, 360)
            XCTAssertEqual(Array(frame.jpeg.prefix(2)), [0xFF, 0xD8], "JPEG")
            XCTAssertTrue(other.binaries.isEmpty, "Only browsers that opened the preview get frames")

            // L1 slows the preview to about one frame a second; L2 stops it.
            rig.camera.appliesLoadPolicy = false
            rig.camera.shed = (2, "测试降载")
            try await Task.sleep(for: .milliseconds(400))
            let stopped = watcher.binaries.count
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(watcher.binaries.count, stopped, "No preview at L2")
            rig.camera.shed = (0, nil)

            let still = other.control("still", [:])
            try await waitFor("still", timeout: 10) { other.binaries.contains { $0.type == 2 } }
            let image = try XCTUnwrap(other.binaries.first { $0.type == 2 })
            XCTAssertEqual(image.info["request"] as? String, still)
            XCTAssertFalse(watcher.binaries.contains { $0.type == 2 }, "The still goes only to the browser that asked")
            watcher.preview(false)
        } catch { watcher.close(); other.close(); await rig.close(); throw error }
        watcher.close(); other.close()
        await rig.close()
    }

    // MARK: HTTP API

    @MainActor func testHistoryClipAndRecordingDownload() async throws {
        let rig = CameraRig(root: makeRoot("court-web-http"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let credentials = try XCTUnwrap(rig.camera.webCredentials)
        let browser = TestBrowser(port: port)
        do {
            let auth = try await browser.authenticate(mac: credentials)
            let access = try XCTUnwrap(auth.access)
            browser.hello()
            let base = "http://127.0.0.1:\(port)"

            // The page itself needs no key; the API does.
            let page = try await get("\(base)/")
            XCTAssertEqual(page.status, 200); XCTAssertTrue(page.type.hasPrefix("text/html"))
            let status1 = try await get("\(base)/../Package.swift").status; XCTAssertEqual(status1, 404)
            let status2 = try await get("\(base)/api/sessions").status; XCTAssertEqual(status2, 401)
            let status3 = try await get("\(base)/api/sessions?k=wrong").status; XCTAssertEqual(status3, 401)

            rig.source.start()
            rig.camera.startSession(title: "接口测试")
            try await waitFor("records", timeout: 30) { (rig.camera.counters.recordingSeconds ?? 0) > 6 }
            let session = try XCTUnwrap(rig.camera.session)
            let stream = try XCTUnwrap(rig.camera.streamID)
            let pts = try XCTUnwrap(rig.camera.counters.latestPTS)
            let shot = TennisShotEvent(streamID: stream, sourcePTS: pts - 2.5, stroke: .volley, confidence: 0.6)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [shot]))

            let list = try await get("\(base)/api/sessions?k=\(access)")
            XCTAssertEqual(list.status, 200)
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
            XCTAssertEqual(rows.first?["id"] as? String, session.id.uuidString)
            XCTAssertEqual(rows.first?["shots"] as? Int, 1)
            let detail = try await get("\(base)/api/session?k=\(access)&id=\(session.id.uuidString)")
            let detailBody = try XCTUnwrap(JSONSerialization.jsonObject(with: detail.body) as? [String: Any])
            XCTAssertEqual(((detailBody["session"] as? [String: Any])?["tennisEvents"] as? [Any])?.count, 1)

            // A clip while recording is cut from memory as MP4 and served with ranges.
            let clipURL = "\(base)/api/clip?k=\(access)&session=\(session.id.uuidString)&shot=\(shot.id.uuidString)"
            let clip = try await get(clipURL)
            XCTAssertEqual(clip.status, 200, String(decoding: clip.body.prefix(200), as: UTF8.self))
            XCTAssertEqual(clip.type, "video/mp4")
            let saved = makeRoot("court-web-clip").appendingPathExtension("mp4")
            try clip.body.write(to: saved)
            let frames = try await decodeMovie(saved)
            XCTAssertGreaterThanOrEqual(frames, 5 * 60 - 2)
            let partial = try await get(clipURL, range: "bytes=0-99")
            XCTAssertEqual(partial.status, 206); XCTAssertEqual(partial.body.count, 100)
            XCTAssertEqual(partial.body, clip.body.prefix(100), "Same cut is reused")

            // Recordings download only while not recording.
            await rig.camera.pause()
            try await waitFor("recording saved", timeout: 20) { rig.camera.session?.recordings.count == 1 }
            let name = try XCTUnwrap(rig.camera.session?.recordings.first?.filename)
            rig.camera.resume()
            try await waitFor("recording again", timeout: 10) { rig.camera.counters.recording }
            let refused = try await get("\(base)/api/recording?k=\(access)&session=\(session.id.uuidString)&file=\(name)")
            XCTAssertEqual(refused.status, 409)
            await rig.camera.finish()
            let recording = try await get("\(base)/api/recording?k=\(access)&session=\(session.id.uuidString)&file=\(name)")
            XCTAssertEqual(recording.status, 200)
            XCTAssertTrue(recording.disposition?.contains(name) == true)
            let onDisk = try Data(contentsOf: rig.root.appendingPathComponent(name))
            XCTAssertEqual(recording.body, onDisk)
            let tail = try await get("\(base)/api/recording?k=\(access)&session=\(session.id.uuidString)&file=\(name)", range: "bytes=-1000")
            XCTAssertEqual(tail.status, 206); XCTAssertEqual(tail.body, onDisk.suffix(1000))
            let status4 = try await get("\(base)/api/recording?k=\(access)&session=\(session.id.uuidString)&file=../x.mov").status; XCTAssertEqual(status4, 404)

            // The record's detail says which recordings are still on the camera; after the camera
            // clears them (keeping the record) the page gets an empty list and offers no download.
            func available() async throws -> [String]? {
                let detail = try await get("\(base)/api/session?k=\(access)&id=\(session.id.uuidString)")
                return (try JSONSerialization.jsonObject(with: detail.body) as? [String: Any])?["available"] as? [String]
            }
            let listed = try await available()
            XCTAssertEqual(listed, rig.camera.session?.recordingFilenames)
            let store = try SessionStore(directory: rig.root)
            let cleanup = StorageCleanup(store: store)
            let stored = try store.loadAll(recoverUnfinished: false)
            try cleanup.clearRecordings(cleanup.planRecordings(of: stored, all: stored, inUse: []))
            let cleared = try await available()
            XCTAssertEqual(cleared, [])

            // The access key stops working a while after its WebSocket closes; not at once.
            browser.close()
            try await waitFor("left", timeout: 5) { rig.camera.webClients == 0 }
            let status5 = try await get("\(base)/api/sessions?k=\(access)").status; XCTAssertEqual(status5, 200, "Grace period for a loading video")
        } catch { browser.close(); await rig.close(); throw error }
        await rig.close()
    }

    // MARK: Hawk-Eye

    /// A browser turns Hawk-Eye on; the camera echoes the settings in its status and judges the next
    /// shot's bounce, so the browser row carries the call. Injected rows: the rules only, not accuracy.
    @MainActor func testBrowserTurnsOnHawkEyeAndGetsCalls() async throws {
        let rig = CameraRig(root: makeRoot("court-web-hawkeye"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        let page = TestBrowser(port: port)
        do {
            _ = try await page.authenticate(mac: try XCTUnwrap(rig.camera.webCredentials))
            page.hello()
            try await waitFor("hello", timeout: 5) { page.count("hello") == 1 }
            XCTAssertTrue((page.last("hello")?["capabilities"] as? [String])?.contains(WireHello.hawkEye) == true)
            let on = page.control("hawkEye", ["hawkEye": ["enabled": true, "format": "doubles", "farHalf": false]])
            try await waitFor("reply", timeout: 5) { page.reply(to: on) != nil }
            XCTAssertEqual(page.reply(to: on)?["ok"] as? Bool, true)
            XCTAssertEqual(rig.camera.hawkEye, HawkEyeSettings(enabled: true, format: .doubles, farHalf: false))
            try await waitFor("status echo", timeout: 5) { (page.last("status")?["hawkEye"] as? [String: Any])?["format"] as? String == "doubles" }

            rig.source.start()
            try await waitFor("capturing", timeout: 10) { rig.camera.capturing && rig.camera.streamID != nil }
            let stream = try XCTUnwrap(rig.camera.streamID)
            var shot = TennisShotEvent(streamID: stream, sourcePTS: 1, stroke: .forehand, confidence: 0)
            shot.bounce = TennisBounceEstimate(sourcePTS: 1.6, xMeters: 5.485, yMeters: -0.4, confidence: 0)
            shot.bounce?.sigmaXMeters = 0.02; shot.bounce?.sigmaYMeters = 0.05
            shot.hit = TennisCourtPoint(x: 5, y: 22, z: 1)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [shot]))
            try await waitFor("judged row", timeout: 5) { page.shotIDs.contains(shot.id.uuidString) }
            let row = try XCTUnwrap(page.analysis.flatMap { $0["events"] as? [[String: Any]] ?? [] }.last { $0["id"] as? String == shot.id.uuidString })
            let call = try XCTUnwrap((row["bounce"] as? [String: Any])?["hawkEye"] as? [String: Any])
            XCTAssertEqual(call["call"] as? String, "out")
            XCTAssertEqual(call["line"] as? String, "baseline")
        } catch { page.close(); await rig.close(); throw error }
        page.close()
        await rig.close()
    }

    /// Opt-in demo for checking the page by hand: the camera's browser server on localhost with made-up
    /// judged shots every few seconds (synthetic, labelled as such). COURT_WEB_HAWKEYE_DEMO=/path/url.txt
    /// writes the page URL (with its one-off token) there; runs COURT_WEB_HAWKEYE_DEMO_SECONDS (default 300).
    @MainActor func testHawkEyeDemoForManualCheck() async throws {
        guard let out = ProcessInfo.processInfo.environment["COURT_WEB_HAWKEYE_DEMO"] else { throw XCTSkip("Set COURT_WEB_HAWKEYE_DEMO=/path/url.txt to run the demo") }
        let seconds = Double(ProcessInfo.processInfo.environment["COURT_WEB_HAWKEYE_DEMO_SECONDS"] ?? "") ?? 300
        let rig = CameraRig(root: makeRoot("court-web-hawkeye-demo"))
        rig.camera.startWebDisplay(webRoot: try webRoot(), port: nil)
        let port = try await listening(rig.camera)
        rig.source.start()
        try await waitFor("capturing", timeout: 10) { rig.camera.capturing && rig.camera.streamID != nil }
        rig.camera.startSession(title: "界内外演示（合成数据）")
        rig.camera.setHawkEye(HawkEyeSettings(enabled: true, format: .singles, farHalf: true))
        let url = try XCTUnwrap(rig.camera.webURL(address: "127.0.0.1"))
        try Data(url.utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
        let c = HawkEye.centreX
        let demo: [(TennisStrokeKind, TennisCourtPoint, Double, Double)] = [
            (.forehand, TennisCourtPoint(x: c + 1, y: 22.5, z: 1.0), c - 1.2, -0.16),
            (.serve, TennisCourtPoint(x: c + 2, y: 24.2, z: 2.7), c - 2, HawkEye.netY - HawkEye.serviceFromNet + 0.02),
            (.backhand, TennisCourtPoint(x: c - 1, y: 21.5, z: 0.9), c + HawkEye.singlesHalfWidth - 0.35, 4.0),
            (.forehand, TennisCourtPoint(x: c, y: 1.0, z: 1.0), c + 2.4, 23.95),
        ]
        let end = ProcessInfo.processInfo.systemUptime + seconds
        var k = 0
        while ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .seconds(6))
            guard let stream = rig.camera.streamID, let pts = rig.pipeline.currentCounters.latestPTS else { continue }
            let (stroke, hit, x, y) = demo[k % demo.count]; k += 1
            var shot = TennisShotEvent(streamID: stream, sourcePTS: pts - 1, stroke: stroke, confidence: 0.8, speedKPH: 120)
            shot.hit = hit
            shot.bounce = TennisBounceEstimate(sourcePTS: pts - 0.1, xMeters: x, yMeters: y, confidence: 0.5)
            shot.bounce?.sigmaXMeters = 0.04; shot.bounce?.sigmaYMeters = y > HawkEye.netY ? 0.5 : 0.08
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [shot]))
        }
        await rig.close()
        _ = port
    }

    // MARK: Helpers

    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }
    private func webRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CourtCore/Web", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path))
        return url
    }
    @MainActor private func listening(_ camera: CameraSessionController) async throws -> UInt16 {
        try await waitFor("listening", timeout: 5) { if case .listening = camera.webState { return true }; return false }
        guard case .listening(let port) = camera.webState else { throw WebTestFailure.timeout("port") }
        return port
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WebTestFailure.timeout(condition) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private struct Response { let status: Int; let type: String; let disposition: String?; let body: Data }
    private func get(_ url: String, range: String? = nil) async throws -> Response {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.timeoutInterval = 30
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return Response(status: http.statusCode, type: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                        disposition: http.value(forHTTPHeaderField: "Content-Disposition"), body: data)
    }
    private func decodeMovie(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? WebTestFailure.timeout("decode") }
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        return count
    }
}

private final class SavedCredentials: @unchecked Sendable { var value: WebDisplayCredentials? }

private enum WebTestFailure: LocalizedError {
    case timeout(String)
    var errorDescription: String? { if case .timeout(let what) = self { return "Timed out waiting for \(what)." }; return nil }
}

/// Plays a browser page: auth, hello, controls, and collects every message it receives.
private final class TestBrowser: @unchecked Sendable {
    struct Binary { let type: UInt8; let info: [String: Any]; let jpeg: Data }
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var messages: [(kind: String, body: Any)] = []
    private var _binaries: [Binary] = []
    private var closed = false

    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.resume(); receive()
    }
    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure: self.lock.lock(); self.closed = true; self.lock.unlock()
            case .success(.string(let text)):
                if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let kind = object["kind"] as? String {
                    self.lock.lock(); self.messages.append((kind, object["body"] ?? NSNull())); self.lock.unlock()
                }
                self.receive()
            case .success(.data(let data)):
                if data.count > 5 {
                    let length = Int(data[1]) << 24 | Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
                    let info = (try? JSONSerialization.jsonObject(with: data.subdata(in: 5..<(5 + length)))) as? [String: Any] ?? [:]
                    self.lock.lock(); self._binaries.append(Binary(type: data[0], info: info, jpeg: data.subdata(in: (5 + length)..<data.count))); self.lock.unlock()
                }
                self.receive()
            case .success: self.receive()
            }
        }
    }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var binaries: [Binary] { lock.lock(); defer { lock.unlock() }; return _binaries }
    func all(_ kind: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return messages.filter { $0.kind == kind }.compactMap { $0.body as? [String: Any] }
    }
    func count(_ kind: String) -> Int { all(kind).count }
    func last(_ kind: String) -> [String: Any]? { all(kind).last }
    var analysis: [[String: Any]] { all("analysis") }
    var shotIDs: Set<String> { Set(analysis.flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }) }
    func reply(to id: String) -> [String: Any]? { all("control").last { $0["command"] as? String == "reply" && $0["replyTo"] as? String == id } }

    func challenge() async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let nonce = all("auth").first?["nonce"] as? String { return nonce }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebTestFailure.timeout("challenge")
    }
    func authenticate(mac credentials: WebDisplayCredentials) async throws -> WebAuthResult {
        let nonce = try await challenge()
        return try await sendAuth(["mac": credentials.mac(nonce: nonce)])
    }
    func send(pin: String) async throws -> WebAuthResult { try await sendAuth(["pin": pin]) }
    private func sendAuth(_ body: [String: String]) async throws -> WebAuthResult {
        let before = count("auth")
        send(["kind": "auth", "body": body])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let replies = all("auth")
            if replies.count > before, let reply = replies.last {
                return WebAuthResult(ok: reply["ok"] as? Bool ?? false, message: reply["message"] as? String,
                                     token: reply["token"] as? String, access: reply["access"] as? String)
            }
            if isClosed { return WebAuthResult(ok: false, message: "closed") }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebTestFailure.timeout("auth reply")
    }
    func hello() { send(["kind": "hello", "body": ["role": "display", "device": "测试浏览器", "hardware": "browser", "app": "web", "capabilities": ["web"]]]) }
    func preview(_ enabled: Bool) { send(["kind": "preview", "body": ["enabled": enabled]]) }
    @discardableResult func control(_ command: String, _ fields: [String: Any]) -> String {
        let id = UUID().uuidString
        var body = fields; body["id"] = id; body["command"] = command
        send(["kind": "control", "body": body])
        return id
    }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}
#endif
