import Foundation

/// Zoom range of the camera's 1080p60 format, in the units the system camera shows: 0.5× is the
/// ultra-wide lens, 1× the main lens, 4× the telephoto on a triple camera. On a multi-lens camera
/// the device's own factor 1 is its widest lens, so `displayMultiplier` is 0.5; a single camera has
/// multiplier 1 and starts at 1×. Zoom is continuous between the ends; the presets are the lens
/// factors and twice each lens (their native crops), like the system camera. Every factor keeps the
/// 1920×1080 buffers. Past twice the lens in use the 1080p picture is upscaled and softens.
public struct CameraZoomRange: Equatable, Sendable {
    /// The system camera's video zoom limit.
    public static let cap = 25.0
    public let minimum: Double
    public let maximum: Double
    /// Display factor of the device's zoom factor 1.
    public let displayMultiplier: Double
    /// Display factors where each lens starts, widest first (e.g. 0.5, 1, 4).
    public let lenses: [Double]

    /// `formatMaximum` and `switchOvers` are device factors as AVFoundation reports them.
    /// nil when the format cannot zoom at all, so no control is shown.
    public init?(formatMaximum: Double, displayMultiplier: Double = 1, switchOvers: [Double] = []) {
        guard formatMaximum.isFinite, displayMultiplier.isFinite, displayMultiplier > 0, displayMultiplier <= 1 else { return nil }
        let multiplier = (displayMultiplier * 100).rounded() / 100
        minimum = multiplier
        maximum = min(formatMaximum * multiplier, Self.cap)
        guard maximum > minimum + 0.01 else { return nil }
        self.displayMultiplier = multiplier
        lenses = [multiplier] + switchOvers.filter(\.isFinite).map { ($0 * multiplier * 100).rounded() / 100 }.filter { $0 > multiplier && $0 <= formatMaximum * multiplier }
    }

    /// Lens factors and twice each lens from 1× up, within the range: 0.5 / 1 / 2 / 4 / 8 on a triple camera.
    public var presets: [Double] {
        var values = Set(lenses.map { ($0 * 100).rounded() / 100 })
        for lens in lenses + [1] where lens >= 1 { values.insert(lens * 2) }
        if minimum <= 1 { values.insert(1) }
        return values.filter { $0 >= minimum - 0.001 && $0 <= maximum + 0.001 }.sorted()
    }
    /// The range includes the ultra-wide lens.
    public var hasUltraWide: Bool { minimum < 0.99 }
    public func clamp(_ factor: Double) -> Double {
        guard factor.isFinite else { return max(minimum, min(1, maximum)) }
        return (min(max(factor, minimum), maximum) * 100).rounded() / 100
    }
    /// Device zoom factor for a display factor.
    public func deviceFactor(_ factor: Double) -> Double { clamp(factor) / displayMultiplier }
    /// Highest factor the lens in use reaches without upscaling: every lens on iPhone 13 and later
    /// reads at least 12 MP (4032 px wide), which crops 2× to 1920 px (the iPhone 17 Pro Max main
    /// camera's 1080p60 format reports exactly 2×).
    public func nativeLimit(_ factor: Double) -> Double { (lenses.last(where: { $0 <= factor + 0.001 }) ?? minimum) * 2 }
    /// The factor softens the image (upscaled past the lens's native crop).
    public func isUpscaled(_ factor: Double) -> Bool { factor > max(nativeLimit(factor), 1) + 0.01 }
    /// Continuous change from a drag or a VoiceOver swipe: `steps` doublings (negative zooms out).
    public func stepped(_ factor: Double, by steps: Double) -> Double { clamp(factor * pow(2, steps)) }

    /// "0.5×", "1×", "2.3×", "12×". One decimal below 10×, whole numbers above, like the system camera.
    public static func title(_ factor: Double) -> String {
        guard factor.isFinite else { return "—" }
        if factor >= 9.95 { return String(Int(factor.rounded())) + "×" }
        let rounded = (factor * 10).rounded() / 10
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)) + "×"
    }
}
