import Foundation
import Observation
import CourtCore
#if os(iOS)
import UIKit
#endif

/// Screen brightness seam so the standby policy can be tested off device.
protocol StandbyScreen: AnyObject {
    /// Current brightness 0…1, or nil where the platform has no app-controlled brightness (macOS).
    var brightness: Double? { get }
    func setBrightness(_ value: Double)
}

/// Camera-screen power policy while recording (docs/camera-side-analysis.md §8).
///
/// After `delay` seconds without a touch the camera UI goes black (the preview layer is not
/// mounted) and the screen is dimmed. A tap only wakes it, for `peekSeconds`; controls are never
/// triggered by that tap. App-set brightness lasts until the device locks, so every exit path —
/// ineligible, scene inactive or background, wake, teardown — restores the saved value.
@MainActor @Observable
final class CameraStandby {
    enum Delay: Int, CaseIterable, Identifiable {
        case ten = 10, twenty = 20, thirty = 30, sixty = 60, never = 0
        var id: Int { rawValue }
        var title: String { self == .never ? courtText("从不") : courtFormat("%1$@ 秒", "\(rawValue)") }
    }
    static let peekSeconds: TimeInterval = 15
    static let dimBrightness = 0.1
    private static let delayKey = "court.camera.standby-delay"

    private(set) var isDimmed = false
    private(set) var eligible = false
    /// Seconds until a woken screen dims again; nil when not in a temporary wake.
    private(set) var peekRemaining: Int?
    var delay: Delay {
        didSet {
            UserDefaults.standard.set(delay.rawValue, forKey: Self.delayKey)
            if delay == .never { exitDim() }
            lastActivity = now()
        }
    }
    @ObservationIgnored private var lastActivity: Date
    @ObservationIgnored private var peeking = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var savedBrightness: Double?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let screen: StandbyScreen

    init(screen: StandbyScreen = SystemStandbyScreen(), now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
        self.screen = screen; self.now = now
        let stored = defaults.object(forKey: Self.delayKey) as? Int
        delay = stored.flatMap(Delay.init(rawValue:)) ?? .twenty
        lastActivity = now()
    }

    /// Recording-side condition; standby only applies while it holds.
    func update(eligible value: Bool) {
        guard value != eligible else { return }
        eligible = value
        lastActivity = now(); peeking = false; peekRemaining = nil
        if !value { exitDim() }
    }
    /// Any touch on the camera UI postpones dimming.
    func noteActivity() { lastActivity = now() }
    /// A tap on the black screen: show the camera UI for `peekSeconds`, then dim again.
    func wake() {
        guard isDimmed || peeking else { return }
        exitDim(); peeking = true; lastActivity = now()
        peekRemaining = Int(Self.peekSeconds)
    }
    /// Called once a second.
    func tick() {
        guard eligible, !suspended, delay != .never else { peekRemaining = nil; return }
        guard !isDimmed else { return }
        let limit = peeking ? Self.peekSeconds : TimeInterval(delay.rawValue)
        let idle = now().timeIntervalSince(lastActivity)
        if peeking { peekRemaining = max(0, Int((limit - idle).rounded(.up))) }
        if idle >= limit { enterDim() }
    }
    /// Scene inactive or background (including Control Center): restore brightness immediately.
    func suspend() { suspended = true; exitDim(); peeking = false; peekRemaining = nil }
    func resume() { suspended = false; lastActivity = now() }
    /// Leaving the camera role or stopping capture.
    func teardown() { update(eligible: false); exitDim() }

    private func enterDim() {
        peeking = false; peekRemaining = nil
        if let current = screen.brightness {
            savedBrightness = current
            if current > Self.dimBrightness { screen.setBrightness(Self.dimBrightness) }
        }
        isDimmed = true
    }
    private func exitDim() {
        if let saved = savedBrightness { screen.setBrightness(saved); savedBrightness = nil }
        isDimmed = false
    }
}

final class SystemStandbyScreen: StandbyScreen {
    #if os(iOS)
    @MainActor private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }
    var brightness: Double? { MainActor.assumeIsolated { screen.map { Double($0.brightness) } } }
    func setBrightness(_ value: Double) { MainActor.assumeIsolated { screen?.brightness = CGFloat(min(1, max(0, value))) } }
    #else
    var brightness: Double? { nil }
    func setBrightness(_ value: Double) {}
    #endif
}
