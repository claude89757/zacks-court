#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CourtCore
@testable import CourtApp

/// Renders the camera's zoom presets offscreen for the triple, dual-wide and single cameras, unlocked
/// and locked, at a few factors. Gestures and the dial are not exercised (they need touch).
/// Set COURT_ZOOM_SNAPSHOTS=/path to also write the PNGs for a visual check.
@MainActor
final class CameraZoomLayoutTests: XCTestCase {
    func testPresetsRenderForEachCamera() throws {
        let cameras: [(String, CameraZoomRange?)] = [
            ("triple", CameraZoomRange(formatMaximum: 135, displayMultiplier: 0.5, switchOvers: [2, 8])),
            ("dual", CameraZoomRange(formatMaximum: 135, displayMultiplier: 0.5, switchOvers: [2])),
            ("single", CameraZoomRange(formatMaximum: 135, )),
        ]
        XCTAssertEqual(cameras[0].1?.presets, [0.5, 1, 2, 4, 8])
        XCTAssertEqual(cameras[1].1?.presets, [0.5, 1, 2])
        XCTAssertEqual(cameras[2].1?.presets, [1, 2])
        let folder = ProcessInfo.processInfo.environment["COURT_ZOOM_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        let camera = CameraModel()
        camera.streaming = true
        for (name, range) in cameras {
            camera.zoomRange = range
            for factor in [0.5, 1, 2.6, 6] {
                camera.zoomFactor = range?.clamp(factor) ?? 1
                let view = ZStack(alignment: .bottomTrailing) { Color.gray; CameraZoomControl(camera: camera).padding(14) }
                    .frame(width: 520, height: 120).environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(name) \(factor)")
                if let folder {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: folder.appendingPathComponent("zoom-\(name)-\(factor).png"))
                }
            }
        }
        camera.streaming = false
    }
}
#endif
