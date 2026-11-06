import Foundation

/// Source-frame cadence of the frame-pair analysis lane, shared with camera-side frame selection.
/// Every source frame advances it, but pixels are read only where `needsPixels` is true
/// (at 60 fps: ordinals 6k, 6k+1 and 6k+2, about 10 pairs a second). Identical rules on both
/// sides keep a selector aligned.
public struct TennisFrameCadence: Sendable {
    public let fps: Double, period: Int, delay: Int
    public private(set) var ordinal = 0
    private var lastPTS: Double?
    private var streamID: UUID?
    public init(fps: Double) {
        let cadence = Self.pairing(fps: fps)
        self.fps = fps; period = cadence.period; delay = cadence.delay
    }
    /// About 10 Hz anchors; the pair frame follows one thirtieth of a second later (at least one frame).
    static func pairing(fps: Double) -> (period: Int, delay: Int) {
        let rounded = fps.rounded(.toNearestOrAwayFromZero)
        return (max(1,Int(rounded / 10)), max(1,Int(rounded / 30)))
    }
    /// Advances one source frame. True when this frame starts a new temporal run: a different stream,
    /// non-increasing PTS, or a gap above 3.5 source frames. Up to two frames may be missing (2026-11-06):
    /// a recorder or camera that drops a frame is not a break, and resetting there threw away the flight in
    /// the air over one dropped frame every 17 seconds.
    @discardableResult public mutating func advance(pts: Double, streamID: UUID) -> Bool {
        let restarted = self.streamID != streamID || lastPTS.map { pts <= $0 || pts - $0 > 3.5 / fps } == true
        if restarted { ordinal = 0; self.streamID = streamID }
        lastPTS = pts; ordinal += 1
        return restarted
    }
    /// The next frame starts a new temporal run at ordinal 1.
    public mutating func restart() { ordinal = 0; lastPTS = nil; streamID = nil }
    public var needsPixels: Bool { ordinal >= period && ordinal % period <= delay }
    /// 0 = anchor, 1 = adjacent, `delay` = pair frame; nil when this frame's pixels are never read.
    public var slot: Int? { needsPixels ? ordinal % period : nil }
}
