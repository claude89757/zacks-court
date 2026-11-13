import XCTest
import UIKit

/// Exercises the shipped app through real device orientation and lifecycle events.
/// These sessions have no camera input and must never be treated as field measurements.
@MainActor
final class WorkspaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.claude89757.zackscourt")
        if name.contains("testAutomaticCourtOnLiveVideo") || name.contains("testScreenTourForReview"), liveVideoOptIn { app.launchArguments = ["--pairing-file", "@documents"] }
        // Simulators have no camera: the demo shows a triple camera's zoom presets so their layout
        // and gestures can be checked. Nothing is captured.
        if name.contains("testCameraZoomPresets") || name.contains("testScreenTourForReview") { app.launchEnvironment["COURT_UI_ZOOM_DEMO"] = "1" }
        // The display shows the seeded demo record (titled 演示数据) as just finished.
        if name.contains("testChallengeReplayDemo") || name.contains("testStorePreviewFlow") { app.launchEnvironment["COURT_UI_REPLAY_DEMO"] = "1" }
        // Existing tests look up Simplified Chinese labels. A capture run sets COURT_LANGUAGE.
        let language = ProcessInfo.processInfo.environment["COURT_LANGUAGE"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_COURT_LANGUAGE"] ?? "zh-Hans"
        app.launchEnvironment["COURT_LANGUAGE"] = language
        app.launch()
        let history = language == "zh-Hans" ? app.buttons["历史记录"].firstMatch : app.buttons["court.history.open"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        if app.state != .runningForeground { app.activate() }
        // Also runs after assertion failures, so development sessions are finalized.
        if app.buttons["结束"].firstMatch.exists {
            if makeReachable(app.buttons["结束"].firstMatch) {
                app.buttons["结束"].firstMatch.tap()
                let confirm = app.buttons["结束并保存"].firstMatch
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            }
        }
        // Sheets opened over the camera (history) close before leaving the mode.
        if app.navigationBars["历史记录"].exists { app.navigationBars["历史记录"].buttons["完成"].firstMatch.tap() }
        let back = app.buttons["切换模式"].firstMatch
        if back.exists, makeReachable(back) { back.tap() }
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testOrientationTrainingAndBackgroundRecovery() throws {
        attach("01-home-portrait")
        enterServer()
        assertPortrait()
        attach("02-server-portrait")
        assertNoScoringControls()

        for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "03-server-landscape-left"),
                                    (.landscapeRight, "04-server-landscape-right")] {
            XCUIDevice.shared.orientation = orientation
            assertLandscape()
            assertServerColumns()
            attach(name)
        }

        XCUIDevice.shared.orientation = .portrait
        assertPortrait()
        startTraining(title: "UI-QA")
        // In portrait the running record's controls sit in a bar above the home indicator,
        // on screen without scrolling.
        let bar = app.descendants(matching: .any)["court.session.bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        for label in ["暂停", "精彩", "待复核", "结束"] {
            let control = bar.buttons[label].firstMatch
            XCTAssertTrue(control.exists && control.isHittable, "\(label) is in the bottom bar")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(bar.frame))
        tapReachable(app.buttons["精彩"].firstMatch)
        XCTAssertTrue(app.staticTexts["已标记 1 个时刻"].waitForExistence(timeout: 3))

        tapReachable(app.buttons["暂停"].firstMatch)
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["精彩"].firstMatch.isEnabled)
        attach("05-training-paused-portrait")
        tapReachable(app.buttons["继续"].firstMatch)
        XCTAssertTrue(app.staticTexts["进行中"].waitForExistence(timeout: 3))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5), "Backgrounding must pause the session")
        tapReachable(app.buttons["继续"].firstMatch)
        XCTAssertTrue(app.staticTexts["进行中"].waitForExistence(timeout: 3))
        attach("06-training-resumed-after-background")

        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        assertServerColumns()
        let previewBeforeScrolling = app.otherElements["court.server.preview"].firstMatch.frame
        tapReachable(app.buttons["暂停"].firstMatch)
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 3))
        assertPreviewRemainsVisible(frameBeforeScrolling: previewBeforeScrolling)
        attach("07-training-controls-landscape")
        finishTraining()
        XCTAssertTrue(app.buttons["开始记录"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        assertPortrait()
        tapReachable(app.buttons["切换模式"].firstMatch)
        XCTAssertTrue(app.buttons["历史记录"].firstMatch.waitForExistence(timeout: 5))
        attach("08-home-after-cleanup")
    }

    func testCameraAutoLandscapePinsPreviewAndRestoresPortrait() throws {
        assertPortrait()
        tapReachable(app.buttons["court.role.camera"].firstMatch)
        assertLandscape()
        let preview = app.otherElements["court.camera.preview"].firstMatch
        let sidebar = app.scrollViews["court.camera.sidebar"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.exists)
        XCTAssertLessThanOrEqual(preview.frame.maxX, sidebar.frame.minX + 1)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(preview.frame))
        let before = preview.frame
        let captureButton = app.buttons["开始采集"].firstMatch.frame
        sidebar.swipeUp()
        XCTAssertEqual(preview.frame.minX, before.minX, accuracy: 1)
        XCTAssertEqual(preview.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(preview.frame.width, before.width, accuracy: 1)
        XCTAssertEqual(preview.frame.height, before.height, accuracy: 1)
        // Normal text: capture sits on the picture and stays put. Accessibility sizes move it into the
        // sidebar, which then scrolls as a whole (reached by scrolling, see the sidebar test).
        if preview.frame.contains(CGPoint(x: captureButton.midX, y: captureButton.midY)) {
            XCTAssertEqual(app.buttons["开始采集"].firstMatch.frame.minY, captureButton.minY, accuracy: 1, "Capture controls must remain reachable while statistics scroll")
        }
        attach("camera-fixed-preview-and-sidebar")
        XCUIDevice.shared.orientation = .portrait
        assertLandscape()
        app.buttons["切换模式"].firstMatch.tap()
        assertPortrait()
        XCTAssertTrue(app.buttons["court.role.camera"].firstMatch.waitForExistence(timeout: 5))
    }

    /// The landscape camera keeps leaving and capture on the picture, the page tabs and the connect
    /// button in one fixed row, and splits the rest into three pages; each page's main control is
    /// reachable on a phone, also at the largest text size (where everything moves into the sidebar).
    func testCameraSidebarPagesKeepControlsReachable() throws {
        tapReachable(app.buttons["court.role.camera"].firstMatch)
        assertLandscape()
        XCTAssertTrue(app.buttons["开始采集"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["切换模式"].firstMatch.isHittable, "Leaving camera mode stays reachable without scrolling")
        XCTAssertTrue(makeReachable(app.buttons["court.camera.connect"].firstMatch), "Connecting is reachable from the fixed controls")
        let sidebar = app.scrollViews["court.camera.sidebar"].firstMatch
        let tabs = app.buttons["court.camera.section.session"].firstMatch
        if tabs.isHittable, tabs.frame.maxY < sidebar.frame.minY {
            // Normal text: one fixed row above the page, so the page keeps most of the height.
            XCTAssertGreaterThanOrEqual(sidebar.frame.height, app.windows.firstMatch.frame.height * 0.6, "The page keeps most of the sidebar")
        }
        XCTAssertFalse(app.buttons["court.camera.section.connection"].exists, "Connecting is a button, not a page")
        let pages: [(key: String, control: XCUIElement)] = [
            ("session", app.buttons["court.camera.session.start"].firstMatch),
            ("analysis", app.buttons["court.handedness.open"].firstMatch),
            ("settings", app.descendants(matching: .any)["court.camera.standby-delay"].firstMatch),
        ]
        // At the largest text sizes the fixed controls scroll with the page, so tabs are reached by scrolling.
        for page in pages {
            let tab = app.buttons["court.camera.section.\(page.key)"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tapReachable(tab)
            // A tap while the scroll view is still decelerating only stops the scroll; tap once more.
            if !tab.isSelected { tab.tap() }
            XCTAssertTrue(tab.isSelected)
            XCTAssertTrue(page.control.waitForExistence(timeout: 5), "The \(page.key) page shows its main control")
            XCTAssertTrue(makeReachable(page.control), "The \(page.key) page control is reachable")
            if page.key == "settings" {
                // The simulator has no camera: the saved factor shows, the presets wait for capture.
                let zoom = app.staticTexts["court.camera.zoom.value"].firstMatch
                XCTAssertTrue(makeReachable(zoom), "The zoom factor is on the settings page")
                XCTAssertTrue(zoom.label.hasSuffix("×"))
                XCTAssertFalse(app.descendants(matching: .any)["court.camera.zoom"].exists, "No zoom presets before capture starts")
            }
            attach("camera-page-\(page.key)")
        }
        // The settings page is the longest (thousands of points at the largest text size); the way
        // out is pinned on the picture, so it never scrolls away with the page.
        XCTAssertTrue(app.buttons["切换模式"].firstMatch.isHittable, "Leaving camera mode stays on screen after scrolling a page")
        tapReachable(app.buttons["court.camera.section.session"].firstMatch)
        if !app.buttons["court.camera.section.session"].firstMatch.isSelected { app.buttons["court.camera.section.session"].firstMatch.tap() }

        // Setup tips: shown until dismissed on this device (nothing is recorded or calibrated here).
        let dismissTips = app.buttons["court.camera.tips.dismiss"].firstMatch
        if dismissTips.exists {
            tapReachable(dismissTips)
            XCTAssertTrue(dismissTips.waitForNonExistence(timeout: 3), "The tip card closes")
        }

        // History opens over the camera from the 记录 page and comes back without leaving the mode.
        let history = app.buttons["court.camera.history"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        tapReachable(history)
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5), "History opens inside camera mode")
        attach("camera-history-sheet")
        app.navigationBars["历史记录"].buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["开始采集"].firstMatch.exists, "Still in camera mode after history")
        XCTAssertTrue(app.descendants(matching: .any)["court.camera.preview"].firstMatch.exists)
    }

    /// Zoom presets on the camera picture, on every screen size: the five triple-camera presets fit
    /// inside the preview at 44 pt, a tap sets the factor, and dragging left on them zooms in steplessly.
    /// Runs the UI-test demo (no camera); the real camera's lenses and frames are not exercised.
    func testCameraZoomPresetsFitAndRespond() throws {
        tapReachable(app.buttons["court.role.camera"].firstMatch)
        assertLandscape()
        let bar = app.descendants(matching: .any)["court.camera.zoom"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The zoom presets show on the camera picture")
        let preview = app.descendants(matching: .any)["court.camera.preview"].firstMatch
        let window = app.windows.firstMatch.frame
        for preset in ["0.5", "1", "2", "4", "8"] {
            let chip = app.buttons["court.camera.zoom.\(preset)"].firstMatch
            XCTAssertTrue(chip.exists, "Preset \(preset)")
            XCTAssertTrue(chip.isHittable, "Preset \(preset) can be tapped")
            // Frames come back as 43.99999…: allow rounding, not a smaller target.
            XCTAssertGreaterThanOrEqual(chip.frame.width, 43.99, "Preset \(preset) width"); XCTAssertGreaterThanOrEqual(chip.frame.height, 43.99, "Preset \(preset) height")
            XCTAssertTrue(preview.frame.insetBy(dx: -1, dy: -1).contains(chip.frame), "Preset \(preset) stays inside the picture")
            XCTAssertTrue(window.contains(chip.frame))
        }
        let status = app.descendants(matching: .any)["court.camera.status"].firstMatch
        if status.exists { XCTAssertFalse(status.frame.intersects(bar.frame), "The presets never cover the connection status") }
        attach("camera-zoom-presets")

        app.buttons["court.camera.zoom.1"].firstMatch.tap()
        XCTAssertEqual(zoomSetting(), "1×")
        app.buttons["court.camera.zoom.2"].firstMatch.tap()
        XCTAssertEqual(zoomSetting(), "2×")
        // Drag left on the presets: one doubling per 90 pt, like the system camera's dial. Half of
        // that from 2× lands between presets (about 2.8×), so the zoom is stepless, not snapped.
        let chip = app.buttons["court.camera.zoom.1"].firstMatch
        let start = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -45, dy: 0)))
        let dragged = Double(zoomSetting().dropLast()) ?? 0
        XCTAssertGreaterThan(dragged, 2.1, "Dragging left zooms in")
        XCTAssertLessThan(dragged, 3.9, "Half a doubling stays between the 2× and 4× presets")
        app.buttons["court.camera.zoom.1"].firstMatch.tap()
        XCTAssertEqual(zoomSetting(), "1×")
    }

    /// The factor the settings page shows, read through the settings tab and back.
    private func zoomSetting() -> String {
        let tab = app.buttons["court.camera.section.settings"].firstMatch
        tapReachable(tab)
        let value = app.staticTexts["court.camera.zoom.value"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 3))
        let label = value.label
        app.buttons["court.camera.section.session"].firstMatch.tap()
        return label
    }

    /// 「连接」opens the connect page with its first choice (does the other device have the App?):
    /// for a browser, this camera's code (on by default), large enough to scan, its status and PIN and
    /// the browser switch; for an App display, the scan and the link, with no code on screen.
    /// Checked by frames only: the code carries the browser pairing key, so no screenshot while it is open.
    func testCameraConnectOpensCodeDirectly() throws {
        tapReachable(app.buttons["court.role.camera"].firstMatch)
        assertLandscape()
        let connect = app.buttons["court.camera.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isHittable, "连接 sits in the fixed controls")
        tapReachable(connect)
        let appChoice = app.buttons["court.connect.choice.app"].firstMatch
        let browserChoice = app.buttons["court.connect.choice.browser"].firstMatch
        XCTAssertTrue(app.staticTexts["另一台设备装了 Zacks Court 吗？"].waitForExistence(timeout: 5), "The page asks first")
        // Fixed at the top at normal sizes; at accessibility sizes the choice scrolls with the page.
        XCTAssertTrue(makeReachable(appChoice) && makeReachable(browserChoice), "Both answers are reachable")
        XCTAssertGreaterThanOrEqual(appChoice.frame.height, 44); XCTAssertGreaterThanOrEqual(browserChoice.frame.height, 44)
        browserChoice.tap()
        XCTAssertTrue(browserChoice.isSelected)
        let toggle = app.switches["court.web.enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        func flip() {
            XCTAssertTrue(makeReachable(toggle))
            let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
            control.coordinate(withNormalizedOffset: CGVector(dx: control == toggle ? 0.92 : 0.5, dy: 0.5)).tap()
        }
        // On unless this simulator was switched off earlier; leave it as it was found.
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn { flip() }
        let code = app.descendants(matching: .any)["court.web.qr"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "The browser display listens and shows its code")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(code.frame), "The whole code is on screen")
        XCTAssertGreaterThanOrEqual(min(code.frame.width, code.frame.height), 300, "The code is large enough to scan")
        XCTAssertEqual(code.frame.width, code.frame.height, accuracy: 2)
        XCTAssertTrue(app.descendants(matching: .any)["court.web.status"].firstMatch.exists, "The page shows the connection status")
        // Frames only in messages: the PIN's text is part of the pairing.
        let pin = app.descendants(matching: .any)["court.web.pin.large"].firstMatch
        XCTAssertTrue(makeReachable(pin), "PIN at \(pin.frame), scroll at \(app.scrollViews["court.connect.scroll"].firstMatch.frame)")
        XCTAssertFalse(app.buttons["court.camera.scan"].exists, "The App display's scan is not beside the browser code")
        // Refreshing disconnects every browser: it asks first and names the consequence; confirming
        // (harmless on a simulator) brings a new code.
        let refresh = app.buttons["court.web.refresh"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 3))
        XCTAssertTrue(makeReachable(refresh))
        refresh.tap()
        XCTAssertTrue(app.staticTexts["刷新浏览器配对？"].waitForExistence(timeout: 3), "Refreshing asks for confirmation")
        let confirmRefresh = app.buttons["刷新并断开所有浏览器"].firstMatch
        XCTAssertTrue(confirmRefresh.waitForExistence(timeout: 3))
        confirmRefresh.tap()
        XCTAssertTrue(app.staticTexts["刷新浏览器配对？"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(code.waitForExistence(timeout: 10), "A new code shows after refreshing")
        if !wasOn {
            flip()
            XCTAssertTrue(code.waitForNonExistence(timeout: 5), "The browser display is off again")
        }
        // At accessibility sizes the choice scrolled far up with the long page: fling back to the top.
        let connectScroll = app.scrollViews["court.connect.scroll"].firstMatch
        for _ in 0..<12 where !appChoice.isHittable && connectScroll.exists { connectScroll.swipeDown(velocity: .fast) }
        tapReachable(appChoice)
        XCTAssertTrue(appChoice.isSelected)
        XCTAssertTrue(code.waitForNonExistence(timeout: 3), "The App way shows no code to scan")
        // Safe to capture: the App way shows no code and the link field is empty.
        attach("camera-connect-app-way")
        XCTAssertTrue(makeReachable(app.buttons["court.camera.scan"].firstMatch), "The App display's scan is on its page")
        XCTAssertTrue(makeReachable(app.buttons["使用链接连接"].firstMatch))
        tapReachable(browserChoice)
        let close = app.buttons["court.web.code.close"].firstMatch
        XCTAssertTrue(makeReachable(close), "完成 at \(close.frame) exists \(close.exists) hittable \(close.exists && close.isHittable) in \(app.windows.firstMatch.frame)")
        close.tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["court.web.code"].exists)
    }

    func testServerCanOpenLiveVideoView() throws {
        enterServer()
        // Without a camera the portrait page has no picture (only the connect prompt); the
        // landscape header keeps its 实时画面 button.
        XCTAssertFalse(app.buttons["court.live-video.open"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        tapReachable(app.buttons["court.live-video.open"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["court.live-video.window"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["等待机位连接"].exists)
        attach("server-live-video-window")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["court.live-video.open"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
    }

    /// 球速, 落点 and 动作 behave alike: each tile opens its metric full screen, closed with one button.
    func testShortcutTilesOpenFullScreen() throws {
        enterServer()
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        let window = app.windows.firstMatch.frame
        for (key, close) in [("speed", "关闭测速牌"), ("placement", "完成"), ("strokes", "完成")] {
            let tile = app.buttons["court.analysis.\(key).open"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "tile \(key)")
            tapReachable(tile)
            let focus = app.descendants(matching: .any)["court.focus.\(key)"].firstMatch
            XCTAssertTrue(focus.waitForExistence(timeout: 5), "\(key) opens full screen")
            XCTAssertGreaterThan(focus.frame.width, window.width * 0.85, "\(key) covers the screen")
            attach("shortcut-\(key)-full-screen")
            app.buttons[close].firstMatch.tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testSpeedComponentOpensFullScreenCourtsideBoard() throws {
        enterServer()
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        // In the two-column landscape layout the speed shortcut is fully on the first screen, without
        // scrolling (Pro Max too). Accessibility text sizes use one scrolling column instead.
        let shortcut = app.buttons["court.analysis.speed.open"].firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        if app.scrollViews["court.preview.scroll"].exists {
            XCTAssertTrue(shortcut.isHittable)
            XCTAssertLessThanOrEqual(shortcut.frame.maxY, app.windows.firstMatch.frame.maxY)
        }
        attach("server-landscape-shortcuts")
        tapReachable(shortcut)
        let board = app.descendants(matching: .any)["court.focus.speed"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        // The board remembers its mode per device; this test checks the default 「全部球速」 layout.
        app.buttons["court.speedboard.mode.all"].firstMatch.tap()
        let readout = app.descendants(matching: .any)["court.speedboard.readout"].firstMatch
        XCTAssertTrue(readout.exists)
        XCTAssertEqual(readout.value as? String, "等待有效击球")
        XCTAssertGreaterThan(board.frame.width, app.windows.firstMatch.frame.width * 0.85)
        XCTAssertGreaterThan(readout.frame.height, board.frame.height * 0.5)
        XCTAssertFalse(app.switches["显示逐拍明细"].exists)
        attach("speedboard-fullscreen-landscape")
        app.buttons["关闭测速牌"].firstMatch.tap()
        XCTAssertTrue(app.buttons["court.analysis.speed.open"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSpeedBoardServeModeInPortraitAndLandscape() throws {
        enterServer()
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        tapReachable(app.buttons["court.analysis.speed.open"].firstMatch)
        let board = app.descendants(matching: .any)["court.focus.speed"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        let serve = app.buttons["court.speedboard.mode.serve"].firstMatch
        XCTAssertTrue(serve.exists)
        XCTAssertGreaterThanOrEqual(serve.frame.height, 44)
        serve.tap()
        let readout = app.descendants(matching: .any)["court.speedboard.readout"].firstMatch
        let serveValue = NSPredicate(format: "value == %@", "等待有效发球")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: serveValue, object: readout)], timeout: 5), .completed)
        // Unknown statistics stay empty, never 0.
        assertEmptyServeStatistics()
        // The current serve speed takes most of the board; statistics and the trend strip sit under it.
        // Digit sizes with data are checked by SpeedBoardLayoutTests; the empty placeholder is thin.
        let chart = app.descendants(matching: .any)["court.speedboard.serve.chart"].firstMatch
        assertServeSpeedLeads(board: board, readout: readout, chart: chart)
        attach("speedboard-serve-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, Date() < deadline { usleep(100_000) }
        assertServeSpeedLeads(board: board, readout: readout, chart: chart)
        assertEmptyServeStatistics()
        attach("speedboard-serve-portrait")

        // Leave the default mode for the other tests and the next launch.
        app.buttons["court.speedboard.mode.all"].firstMatch.tap()
        XCTAssertEqual(readout.value as? String, "等待有效击球")
        app.buttons["关闭测速牌"].firstMatch.tap()
    }

    private func assertEmptyServeStatistics(file: StaticString = #filePath, line: UInt = #line) {
        let summary = app.descendants(matching: .any)["court.speedboard.serve.stats"].firstMatch
        XCTAssertTrue(summary.exists, "missing serve statistics", file: file, line: line)
        XCTAssertFalse(summary.label.contains("0 千米"), file: file, line: line)
        XCTAssertTrue(summary.label.contains("暂无"), file: file, line: line)
    }

    /// The serve speed region takes most of the board; the trend, when shown, is a thin strip below it.
    private func assertServeSpeedLeads(board: XCUIElement, readout: XCUIElement, chart: XCUIElement,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(readout.frame.height, board.frame.height * 0.5, file: file, line: line)
        // Landscape iPhones keep the side safe areas (about 60 pt each) out of the readout.
        XCTAssertGreaterThan(readout.frame.width, board.frame.width * 0.7, file: file, line: line)
        if chart.exists {
            XCTAssertLessThanOrEqual(readout.frame.maxY, chart.frame.minY + 1, file: file, line: line)
            XCTAssertLessThan(chart.frame.height, board.frame.height * 0.15, file: file, line: line)
        }
    }

    /// Run this test separately after setting the simulator's real system content size.
    func testLargeTextControlsRemainReachable() throws {
        attach("large-01-home-portrait")
        enterServer()
        assertPortrait()
        attach("large-02-server-portrait")
        startTraining(title: "UI-QA-LARGE-TEXT")
        tapReachable(app.buttons["精彩"].firstMatch)
        XCTAssertTrue(app.staticTexts["已标记 1 个时刻"].waitForExistence(timeout: 3))
        tapReachable(app.buttons["暂停"].firstMatch)
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 3))
        tapReachable(app.buttons["继续"].firstMatch)
        XCTAssertTrue(app.staticTexts["进行中"].waitForExistence(timeout: 3))
        attach("large-03-training-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        tapReachable(app.buttons["暂停"].firstMatch)
        attach("large-04-training-landscape")
        finishTraining()
        // The end-of-record summary stays usable at the largest text size.
        let close = app.buttons["court.summary.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The summary shows after finishing")
        XCTAssertTrue(makeReachable(app.buttons["court.summary.details"].firstMatch), "查看详情 is reachable")
        attach("large-05-summary-landscape")
        tapReachable(close)
        // A tap while the scroll view is still decelerating only stops the scroll; tap once more.
        if !close.waitForNonExistence(timeout: 2), close.exists, close.isHittable { close.tap() }
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }

    /// Home at the size it runs at (the UI script runs it at the largest accessibility size): the brand
    /// name stays whole words on at most two lines, never 「ZACK / S / COUR / T」, and the history icon
    /// button keeps at least 44 pt (it grows with the text).
    func testLargeTextHomeBrandTitle() throws {
        let brand = app.staticTexts["court.home.brand"].firstMatch
        XCTAssertTrue(brand.waitForExistence(timeout: 5))
        XCTAssertEqual(brand.label, "ZACKS COURT")
        attach("large-home-brand")
        // Letter-by-letter wrapping made it four lines, taller than wide; one or two lines stay wider.
        XCTAssertGreaterThan(brand.frame.width, brand.frame.height, "ZACKS COURT must not wrap per character: \(brand.frame)")
        // Two lines of the tagline-sized headline at most: the history button beside the logo is about one line.
        let history = app.buttons["历史记录"].firstMatch
        XCTAssertLessThanOrEqual(brand.frame.height, max(history.frame.height, 44) * 2, "At most two lines: \(brand.frame)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(brand.frame), "The brand name is not clipped")
        XCTAssertTrue(history.isHittable)
        XCTAssertGreaterThanOrEqual(history.frame.height, 43.99); XCTAssertGreaterThanOrEqual(history.frame.width, 43.99)
    }

    /// Screen-by-screen capture for design review, at whatever text size the simulator runs: home,
    /// camera (the zoom chips show through `COURT_UI_ZOOM_DEMO`), the display empty, recording and
    /// finished, the full-screen boards, history list, detail, query and the delete confirmation.
    /// With `COURT_UI_LIVE_VIDEO=1` and an external sender (`court-probe file`) it waits for the
    /// sender, records until the sender's video ends, and also captures the live page, the shot list,
    /// and handedness. Keeps going after a failed step so one miss does not lose the
    /// rest of the tour. Never opens pairing or the camera's connect page (their codes carry keys).
    /// UI-QA records only.
    func testScreenTourForReview() throws {
        continueAfterFailure = true
        let run = String(Int(Date().timeIntervalSince1970) % 100_000)
        let title = "UI-QA-TOUR-" + run
        attach("tour-01-home")
        let home = app.scrollViews["court.workspace.scroll"].firstMatch
        for page in 1...4 { home.swipeUp(velocity: .slow); attach("tour-02-home-\(page)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        attach("tour-03-home-landscape")
        XCUIDevice.shared.orientation = .portrait
        assertPortrait()
        for _ in 0..<5 { home.swipeDown(velocity: .fast) }

        if !liveVideoOptIn {
            tapReachable(app.buttons["court.role.camera"].firstMatch)
            if app.buttons["开始采集"].firstMatch.waitForExistence(timeout: 5) {
                attach("tour-04-camera-session")
                let sidebar = app.scrollViews["court.camera.sidebar"].firstMatch
                if sidebar.exists { sidebar.swipeUp(velocity: .slow); attach("tour-04-camera-session-scrolled"); sidebar.swipeDown(velocity: .fast) }
                for key in ["analysis", "settings"] {
                    let tab = app.buttons["court.camera.section.\(key)"].firstMatch
                    if makeReachable(tab) { tab.tap(); if !tab.isSelected { tab.tap() } }
                    attach("tour-05-camera-\(key)")
                    if sidebar.exists { sidebar.swipeUp(velocity: .slow); attach("tour-05-camera-\(key)-scrolled"); sidebar.swipeDown(velocity: .fast) }
                }
                let session = app.buttons["court.camera.section.session"].firstMatch
                if makeReachable(session) { session.tap() }
                let history = app.buttons["court.camera.history"].firstMatch
                if makeReachable(history) {
                    history.tap()
                    if app.navigationBars["历史记录"].waitForExistence(timeout: 5) {
                        attach("tour-06-camera-history")
                        app.navigationBars["历史记录"].buttons["完成"].firstMatch.tap()
                    }
                }
            }
            XCUIDevice.shared.orientation = .portrait
            // Leaving is pinned on the picture at every text size, however far the pages scrolled.
            let back = app.buttons["切换模式"].firstMatch
            XCTAssertTrue(back.isHittable, "Leaving stays on screen after scrolling the camera pages")
            if back.isHittable { back.tap() }
            assertPortrait()
        }

        enterServer()
        assertPortrait()
        attach("tour-10-display-empty")
        app.scrollViews["court.workspace.scroll"].firstMatch.swipeUp(velocity: .slow)
        attach("tour-10-display-empty-scrolled")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        attach("tour-11-display-empty-landscape")
        if !liveVideoOptIn {
            // Landscape shows the key-number tiles even without a camera: the empty boards.
            for (key, close) in [("speed", "关闭测速牌"), ("placement", "完成"), ("strokes", "完成")] {
                let tile = app.buttons["court.analysis.\(key).open"].firstMatch
                guard tile.exists, makeReachable(tile) else { continue }
                tile.tap()
                if app.descendants(matching: .any)["court.focus.\(key)"].firstMatch.waitForExistence(timeout: 5) { attach("tour-12-empty-\(key)") }
                app.buttons[close].firstMatch.tap()
            }
        }
        XCUIDevice.shared.orientation = .portrait
        assertPortrait()

        if liveVideoOptIn {
            let connection = app.buttons["court.server.connection"].firstMatch
            let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "机位实时"), object: connection)
            XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 180), .completed, "Waiting for the external sender")
            attach("tour-13-display-connected")
        }
        startTraining(title: title)
        attach("tour-14-recording")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        attach("tour-15-recording-landscape")
        XCUIDevice.shared.orientation = .portrait
        assertPortrait()

        if liveVideoOptIn {
            let speed = app.buttons["court.analysis.speed.open"].firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: speed)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed, "Waiting for shots from the external sender")
            // More than 8 shots, so the 「全部 N 拍」 list exists.
            let all = app.buttons["court.analysis.all-shots"].firstMatch
            _ = all.waitForExistence(timeout: 100)
            let page = app.scrollViews["court.workspace.scroll"].firstMatch
            attach("tour-20-live")
            for index in 1...6 { page.swipeUp(velocity: .slow); attach("tour-21-live-\(index)") }
            for _ in 0..<8 { page.swipeDown(velocity: .fast) }
            for (key, close) in [("speed", "关闭测速牌"), ("placement", "完成"), ("strokes", "完成")] {
                let tile = app.buttons["court.analysis.\(key).open"].firstMatch
                guard makeReachable(tile) else { continue }
                tile.tap()
                if app.descendants(matching: .any)["court.focus.\(key)"].firstMatch.waitForExistence(timeout: 5) {
                    attach("tour-22-focus-\(key)")
                    if key == "speed" {
                        let serve = app.buttons["court.speedboard.mode.serve"].firstMatch
                        if serve.exists { serve.tap(); attach("tour-22-focus-speed-serve"); app.buttons["court.speedboard.mode.all"].firstMatch.tap() }
                        XCUIDevice.shared.orientation = .landscapeLeft
                        assertLandscape()
                        attach("tour-22-focus-speed-landscape")
                        XCUIDevice.shared.orientation = .portrait
                        assertPortrait()
                    }
                }
                app.buttons[close].firstMatch.tap()
            }
            if all.exists, makeReachable(all) {
                all.tap()
                if app.navigationBars["全部击球"].waitForExistence(timeout: 5) {
                    attach("tour-23-all-shots")
                    app.navigationBars["全部击球"].buttons["完成"].firstMatch.tap()
                }
            }
            let handedness = app.buttons["court.handedness.open"].firstMatch
            if makeReachable(handedness) {
                handedness.tap()
                if app.navigationBars["持拍手"].waitForExistence(timeout: 5) {
                    attach("tour-24-handedness")
                    app.navigationBars["持拍手"].buttons["取消"].firstMatch.tap()
                }
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            assertLandscape()
            attach("tour-26-live-landscape")
            XCUIDevice.shared.orientation = .portrait
            assertPortrait()
            // The sender's video ends: the camera pauses and the record finishes (or this test
            // finishes a record left paused once the sender is gone).
            let card = app.descendants(matching: .any)["court.summary"].firstMatch
            let deadline = Date().addingTimeInterval(300)
            while !card.exists, Date() < deadline {
                if app.buttons["继续"].firstMatch.exists, !app.buttons["court.server.connection"].firstMatch.label.contains("机位实时") { break }
                _ = card.waitForExistence(timeout: 5)
            }
            if !card.exists { attach("tour-27-before-finish") }
        }
        if !app.descendants(matching: .any)["court.summary"].firstMatch.exists, app.buttons["结束"].firstMatch.exists {
            tapReachable(app.buttons["结束"].firstMatch)
            if app.buttons["结束并保存"].firstMatch.waitForExistence(timeout: 5) {
                attach("tour-28-finish-confirmation")
                app.buttons["结束并保存"].firstMatch.tap()
            }
        }
        let card = app.descendants(matching: .any)["court.summary"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "The summary shows after the record finishes")
        attach("tour-30-finished")
        let page = app.scrollViews["court.workspace.scroll"].firstMatch
        for index in 1...4 { page.swipeUp(velocity: .slow); attach("tour-31-finished-\(index)") }
        for _ in 0..<6 { page.swipeDown(velocity: .fast) }
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        attach("tour-32-finished-landscape")
        XCUIDevice.shared.orientation = .portrait
        assertPortrait()

        // History: the record's detail (from the summary), delete confirmation, the list and the query.
        let details = app.buttons["court.summary.details"].firstMatch
        if makeReachable(details) {
            details.tap()
            if app.navigationBars["记录详情"].waitForExistence(timeout: 5) {
                attach("tour-40-detail")
                let scroll = app.scrollViews["court.history.detail.scroll"].firstMatch
                for index in 1...5 { scroll.swipeUp(velocity: .slow); attach("tour-41-detail-\(index)") }
                let delete = app.buttons["court.history.delete"].firstMatch
                if makeSheetReachable(delete) {
                    delete.tap()
                    let confirm = app.buttons["删除记录"].firstMatch
                    if confirm.waitForExistence(timeout: 5) {
                        attach("tour-42-delete-confirmation")
                        // A live record stays for a later look; tour records without data are removed.
                        // iOS 26 shows the dialog as a popover without 「取消」: tapping outside closes it.
                        if !liveVideoOptIn { confirm.tap() }
                        else if app.buttons["取消"].firstMatch.exists { app.buttons["取消"].firstMatch.tap() }
                        else { app.navigationBars["记录详情"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                    }
                }
                if app.navigationBars["记录详情"].exists { app.navigationBars["记录详情"].buttons.firstMatch.tap() }
            }
        }
        if !app.navigationBars["历史记录"].exists, makeReachable(app.buttons["历史记录"].firstMatch) { app.buttons["历史记录"].firstMatch.tap() }
        if app.navigationBars["历史记录"].waitForExistence(timeout: 5) {
            attach("tour-43-history-list")
            XCUIDevice.shared.orientation = .landscapeLeft
            assertLandscape()
            attach("tour-43-history-list-landscape")
            XCUIDevice.shared.orientation = .portrait
            assertPortrait()
            let shots = app.buttons["球速与落点查询"].firstMatch
            if makeSheetReachable(shots, towardTop: true) {
                shots.tap()
                if app.textFields["court.history.search"].firstMatch.waitForExistence(timeout: 5) {
                    attach("tour-44-history-query")
                    let scroll = app.scrollViews["court.history.query.scroll"].firstMatch
                    for index in 1...3 { scroll.swipeUp(velocity: .slow); attach("tour-45-history-query-\(index)") }
                }
            }
            app.navigationBars["历史记录"].buttons["完成"].firstMatch.tap()
        }
    }

    /// A short capture pass for visual review, separate from lifecycle regression checks.
    func testScreenshotEvidence() throws {
        attach("evidence-home-portrait")
        enterServer()
        startTraining(title: "UI-QA-SCREENSHOTS")
        tapReachable(app.buttons["精彩"].firstMatch)
        XCTAssertTrue(app.staticTexts["已标记 1 个时刻"].waitForExistence(timeout: 3))
        attach("evidence-training-marker-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        tapReachable(app.buttons["暂停"].firstMatch)
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 3))
        attach("evidence-training-controls-landscape-left")
        XCUIDevice.shared.orientation = .landscapeRight
        assertLandscape()
        tapReachable(app.buttons["继续"].firstMatch)
        attach("evidence-training-controls-landscape-right")
        finishTraining()
    }

    func testRolePreviewScreenshots() throws {
        tapReachable(app.buttons["court.role.camera"].firstMatch)
        XCTAssertTrue(app.staticTexts["你的场边机位"].waitForExistence(timeout: 5))
        attach("role-camera-overview")
        // 连接 sits in the fixed part of the camera sidebar, above its pages.
        let pairing = app.buttons["court.camera.connect"].firstMatch
        XCTAssertTrue(pairing.waitForExistence(timeout: 5))
        XCTAssertTrue(pairing.isHittable, "Connecting must be reachable without scrolling past statistics")
        let scroll = app.scrollViews["court.camera.sidebar"].firstMatch
        scroll.swipeUp(velocity: .slow)
        attach("role-camera-pairing-status")
        tapReachable(app.buttons["切换模式"].firstMatch)
        XCTAssertTrue(app.buttons["court.role.camera"].waitForExistence(timeout: 5))
        enterServer()
        attach("role-server-overview")
        XCTAssertTrue(makeReachable(app.buttons["开始记录"].firstMatch))
        attach("role-server-session")
    }

    private func enterServer() {
        // The large-text role card is lazily created only after it scrolls into view.
        let button = app.buttons["court.role.server"].firstMatch
        tapReachable(button)
        let ready = app.descendants(matching: .any)["court.server.toolbar"].firstMatch.waitForExistence(timeout: 5)
            || app.descendants(matching: .any)["court.server.header"].firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(ready, "The display opens with its toolbar (portrait) or its landscape header")
        assertNoScoringControls()
    }

    /// Without a camera the display is one connect prompt and the record panel: no analysis panels
    /// full of 「—」, and nothing that reads as a measurement. Connecting and starting a record are
    /// on the first screen.
    func testAnalysisSectionsHaveNoPlaceholderMeasurements() throws {
        enterServer()
        let prompt = app.descendants(matching: .any)["court.server.empty"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let connect = app.buttons["court.server.connect"].firstMatch
        XCTAssertTrue(connect.isHittable, "Connecting is on the first screen")
        XCTAssertGreaterThanOrEqual(connect.frame.height, 44)
        let start = app.buttons["开始记录"].firstMatch
        XCTAssertTrue(start.exists && start.isHittable, "Starting a record is on the first screen")
        XCTAssertLessThanOrEqual(start.frame.maxY, app.windows.firstMatch.frame.maxY)
        for title in ["球场落点", "动作类别", "最近击球", "机位与分析"] {
            XCTAssertFalse(app.staticTexts[title].exists, "No empty \(title) panel before a camera connects")
        }
        XCTAssertFalse(app.buttons["court.analysis.speed.open"].exists, "No empty key-number tiles")
        XCTAssertFalse(app.staticTexts["ANALYSIS SESSION"].exists, "No English eyebrows on the phone display")
        // The connection pill in the toolbar opens pairing as well.
        XCTAssertTrue(app.buttons["court.server.connection"].firstMatch.isHittable)
        assertNoScoringControls()
        attach("analysis-empty-state")
    }

    /// No video is selected: verifies navigation, accessible controls and honest
    /// empty speed state, not model accuracy. Run at normal and maximum text size.
    func testIndependentVideoExperimentOpensWithoutMeasurements() throws {
        tapReachable(app.buttons["court.independent.open"].firstMatch)
        XCTAssertTrue(app.navigationBars["本地视频实验"].waitForExistence(timeout: 5))
        let choose = app.buttons["court.independent.choose"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertTrue(makeSheetReachable(choose))
        // Accessibility geometry can report an exact 44 pt frame as 44 - 6e-14.
        // A micro-point tolerance is far below one physical pixel.
        XCTAssertGreaterThanOrEqual(choose.frame.height + 1e-6, 44)
        let start = app.buttons["court.independent.start"].firstMatch
        XCTAssertTrue(makeSheetReachable(start))
        XCTAssertFalse(start.isEnabled, "No source video must never start inference")
        for identifier in ["court.independent.startSeconds", "court.independent.durationSeconds"] {
            let field = app.textFields[identifier].firstMatch
            XCTAssertTrue(makeSheetReachable(field))
            XCTAssertGreaterThanOrEqual(field.frame.height + 1e-6, 44)
        }
        let speed = app.descendants(matching: .any)["court.independent.speed"].firstMatch
        XCTAssertTrue(makeSheetReachable(speed))
        XCTAssertTrue(app.staticTexts["—"].firstMatch.exists, "Unknown speed stays empty")
        XCTAssertTrue(app.staticTexts["court.independent.speedReason"].firstMatch.exists)
        XCTAssertFalse(app.buttons["court.independent.previous"].exists)
        assertNoScoringControls()
        attach("independent-video-empty")
        app.buttons["court.independent.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["历史记录"].firstMatch.waitForExistence(timeout: 5))
    }

    func testIndependentVideoPickerCancellationKeepsExperimentOpen() throws {
        tapReachable(app.buttons["court.independent.open"].firstMatch)
        XCTAssertTrue(app.navigationBars["本地视频实验"].waitForExistence(timeout: 5))
        let choose = app.buttons["court.independent.choose"].firstMatch
        XCTAssertTrue(makeSheetReachable(choose))
        choose.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Cancel", "取消")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "System file chooser must be dismissible")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["本地视频实验"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["court.independent.choose"].firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["court.independent.start"].firstMatch.isEnabled)
        app.buttons["court.independent.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["历史记录"].firstMatch.waitForExistence(timeout: 5))
    }

    /// 「导入视频分析」 is on the start page of every build (App Review tries it away from a court).
    /// No video is picked: checks the page, its 44 pt controls and that nothing starts without a
    /// video. Builds without the in-house models say so and disable picking.
    func testVideoImportOpensFromStartPage() throws {
        tapReachable(app.buttons["court.import.open"].firstMatch)
        XCTAssertTrue(app.navigationBars["导入视频"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["court.import.notice"].firstMatch.exists)
        let modelsMissing = app.descendants(matching: .any)["court.import.unavailable"].firstMatch.exists
        for identifier in ["court.import.photos", "court.import.files"] {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(makeSheetReachable(button), identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height + 1e-6, 44)
            XCTAssertEqual(button.isEnabled, !modelsMissing, identifier)
        }
        let start = app.buttons["court.import.start"].firstMatch
        XCTAssertTrue(makeSheetReachable(start))
        XCTAssertFalse(start.isEnabled, "Nothing starts without a video")
        assertNoScoringControls()
        attach("video-import-empty")
        app.buttons["court.import.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["历史记录"].firstMatch.waitForExistence(timeout: 5))
    }

    func testIndependentVideoExperimentIsOutsideLiveModes() throws {
        enterServer()
        XCTAssertFalse(app.buttons["court.independent.open"].exists)
        tapReachable(app.buttons["切换模式"].firstMatch)
        XCTAssertTrue(makeReachable(app.buttons["court.independent.open"].firstMatch))
        assertNoScoringControls()
    }

    /// Opt in only with an external real-video sender ready. For xcodebuild:
    /// TEST_RUNNER_COURT_UI_LIVE_VIDEO=1 xcodebuild test ...
    /// -only-testing:ZacksCourtUITests/WorkspaceUITests/testAutomaticCourtOnLiveVideo
    /// Xcode scheme test environment may instead set COURT_UI_LIVE_VIDEO=1.
    func testAutomaticCourtOnLiveVideo() throws {
        guard liveVideoOptIn else { throw XCTSkip("Requires COURT_UI_LIVE_VIDEO=1 and an external real-video sender") }
        enterServer()
        // No manual corners: the camera finds the court in the real public video by itself.
        XCTAssertTrue(app.staticTexts["球场映射可用"].waitForExistence(timeout: 120), "Waiting for the externally sent, real public test video")
        XCTAssertTrue(makeReachable(app.staticTexts["球场映射可用"].firstMatch))
        attach("live-01-court-recognized")
        tapReachable(app.buttons["court.handedness.open"].firstMatch)
        XCTAssertTrue(app.staticTexts["近端持拍手"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["远端持拍手"].firstMatch.exists)
        attach("live-02-handedness-settings")
        tapReachable(app.buttons["保存持拍手"].firstMatch)

        startTraining(title: "UI-QA-LIVE-VIDEO")
        XCTAssertTrue(makeReachable(app.staticTexts["最近击球"].firstMatch))
        XCTAssertTrue(app.staticTexts["court.analysis.shot-count"].waitForExistence(timeout: 45), "A real video shot must be detected after starting the record")
        // Compact shot rows name the landing state in their spoken label.
        let placed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "落点已标在球场图")).firstMatch
        XCTAssertTrue(placed.waitForExistence(timeout: 30), "At least one real-video bounce must have a court position")
        attach("live-03-real-shot-and-bounce")
        finishTraining()
        tapReachable(app.buttons["历史记录"].firstMatch)
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI-QA-LIVE-VIDEO")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        attach("live-04-saved-analysis-history")
        app.navigationBars.buttons["历史记录"].tap()
        app.buttons["完成"].firstMatch.tap()
    }

    /// Replay requires the previously saved real-video UI-QA record, never mock data.
    /// TEST_RUNNER_COURT_UI_SAVED_HISTORY=1 xcodebuild test ... -only-testing:ZacksCourtUITests/WorkspaceUITests/testSavedRealShotPlayback
    func testSavedRealShotPlayback() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COURT_UI_SAVED_HISTORY"] == "1" || environment["TEST_RUNNER_COURT_UI_SAVED_HISTORY"] == "1" else {
            throw XCTSkip("Requires COURT_UI_SAVED_HISTORY=1 and a saved real-video record")
        }
        app.buttons["历史记录"].firstMatch.tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI-QA-LIVE-VIDEO")).firstMatch
        XCTAssertTrue(makeSheetReachable(record)); record.tap()
        let replay = app.buttons["回看这一拍"].firstMatch
        XCTAssertTrue(makeSheetReachable(replay)); XCTAssertTrue(replay.isEnabled); replay.tap()
        XCTAssertTrue(app.navigationBars["录像回放"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Court-20261026-161951-BCB3BF.mov"].waitForExistence(timeout: 8))
        attach("replay-real-shot-player")
        app.navigationBars["录像回放"].buttons["完成"].tap()
        app.navigationBars.buttons["历史记录"].tap()
        app.buttons["完成"].firstMatch.tap()
    }

    /// Share and save-to-Photos from the player. Needs the session written by
    /// `VideoExportTests/testWriteSimulatorFixture` copied into the app's Documents/Zacks Court/Sessions
    /// (a synthetic 8 s recording), and COURT_UI_EXPORT_FIXTURE=1. Answers the Photos prompt with Allow.
    func testShotExportSharesAndSavesToPhotos() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COURT_UI_EXPORT_FIXTURE"] == "1" || environment["TEST_RUNNER_COURT_UI_EXPORT_FIXTURE"] == "1" else {
            throw XCTSkip("Requires COURT_UI_EXPORT_FIXTURE=1 and the export fixture session")
        }
        app.buttons["历史记录"].firstMatch.tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导出测试")).firstMatch
        XCTAssertTrue(makeSheetReachable(record)); record.tap()
        let replay = app.buttons["回看这一拍"].firstMatch
        XCTAssertTrue(makeSheetReachable(replay)); replay.tap()
        XCTAssertTrue(app.navigationBars["录像回放"].waitForExistence(timeout: 8))
        // The shot is cut out of the recording when the player opens, under a readable name.
        let share = app.buttons["court.player.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Share is ready once the shot is cut")
        XCTAssertTrue(share.label.contains("分享这一拍"), share.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ZacksCourt-")).firstMatch.exists)
        attach("export-01-player")

        app.buttons["court.player.save"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 6) {
            attach("export-02-photos-prompt")
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "Allow Access", "允许访问"])).firstMatch
            XCTAssertTrue(allow.exists, alert.buttons.allElementsBoundByIndex.map(\.label).joined(separator: " / "))
            allow.tap()
        }
        XCTAssertTrue(app.staticTexts["已存到相册"].waitForExistence(timeout: 15), "Saved to Photos without a crash")
        attach("export-03-saved")

        share.tap()
        sleep(2)
        attach("export-04-share-sheet")
    }

    /// 「管理存储空间」 from history: sizes by kind, then clearing every finished record's recordings
    /// keeps the record and its shots and marks it 「录像已清理」. Same fixture as the export test.
    func testStoragePageClearsRecordingsAndKeepsRecords() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COURT_UI_EXPORT_FIXTURE"] == "1" || environment["TEST_RUNNER_COURT_UI_EXPORT_FIXTURE"] == "1" else {
            throw XCTSkip("Requires COURT_UI_EXPORT_FIXTURE=1 and the export fixture session")
        }
        app.buttons["历史记录"].firstMatch.tap()
        let open = app.buttons["court.history.storage"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.navigationBars["存储空间"].waitForExistence(timeout: 5))
        attach("storage-01-page")
        let clearAll = app.buttons["court.storage.recordings.all"]
        XCTAssertTrue(makeSheetReachable(clearAll)); XCTAssertTrue(clearAll.isEnabled, clearAll.label)
        clearAll.tap()
        let confirm = app.buttons["court.storage.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attach("storage-02-confirm")
        confirm.tap()
        let emptied = NSPredicate(format: "label CONTAINS %@", "没有")
        let cleared = expectation(for: emptied, evaluatedWith: app.buttons["court.storage.recordings.all"])
        let result = XCTWaiter.wait(for: [cleared], timeout: 6)
        attach("storage-03-cleared")
        XCTAssertEqual(result, .completed, "Nothing left to clear: \(app.buttons["court.storage.recordings.all"].label)")
        app.navigationBars["存储空间"].buttons["完成"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导出测试")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5), "The record stays")
        XCTAssertTrue(record.label.contains("录像已清理"), record.label)
        record.tap()
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "逐拍数据和标记保留")).firstMatch
        XCTAssertTrue(makeSheetReachable(note))
        attach("storage-04-record")
    }

    /// Finishing a record keeps what was just recorded on screen: a summary card with the name,
    /// counts and 「—」 for speeds nobody measured (no camera here), 「查看详情」 opening that record in
    /// history, and a close button. A new record replaces it. UI-QA records only.
    func testFinishedRecordShowsSummary() throws {
        let run = String(Int(Date().timeIntervalSince1970) % 100_000)
        enterServer()
        let title = "UI-QA-SUMMARY-" + run
        startTraining(title: title)
        tapReachable(app.buttons["精彩"].firstMatch)
        XCTAssertTrue(app.staticTexts["已标记 1 个时刻"].waitForExistence(timeout: 3))
        finishTraining()

        let card = app.descendants(matching: .any)["court.summary"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The finished record's summary shows")
        XCTAssertTrue(makeReachable(card))
        XCTAssertTrue(card.staticTexts[title].exists, "The summary names the record")
        XCTAssertTrue(card.staticTexts["记录已保存"].exists || app.descendants(matching: .any)["court.summary.saved"].exists)
        // No camera: nothing was measured, so speeds stay 「—」, never 0.
        for metric in ["最高", "平均"] {
            let tile = card.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", metric)).firstMatch
            XCTAssertTrue(tile.exists, "\(metric) tile")
            XCTAssertTrue(tile.label.contains("—") && !tile.label.contains("0"), "\(metric) unknown, not 0: \(tile.label)")
        }
        XCTAssertTrue(card.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "标记 1 个时刻")).firstMatch.exists)
        attach("summary-01-after-finish")

        // 「查看详情」 opens history on this record's detail.
        tapReachable(app.buttons["court.summary.details"].firstMatch)
        XCTAssertTrue(app.navigationBars["记录详情"].waitForExistence(timeout: 5), "Details open on the record")
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 3))
        attach("summary-02-details")
        app.navigationBars["记录详情"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5))
        app.navigationBars["历史记录"].buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForNonExistence(timeout: 5))

        // It stays until closed.
        XCTAssertTrue(card.waitForExistence(timeout: 3), "The summary stays after looking at the details")
        let close = app.buttons["court.summary.close"].firstMatch
        XCTAssertTrue(makeReachable(close))
        XCTAssertGreaterThanOrEqual(close.frame.height, 44); XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        close.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), "Closing removes the summary")

        // The next record's summary replaces nothing until it finishes, and starting hides it.
        startTraining(title: title + "-2")
        XCTAssertFalse(card.exists, "No summary while a record runs")
        finishTraining()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts[title + "-2"].exists)
    }

    /// App Store screenshots, opt-in: `TEST_RUNNER_COURT_UI_STORE_SHOTS=<folder>` with the labelled demo
    /// record from `court-probe demo-session` already in the app's Sessions folder. Walks history and
    /// the record's detail and writes every screen as a PNG into the folder; nothing here is measured.
    func testStoreScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["COURT_UI_STORE_SHOTS"] ?? environment["TEST_RUNNER_COURT_UI_STORE_SHOTS"] else {
            throw XCTSkip("Set TEST_RUNNER_COURT_UI_STORE_SHOTS to a folder and seed the demo record first")
        }
        func save(_ name: String) {
            Thread.sleep(forTimeInterval: 0.8)
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
            XCTAssertNoThrow(try XCUIScreen.main.screenshot().pngRepresentation.write(to: url))
        }
        save("00-home")
        let language = ProcessInfo.processInfo.environment["COURT_LANGUAGE"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_COURT_LANGUAGE"] ?? "zh-Hans"
        let history = language == "zh-Hans" ? app.buttons["历史记录"].firstMatch : app.buttons["court.history.open"].firstMatch
        tapReachable(history)
        XCTAssertTrue(app.collectionViews["court.history.list"].firstMatch.waitForExistence(timeout: 5))
        let record = language == "zh-Hans"
            ? app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "示例记录")).firstMatch
            : app.buttons["court.history.row"].firstMatch
        XCTAssertTrue(makeSheetReachable(record), "Seed the demo record with court-probe demo-session first")
        save("01-history")
        let shotsMode = language == "zh-Hans" ? app.buttons["球速与落点查询"].firstMatch : app.buttons["court.history.mode.shots"].firstMatch
        XCTAssertTrue(makeSheetReachable(shotsMode, towardTop: true)); shotsMode.tap()
        save("02-query")
        let query = app.scrollViews.firstMatch
        for page in 1...3 { query.swipeUp(velocity: .slow); save("02-query-\(page)") }
        let sessionsMode = language == "zh-Hans" ? app.buttons["按记录查看"].firstMatch : app.buttons["court.history.mode.sessions"].firstMatch
        XCTAssertTrue(makeSheetReachable(sessionsMode, towardTop: true)); sessionsMode.tap()
        XCTAssertTrue(makeSheetReachable(record)); record.tap()
        let detail = app.scrollViews["court.history.detail.scroll"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        save("03-detail-0")
        for page in 1...8 { detail.swipeUp(velocity: .slow); save("03-detail-\(page)") }
    }

    /// The line-call replay on the full-screen speed board, played from the demo record: frames go to
    /// TEST_RUNNER_COURT_UI_REPLAY_DEMO (a folder) every 0.4 s, for checking the animation and as the
    /// script of the store preview video. Seed the record first with `court-probe demo-session`.
    func testChallengeReplayDemo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["COURT_UI_REPLAY_DEMO"] ?? environment["TEST_RUNNER_COURT_UI_REPLAY_DEMO"] else {
            throw XCTSkip("Set TEST_RUNNER_COURT_UI_REPLAY_DEMO to a folder and seed the demo record first")
        }
        var shot = 0
        func save(_ name: String) {
            shot += 1
            let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%03d-", shot) + name + ".png")
            XCTAssertNoThrow(try XCUIScreen.main.screenshot().pngRepresentation.write(to: url))
        }
        enterServer()
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        let tile = app.buttons["court.analysis.speed.open"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "The demo record fills the speed tile")
        tapReachable(tile)
        XCTAssertTrue(app.descendants(matching: .any)["court.focus.speed"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5); save("board")
        let replay = app.buttons["court.speedboard.challenge"].firstMatch
        XCTAssertTrue(replay.waitForExistence(timeout: 5), "Judged demo shots offer the replay")
        replay.tap()
        XCTAssertTrue(app.descendants(matching: .any)["court.hawkeye.replay"].firstMatch.waitForExistence(timeout: 5))
        for step in 0..<18 { save("replay-a-\(step)"); Thread.sleep(forTimeInterval: 0.4) }
        // The same three replays as the store preview.
        for pass in ["b", "c"] {
            let previous = app.buttons["court.replay.previous"].firstMatch
            guard previous.isEnabled else { break }
            previous.tap()
            for step in 0..<18 { save("replay-\(pass)-\(step)"); Thread.sleep(forTimeInterval: 0.4) }
        }
        app.buttons["court.replay.close"].firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
    }

    /// The store preview video's script, run while `scripts/record-store-preview.sh` records the screen:
    /// the full-screen speed board, then three line-call replays from the demo record. Writes
    /// `marks.txt` (wall-clock seconds) to TEST_RUNNER_COURT_UI_STORE_PREVIEW so the script can trim.
    func testStorePreviewFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["COURT_UI_STORE_PREVIEW"] ?? environment["TEST_RUNNER_COURT_UI_STORE_PREVIEW"] else {
            throw XCTSkip("Set TEST_RUNNER_COURT_UI_STORE_PREVIEW to a folder; run it through scripts/record-store-preview.sh")
        }
        var marks = ""
        func mark(_ name: String) { marks += "\(name) \(Date().timeIntervalSince1970)\n" }
        enterServer()
        XCUIDevice.shared.orientation = .landscapeLeft
        assertLandscape()
        // The window reports landscape before the app has laid out for it; opening the board in that gap
        // records a portrait board and the preview then mixes orientations.
        Thread.sleep(forTimeInterval: 2.5)
        let tile = app.buttons["court.analysis.speed.open"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Seed the demo record with court-probe demo-session first")
        tapReachable(tile)
        XCTAssertTrue(app.descendants(matching: .any)["court.focus.speed"].firstMatch.waitForExistence(timeout: 5))
        assertLandscape()
        Thread.sleep(forTimeInterval: 0.6)
        mark("start")
        Thread.sleep(forTimeInterval: 3.0)
        app.buttons["court.speedboard.challenge"].firstMatch.tap()
        mark("replay1")
        XCTAssertTrue(app.descendants(matching: .any)["court.hawkeye.replay"].firstMatch.waitForExistence(timeout: 5))
        // A replay runs 5.8 s; the extra 1.6 s keeps its verdict and dimension bar on screen long enough to read.
        Thread.sleep(forTimeInterval: 7.4)
        for index in 2...3 {
            let previous = app.buttons["court.replay.previous"].firstMatch
            guard previous.isEnabled else { break }
            previous.tap()
            mark("replay\(index)")
            Thread.sleep(forTimeInterval: 7.4)
        }
        mark("end")
        try marks.write(to: URL(fileURLWithPath: folder).appendingPathComponent("marks.txt"), atomically: true, encoding: .utf8)
        // Stay on the replay, in landscape. The recorder stops when it sees this file, before
        // the test returns, tearDown rotates, and the runner terminates the app.
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// A record's 「导出」 menu offers the diagnostic package first; picking it opens the share sheet
    /// (the package itself, a zip built when a destination is chosen, is checked in `CameraDiagnosticsTests`).
    func testRecordDiagnosticPackageOpensTheShareSheet() throws {
        let run = String(Int(Date().timeIntervalSince1970) % 100_000)
        enterServer()
        startTraining(title: "UI-QA-DIAG-" + run)
        finishTraining()
        tapReachable(app.buttons["历史记录"].firstMatch)
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI-QA-DIAG-" + run)).firstMatch
        XCTAssertTrue(makeSheetReachable(record)); record.tap()
        let export = app.buttons["court.history.export"].firstMatch
        XCTAssertTrue(makeSheetReachable(export)); export.tap()
        let package = app.buttons["诊断包（不含录像）"].firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 5), "The export menu lists the diagnostic package")
        attach("diagnostics-01-export-menu")
        package.tap()
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The share sheet opens for the package")
        attach("diagnostics-02-share-sheet")
    }

    /// History opens on the session list; filters are 44-point controls; a record can be deleted
    /// from its detail page and by swiping its row, each after a confirmation. UI-QA records only.
    func testHistorySessionListFiltersAndDelete() throws {
        // Unique per run, so records left by an earlier run do not match.
        let run = String(Int(Date().timeIntervalSince1970) % 100_000)
        enterServer()
        startTraining(title: "UI-QA-DEL-DETAIL-" + run)
        finishTraining()
        startTraining(title: "UI-QA-DEL-SWIPE-" + run)
        finishTraining()
        tapReachable(app.buttons["历史记录"].firstMatch)

        let detailRecord = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI-QA-DEL-DETAIL-" + run)).firstMatch
        let swipeRecord = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI-QA-DEL-SWIPE-" + run)).firstMatch
        // At the largest text sizes the header fills the first screen and rows are created on scrolling.
        XCTAssertTrue(app.collectionViews["court.history.list"].firstMatch.waitForExistence(timeout: 5), "History opens on the session list")
        XCTAssertTrue(makeSheetReachable(swipeRecord), "The newest record is in the list")
        XCTAssertTrue(swipeRecord.label.contains("最高"), "Rows show the top speed, or — when unknown")
        XCTAssertGreaterThanOrEqual(swipeRecord.frame.height, 44)
        attach("history-01-session-list")

        XCTAssertTrue(makeSheetReachable(app.buttons["球速与落点查询"].firstMatch, towardTop: true)); app.buttons["球速与落点查询"].firstMatch.tap()
        let search = app.textFields["court.history.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.height, 44)
        for key in ["stroke", "availability", "order"] {
            let control = app.buttons["court.history.\(key)"].firstMatch
            XCTAssertTrue(makeSheetReachable(control), "missing filter \(key)")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "filter \(key) is a 44-point control")
        }
        let clear = app.buttons["court.history.clear"].firstMatch
        XCTAssertTrue(makeSheetReachable(clear))
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        attach("history-02-shot-query")
        XCTAssertTrue(makeSheetReachable(app.buttons["按记录查看"].firstMatch, towardTop: true)); app.buttons["按记录查看"].firstMatch.tap()

        XCTAssertTrue(makeSheetReachable(detailRecord)); detailRecord.tap()
        let delete = app.buttons["court.history.delete"].firstMatch
        XCTAssertTrue(makeSheetReachable(delete)); XCTAssertTrue(delete.isEnabled)
        XCTAssertTrue(app.buttons["court.history.export"].firstMatch.exists, "Exports sit in one menu")
        XCTAssertFalse(app.buttons["分享记录 JSON"].exists)
        attach("history-03-detail-manage")
        delete.tap()
        let confirm = app.buttons["删除记录"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attach("history-04-delete-confirmation")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5), "Deleting returns to the list")
        XCTAssertTrue(detailRecord.waitForNonExistence(timeout: 5))
        XCTAssertTrue(swipeRecord.exists, "Other records stay")

        XCTAssertTrue(makeSheetReachable(swipeRecord))
        swipeRecord.swipeLeft()
        let swipeDelete = app.buttons["删除"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5)); swipeDelete.tap()
        let confirmSwipe = app.buttons["删除记录"].firstMatch
        XCTAssertTrue(confirmSwipe.waitForExistence(timeout: 5)); confirmSwipe.tap()
        XCTAssertTrue(swipeRecord.waitForNonExistence(timeout: 5))
        attach("history-05-after-delete")
        app.buttons["完成"].firstMatch.tap()
    }

    /// `towardTop`: where to look while the element does not exist yet (a list creates rows only near
    /// the screen, so a header scrolled far away is gone, not just off screen).
    private func makeSheetReachable(_ element: XCUIElement, towardTop: Bool = false) -> Bool {
        for _ in 0..<24 {
            let visible = app.windows.firstMatch.frame.insetBy(dx: 8, dy: 70)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return true }
            // History pages: the pushed detail, the shot query or the session list (a collection view).
            let scroll: XCUIElement
            if app.scrollViews["court.history.detail.scroll"].exists { scroll = app.scrollViews["court.history.detail.scroll"].firstMatch }
            else if app.scrollViews["court.history.query.scroll"].exists { scroll = app.scrollViews["court.history.query.scroll"].firstMatch }
            else if app.collectionViews["court.history.list"].exists { scroll = app.collectionViews["court.history.list"].firstMatch }
            else if let last = app.scrollViews.allElementsBoundByIndex.last { scroll = last }
            else { return false }
            let moveDown = element.exists ? element.frame.midY < visible.minY : towardTop
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.35 : 0.75))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.75 : 0.35)))
        }
        return false
    }

    private var liveVideoOptIn: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["COURT_UI_LIVE_VIDEO"] == "1" || environment["TEST_RUNNER_COURT_UI_LIVE_VIDEO"] == "1"
    }

    private func assertNoScoringControls() {
        XCTAssertFalse(app.buttons["比赛"].exists)
        XCTAssertFalse(app.staticTexts["手动计分"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "得一分")).count, 0)
        XCTAssertFalse(app.textFields["球员 / 队伍 A"].exists)
    }

    private func startTraining(title: String) {
        let field = app.textFields["给这次上场起个名字"].firstMatch
        tapReachable(field, minimumTouchSize: false)
        // The field keeps the previous record's name; clear it before typing a new one.
        // A tap may land the cursor mid-text (large text sizes), so repeat until the field is empty.
        for _ in 0..<4 {
            guard let value = field.value as? String, !value.isEmpty, value != field.placeholderValue else { break }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
        }
        // Return dismisses the keyboard, which otherwise covers the start button.
        field.typeText(title + "\n")
        let start = app.buttons["开始记录"].firstMatch
        tapReachable(start)
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists)
    }

    private func finishTraining() {
        tapReachable(app.buttons["结束"].firstMatch)
        let confirmation = app.buttons["结束并保存"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(app.buttons["开始记录"].waitForExistence(timeout: 5))
    }

    private func assertLandscape(file: StaticString = #filePath, line: UInt = #line) {
        let condition = NSPredicate { [weak self] _, _ in
            guard let frame = self?.app.windows.firstMatch.frame else { return false }
            return frame.width > frame.height
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: nil)], timeout: 6), .completed, file: file, line: line)
    }

    private func assertPortrait(file: StaticString = #filePath, line: UInt = #line) {
        let condition = NSPredicate { [weak self] _, _ in
            guard let frame = self?.app.windows.firstMatch.frame else { return false }
            return frame.height > frame.width
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: nil)], timeout: 6), .completed, file: file, line: line)
    }

    private func assertServerColumns(file: StaticString = #filePath, line: UInt = #line) {
        let preview = app.otherElements["court.server.preview"].firstMatch
        let panel = app.otherElements["court.session.panel"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 4), "Preview container must expose a test identifier", file: file, line: line)
        XCTAssertTrue(panel.waitForExistence(timeout: 4), "Session panel must expose a test identifier", file: file, line: line)
        let left = preview.frame, right = panel.frame
        XCTAssertLessThanOrEqual(left.maxX, right.minX + 1, "Landscape preview and controls must occupy separate columns", file: file, line: line)
        XCTAssertEqual(left.minY, right.minY, accuracy: 2, "The two columns must begin at the same vertical position", file: file, line: line)
        XCTAssertGreaterThan(left.width, 200, file: file, line: line)
        XCTAssertGreaterThanOrEqual(right.width, 280, file: file, line: line)
        XCTAssertLessThanOrEqual(right.maxX, app.windows.firstMatch.frame.maxX, file: file, line: line)
    }

    private func assertPreviewRemainsVisible(frameBeforeScrolling: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.otherElements["court.server.preview"].firstMatch.frame
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(frame.minX, frameBeforeScrolling.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.minY, frameBeforeScrolling.minY, accuracy: 1, "Scrolling session controls must not move the live picture", file: file, line: line)
        XCTAssertEqual(frame.width, frameBeforeScrolling.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.height, frameBeforeScrolling.height, accuracy: 1, file: file, line: line)
        XCTAssertTrue(window.contains(frame), "The full preview must remain on screen while session controls are used", file: file, line: line)
    }

    @discardableResult private func makeReachable(_ element: XCUIElement) -> Bool {
        // The portrait record bar is pinned to the bottom edge (on an SE right at it) and never scrolls.
        let bar = app.descendants(matching: .any)["court.session.bar"].firstMatch
        if element.exists, bar.exists, bar.frame.contains(element.frame), element.isHittable { return true }
        // The two-column landscape workspace scrolls its columns separately: scroll the one the control is in.
        let preview = app.scrollViews["court.preview.scroll"].firstMatch
        let inPreview = preview.exists && element.exists && preview.frame.minX <= element.frame.midX && element.frame.midX <= preview.frame.maxX
        let scroll = inPreview ? preview : app.scrollViews["court.connect.scroll"].exists ? app.scrollViews["court.connect.scroll"].firstMatch :
            app.navigationBars["持拍手"].exists ? app.scrollViews["court.handedness.scroll"].firstMatch :
            app.scrollViews["court.camera.sidebar"].exists ? app.scrollViews["court.camera.sidebar"].firstMatch :
            app.scrollViews["court.workspace.scroll"].firstMatch.exists
            ? app.scrollViews["court.workspace.scroll"].firstMatch : app.scrollViews.firstMatch
        // At the largest text size an SE camera page is several thousand points long.
        for _ in 0..<30 {
            let window = app.windows.firstMatch.frame
            // Portrait keeps clear of the status bar; landscape phones hide it, so the top row counts.
            var visible = window.insetBy(dx: 8, dy: window.width > window.height ? 8 : 35)
            // The display's pinned toolbar covers the page scrolling under it: a control there is not
            // reachable (XCUI may still call it hittable, and the tap would go to the toolbar).
            let toolbar = app.descendants(matching: .any)["court.server.toolbar"].firstMatch
            if toolbar.exists, !toolbar.frame.contains(element.exists ? element.frame : .zero), toolbar.frame.maxY < window.midY {
                let top = toolbar.frame.maxY + 4
                visible = CGRect(x: visible.minX, y: max(visible.minY, top), width: visible.width, height: visible.maxY - max(visible.minY, top))
            }
            // Hittability is asked only on screen: far off screen XCUI cannot compute it and fails the test.
            if element.exists, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)), element.isHittable { return true }
            guard scroll.exists else { return false }
            // Above the visible area (off screen or under the pinned toolbar): scroll toward the top.
            let moveDown = element.exists && element.frame.midY < visible.minY
            if toolbar.exists, element.exists, element.frame.height < visible.height, visible.minY < visible.maxY,
               abs(visible.midY - element.frame.midY) < visible.height * 1.5 {
                // Display page, element nearby: drag it by the distance to the middle of the visible area and
                // hold before lifting, so no fling overshoots the short band below the pinned toolbar.
                let distance = max(-visible.height * 0.4, min(visible.height * 0.4, visible.midY - element.frame.midY))
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: distance)),
                           withVelocity: .slow, thenHoldForDuration: 0.15)
                continue
            }
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.35 : 0.72))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.72 : 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        return false
    }

    private func tapReachable(_ element: XCUIElement, minimumTouchSize: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(makeReachable(element), "Control could not be reached by scrolling: \(element)", file: file, line: line)
        XCTAssertTrue(element.isEnabled, file: file, line: line)
        if minimumTouchSize {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "Interactive controls need a 44-point touch target", file: file, line: line)
        }
        element.tap()
    }

    private func attach(_ name: String) {
        // XCUIApplication.screenshot() on this SDK returns already-rotated pixels
        // with a second orientation tag; the screen API preserves correct pixels.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
