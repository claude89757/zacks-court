import Foundation
import CoreVideo
import CoreML

/// The optional reference chain: a frame-pair analysis lane that runs the S家 models locally, for
/// comparison only. Its code and models stay on each developer's machine and never enter Git
/// (`.local/s-chain/`, `.local/s-models/`; docs/s-reference.md). `scripts/reference-chain.sh on`
/// links the code into `Sources/CourtCore/Reference/` for the `both`/`sjia` builds, and the default
/// and release builds unlink it, so they contain none of it and `isAvailable` is false there.
public enum ReferenceChain {
    /// The local implementation registers under this Objective-C class name.
    private static let factory: ReferenceChainFactory? =
        (NSClassFromString("CourtReferenceChain") as? ReferenceChainFactory.Type)?.init()

    public static var isAvailable: Bool { factory != nil }
    /// Shown when a reference lane is requested from a build without it.
    public static let unavailableReason = "这个构建不含 S家参照链（只在本地带 S家资料的构建里有）"

    public static func makeEngine(configuration: TennisAnalysisConfiguration) throws -> ReferenceAnalysisEngine {
        try laneEngine(configuration)
    }
    static func laneEngine(_ configuration: TennisAnalysisConfiguration) throws -> ReferenceLaneEngine {
        guard let factory else { throw CourtError.message(unavailableReason) }
        return try factory.engine(configuration)
    }
    static func bounceResolver(_ configuration: TennisAnalysisConfiguration) throws -> ReferenceBounceResolver {
        guard let factory else { throw CourtError.message(unavailableReason) }
        return try factory.bounceResolver(configuration)
    }
}

/// Implemented only by the local reference chain.
protocol ReferenceChainFactory: AnyObject {
    init()
    func engine(_ configuration: TennisAnalysisConfiguration) throws -> ReferenceLaneEngine
    func bounceResolver(_ configuration: TennisAnalysisConfiguration) throws -> ReferenceBounceResolver
}

/// Serial-queue frame consumer of the reference chain. Feed every decoded source frame in PTS order;
/// frames outside `TennisFrameCadence.needsPixels` may be passed without pixels.
public protocol ReferenceAnalysisEngine: AnyObject {
    /// Seconds between court refreshes (minimum 2). Load shedding may raise it.
    var courtRefreshInterval: Double { get set }
    /// Frames whose pixels the cadence needed but the caller did not supply.
    var pixelMisses: Int { get }
    func reset()
    func reconfigure(near: TennisHandedness, far: TennisHandedness) throws
    func process(_ pixelBuffer: CVPixelBuffer?, pts: Double, streamID: UUID) throws -> TennisAnalysisSnapshot?
    /// Deferred bounce work produced since the last call (only with `defersBounceLocalization`).
    func takeBounceRequests() -> [TennisBounceRequest]
    /// Flushes the final open row.
    func finish() -> TennisAnalysisSnapshot?
}

/// What the camera-side analyzer additionally needs from the reference lane.
protocol ReferenceLaneEngine: ReferenceAnalysisEngine {
    /// Court scores a load probe needs.
    var currentCourtScores: MLMultiArray? { get }
    /// Applies a separate lane's bounce result; nil when the row has left the engine's window.
    func applyBounce(eventID: UUID, estimate: TennisBounceEstimate, mapping: TennisCourtMapping?) -> TennisAnalysisSnapshot?
}

/// The separate bounce lane of the reference chain (owns its own model instance).
protocol ReferenceBounceResolver: AnyObject {
    func resolve(_ request: TennisBounceRequest) throws -> (estimate: TennisBounceEstimate, mapping: TennisCourtMapping?)
}
