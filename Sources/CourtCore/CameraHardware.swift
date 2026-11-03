import Foundation

/// Which iPhones can be the camera. iPhone 13 and later (hardware identifiers iPhone14,x and up,
/// which includes the iPhone SE 3rd generation) qualify: they all capture 1080p60 and run the
/// analysis models on an A15 or newer chip. Later models qualify without a code change.
/// Only `measured` models have had a Phase 0 load measurement (docs/camera-side-analysis.md §11);
/// the others run the same load shedding but their heat and battery behaviour is unmeasured.
public enum CameraHardware {
    /// First hardware generation that qualifies (iPhone14,x = iPhone 13 family).
    public static let firstSupportedGeneration = 14
    /// Models measured with the Phase 0 mode.
    public static let measured: Set<String> = ["iPhone18,2"]
    /// Marketing names, from Xcode's simulator device types (2026-10-29).
    public static let names: [String: String] = [
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE（第 3 代）", "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air", "iPhone18,5": "iPhone 17e", "iPhone19,2": "iPhone 18 Pro",
        "iPhone19,3": "iPhone 18 Pro Max",
    ]

    /// Generation of an "iPhoneN,M" identifier, nil for anything else (Mac, iPad, simulator name).
    public static func generation(_ hardware: String) -> Int? {
        guard hardware.hasPrefix("iPhone") else { return nil }
        let parts = hardware.dropFirst("iPhone".count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), Int(parts[1]) != nil else { return nil }
        return major
    }
    public static func isSupported(_ hardware: String) -> Bool { (generation(hardware) ?? 0) >= firstSupportedGeneration }
    public static func isMeasured(_ hardware: String) -> Bool { measured.contains(hardware) }
    /// "iPhone 13 mini", or the identifier itself for a model newer than this table.
    public static func name(_ hardware: String) -> String { names[hardware] ?? hardware }
}
