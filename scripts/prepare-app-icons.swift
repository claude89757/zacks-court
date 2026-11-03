import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Export the approved artwork into platform icon formats. The source artwork
// stays intact; macOS alone gets an antialiased mask and transparent safe margin.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let files = FileManager.default
let brand = root.appendingPathComponent("assets/brand")
let masterURL = brand.appendingPathComponent("zacks-court-logo-master.png")
guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil),
      master.width == master.height else { fatalError("A square logo master is required") }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ image: CGImage, size: Int, rounded: Bool = false, transparent: Bool = false) -> CGImage {
    let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace, bitmapInfo: alpha.rawValue) else {
        fatalError("Cannot allocate icon bitmap")
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let side = CGFloat(size)
    var rect = CGRect(x: 0, y: 0, width: side, height: side)
    if rounded {
        rect = rect.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
        let radius = side * 185 / 1024
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }
    context.draw(image, in: rect)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed: \(url.path)") }
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

let catalog = root.appendingPathComponent("apps/iphone/ZacksCourt/Assets.xcassets")
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
try files.createDirectory(at: appIcon, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))

let slots: [(String, String, Int)] = [
    ("iphone", "20", 2), ("iphone", "20", 3),
    ("iphone", "29", 2), ("iphone", "29", 3),
    ("iphone", "40", 2), ("iphone", "40", 3),
    ("iphone", "60", 2), ("iphone", "60", 3),
    ("ipad", "20", 1), ("ipad", "20", 2),
    ("ipad", "29", 1), ("ipad", "29", 2),
    ("ipad", "40", 1), ("ipad", "40", 2),
    ("ipad", "76", 1), ("ipad", "76", 2),
    ("ipad", "83.5", 2), ("ios-marketing", "1024", 1)
]
var entries: [[String: String]] = []
var exported = Set<Int>()
for (idiom, points, scale) in slots {
    let pixels = Int(Double(points)! * Double(scale))
    let filename = "icon-\(pixels).png"
    if exported.insert(pixels).inserted {
        try writePNG(render(master, size: pixels), to: appIcon.appendingPathComponent(filename))
    }
    entries.append(["idiom": idiom, "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
}
try writeJSON(["images": entries, "info": info], to: appIcon.appendingPathComponent("Contents.json"))

let macMaster = render(master, size: 1024, rounded: true, transparent: true)
try writePNG(macMaster, to: brand.appendingPathComponent("zacks-court-logo-mac.png"))
let iconset = root.appendingPathComponent(".local/app-icons/ZacksCourt.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let icon = render(macMaster, size: points * scale, transparent: true)
        try writePNG(icon, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", brand.appendingPathComponent("ZacksCourt.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { fatalError("ICNS export failed") }
print("Exported iPhone/iPad AppIcon catalog and macOS ZacksCourt.icns from the approved logo master.")
