#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CourtCore
@testable import CourtApp

/// Renders the courtside board offscreen at phone, tablet, laptop and small-window sizes in both
/// modes. Synthetic rows only exercise the layout, never analysis accuracy.
/// Set COURT_SPEEDBOARD_SNAPSHOTS=/path to also write the PNGs for a visual check.
@MainActor
final class SpeedBoardLayoutTests: XCTestCase {
    private func rows() -> [TennisShotEvent] {
        let stream = UUID()
        let serves: [Double?] = [142, 151, nil, 138, 163, 147, 156]
        var events: [TennisShotEvent] = []
        for (index, speed) in serves.enumerated() {
            let start = Double(index) * 20
            events.append(TennisShotEvent(streamID: stream, sourcePTS: start, stroke: .serve, confidence: 0.9, speedKPH: speed))
            events.append(TennisShotEvent(streamID: stream, sourcePTS: start + 1.2, stroke: .forehand, confidence: 0.8, speedKPH: 96))
        }
        return events
    }

    /// Height in pixels of the band of rows that hold many brand-green pixels: the large digits.
    /// The trend's current-serve dot is green too but far too narrow to count as a row of digits.
    private func greenDigitHeight(_ image: CGImage) -> Int? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let minimum: Int = max(12, width / 40)
        var first: Int?, last: Int?
        for y in 0..<height {
            var count = 0
            for x in 0..<width {
                let i: Int = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if g > 200 && r > 160 && r < 225 && b < 130 { count += 1 }
            }
            if count >= minimum { if first == nil { first = y }; last = y }
        }
        guard let first, let last else { return nil }
        return last - first + 1
    }

    func testBoardRendersInBothModesAcrossWindowSizes() throws {
        let sizes: [(String, CGSize)] = [
            ("phone-portrait", .init(width: 393, height: 852)), ("phone-landscape", .init(width: 852, height: 393)),
            ("tablet", .init(width: 1180, height: 820)), ("laptop", .init(width: 1440, height: 900)),
            ("small-wide", .init(width: 640, height: 300)), ("small-tall", .init(width: 320, height: 420)),
        ]
        let folder = ProcessInfo.processInfo.environment["COURT_SPEEDBOARD_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        let defaults = UserDefaults.standard, key = "court.speedboard.mode"
        let saved = defaults.string(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        for mode in CourtSpeedBoardMode.allCases {
            defaults.set(mode.rawValue, forKey: key)
            for (data, events) in [("data", rows()), ("empty", [])] {
                for (name, size) in sizes {
                    let view = CourtSpeedBoard(events: events, isLive: true).frame(width: size.width, height: size.height)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage, "\(mode) \(data) \(name)")
                    XCTAssertEqual(image.width, Int(size.width)); XCTAssertEqual(image.height, Int(size.height))
                    // The current speed is the board: its digits (the brand-green rows) are as tall as three
                    // digits can be across the width, or take most of the height when the board is wide.
                    if data == "data", size.height >= 380 {
                        let digits = try XCTUnwrap(greenDigitHeight(image), "\(mode) \(name)")
                        let inset: Double = max(16, min(48, Double(size.width) * 0.035))
                        let acrossWidth: Double = (Double(size.width) - 2 * inset) / (3 * Double(SpeedHeroLayout.digitAdvance)) * Double(SpeedHeroLayout.capHeight)
                        let bound: Double = min(acrossWidth, Double(size.height) * 0.6)
                        XCTAssertGreaterThan(Double(digits), bound * 0.85, "\(mode) \(name): digits \(digits) of \(Int(size.height))")
                    }
                    if let folder {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        try png.write(to: folder.appendingPathComponent("\(mode.rawValue)-\(data)-\(name).png"))
                    }
                }
            }
        }
        // The board caps text at accessibility2; at the largest size the number still leads.
        for mode in CourtSpeedBoardMode.allCases {
            defaults.set(mode.rawValue, forKey: key)
            let view = CourtSpeedBoard(events: rows(), isLive: true).frame(width: 852, height: 393)
                .environment(\.dynamicTypeSize, .accessibility5)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let digits = try XCTUnwrap(greenDigitHeight(image), "\(mode) large text")
            XCTAssertGreaterThan(Double(digits) / 393, 0.45, "\(mode) large text")
            if let folder {
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("\(mode.rawValue)-data-large-text.png"))
            }
        }
        // README examples (docs/images/speedboard-example.png, speedboard-serve-example.png): the Mac window at its default
        // size with demo values. AppKit buttons do not render offscreen, so the full-screen icon
        // is drawn over its placeholder.
        if let folder {
            for (mode, file) in [(CourtSpeedBoardMode.all, "readme-example.png"), (.serve, "readme-serve-example.png")] {
                defaults.set(mode.rawValue, forKey: key)
                let inset = 1100 * 0.035
                let view = CourtSpeedBoard(events: rows(), isLive: true).frame(width: 1100, height: 700)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 18)).foregroundStyle(.white)
                            .frame(width: 60, height: 60).background(CourtStyle.background).padding(.top, inset - 8).padding(.trailing, inset - 8)
                    }
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent(file))
            }
        }
    }
}
#endif
