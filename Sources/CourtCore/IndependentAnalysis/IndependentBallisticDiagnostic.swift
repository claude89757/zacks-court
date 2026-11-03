import Foundation
import CoreMedia

public enum IndependentBallisticError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}
private func independentRequire(_ value: Bool, _ reason: String) throws {
    if !value { throw IndependentBallisticError.invalid(reason) }
}

/// An assumed pinhole camera, never a qualified calibration. Matrices are row-major;
/// camera coordinates are R * world + t, and pixels are K * camera / camera.z.
public struct IndependentBallisticCamera: Codable, Sendable {
    public let sourceID: String
    public let width: Int, height: Int
    public let rowMajorK: [Double], rowMajorR: [Double], t: [Double]
    public let assumptions: [String]
    public init(sourceID: String, width: Int, height: Int, rowMajorK: [Double], rowMajorR: [Double], t: [Double], assumptions: [String]) throws {
        self.sourceID = sourceID; self.width = width; self.height = height
        self.rowMajorK = rowMajorK; self.rowMajorR = rowMajorR; self.t = t; self.assumptions = assumptions
        try validate()
    }
    public func validate() throws {
        try independentRequire(!sourceID.isEmpty && sourceID.utf8.count <= 256 && width > 0 && height > 0 && width <= 16384 && height <= 16384, "Invalid camera source or dimensions")
        try independentRequire(rowMajorK.count == 9 && rowMajorR.count == 9 && t.count == 3 && (rowMajorK + rowMajorR + t).allSatisfy(\.isFinite), "Nonfinite or malformed camera")
        let k = rowMajorK, r = rowMajorR
        try independentRequire(k[0] > 0 && k[4] > 0 && k[3] == 0 && k[6] == 0 && k[7] == 0 && k[8] == 1, "K must be upper triangular with positive focal lengths and bottom row 0,0,1")
        for i in 0..<3 { for j in 0..<3 {
            var dot = 0.0
            for m in 0..<3 { dot += r[m * 3 + i] * r[m * 3 + j] }
            try independentRequire(abs(dot - (i == j ? 1 : 0)) <= 1e-6, "R is not orthonormal")
        } }
        let det = r[0]*(r[4]*r[8]-r[5]*r[7])-r[1]*(r[3]*r[8]-r[5]*r[6])+r[2]*(r[3]*r[7]-r[4]*r[6])
        try independentRequire(abs(det-1) <= 1e-6, "R must have determinant +1")
        try independentRequire(!assumptions.isEmpty && assumptions.count <= 64 && assumptions.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 }, "Explicit bounded camera assumptions required")
    }
    private enum CodingKeys: String, CodingKey { case sourceID, width, height, rowMajorK, rowMajorR, t, assumptions }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceID: c.decode(String.self, forKey: .sourceID), width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height), rowMajorK: c.decode([Double].self, forKey: .rowMajorK), rowMajorR: c.decode([Double].self, forKey: .rowMajorR), t: c.decode([Double].self, forKey: .t), assumptions: c.decode([String].self, forKey: .assumptions))
    }
}

public struct IndependentBallisticPixel: Codable, Sendable {
    public let x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct IndependentBallisticFrame: Codable, Sendable {
    public let frameIndex: Int
    public let sourceID: String
    public let time: IndependentBallFrameTime
    public let originalPixel: IndependentBallisticPixel?
    public let missingReason: String?
    public init(frameIndex: Int, sourceID: String, time: IndependentBallFrameTime, originalPixel: IndependentBallisticPixel?, missingReason: String? = nil) {
        self.frameIndex = frameIndex; self.sourceID = sourceID; self.time = time; self.originalPixel = originalPixel; self.missingReason = missingReason
    }
    private enum CodingKeys: String, CodingKey { case frameIndex, sourceID, time, originalPixel, missingReason }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frameIndex:try c.decode(Int.self,forKey:.frameIndex),sourceID:try c.decode(String.self,forKey:.sourceID),time:try c.decode(IndependentBallFrameTime.self,forKey:.time),originalPixel:try c.decodeIfPresent(IndependentBallisticPixel.self,forKey:.originalPixel),missingReason:try c.decodeIfPresent(String.self,forKey:.missingReason))
        _ = try time.mediaTime()
        try independentRequire(frameIndex >= 0 && !sourceID.isEmpty && sourceID.utf8.count <= 256, "Invalid frame identity")
        if let p = originalPixel {
            try independentRequire(p.x.isFinite && p.y.isFinite && p.x >= 0 && p.y >= 0 && missingReason == nil, "Invalid original pixel or contradictory missing reason")
        } else { try independentRequire(missingReason.map { !$0.isEmpty && $0.utf8.count <= 4096 } == true, "Missing observations require a reason") }
    }
}
public struct IndependentBallisticConfiguration: Codable, Sendable {
    public let gravity: Double, contactCenterHeight: Double, residualBoundPixels: Double
    public let maximumGaussNewtonIterations: Int
    public let maximumScaledJacobianCondition: Double
    public init(gravity: Double = 9.81, contactCenterHeight: Double = 0.033, residualBoundPixels: Double, maximumGaussNewtonIterations: Int = 10, maximumScaledJacobianCondition: Double = 1e6) throws {
        self.gravity = gravity; self.contactCenterHeight = contactCenterHeight; self.residualBoundPixels = residualBoundPixels
        self.maximumGaussNewtonIterations = maximumGaussNewtonIterations; self.maximumScaledJacobianCondition = maximumScaledJacobianCondition
        try validate()
    }
    func validate() throws {
        try independentRequire(gravity.isFinite && gravity > 0 && contactCenterHeight.isFinite && contactCenterHeight >= 0 && residualBoundPixels.isFinite && residualBoundPixels > 0, "Invalid physical assumptions or radial engineering residual bound")
        try independentRequire((1...10).contains(maximumGaussNewtonIterations) && maximumScaledJacobianCondition.isFinite && maximumScaledJacobianCondition >= 1 && maximumScaledJacobianCondition <= 1e6, "Invalid diagnostic iteration or condition bound")
    }
    private enum CodingKeys: String, CodingKey { case gravity, contactCenterHeight, residualBoundPixels, maximumGaussNewtonIterations, maximumScaledJacobianCondition }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(gravity: c.decode(Double.self, forKey: .gravity), contactCenterHeight: c.decode(Double.self, forKey: .contactCenterHeight), residualBoundPixels: c.decode(Double.self, forKey: .residualBoundPixels), maximumGaussNewtonIterations: c.decode(Int.self, forKey: .maximumGaussNewtonIterations), maximumScaledJacobianCondition: c.decode(Double.self, forKey: .maximumScaledJacobianCondition))
    }
}
public struct IndependentBallisticInput: Codable, Sendable {
    public let camera: IndependentBallisticCamera
    public let frames: [IndependentBallisticFrame]
    public let contactTime: IndependentBallFrameTime
    public let configuration: IndependentBallisticConfiguration
    public init(camera: IndependentBallisticCamera, frames: [IndependentBallisticFrame], contactTime: IndependentBallFrameTime, configuration: IndependentBallisticConfiguration) throws {
        self.camera = camera; self.frames = frames; self.contactTime = contactTime; self.configuration = configuration
        try validate()
    }
    public func validate() throws {
        try camera.validate(); try configuration.validate()
        try independentRequire((3...4096).contains(frames.count), "Diagnostic requires 3...4096 source frames")
        let contact = try contactTime.mediaTime()
        var previous: CMTime?, previousIndex = -1
        for frame in frames {
            try independentRequire(frame.sourceID == camera.sourceID && frame.frameIndex >= 0 && frame.frameIndex > previousIndex, "Foreign source or duplicate/unordered frame")
            let time = try frame.time.mediaTime()
            try independentRequire(CMTimeCompare(time, contact) < 0, "Contact must follow all source frames")
            if let previous { try independentRequire(CMTimeCompare(previous, time) < 0, "Duplicate or unordered exact rational timestamps") }
            _ = try Self.seconds(time, minus: contact)
            if let p = frame.originalPixel {
                try independentRequire(p.x.isFinite && p.y.isFinite && p.x >= 0 && p.y >= 0 && p.x < Double(camera.width) && p.y < Double(camera.height) && frame.missingReason == nil, "Invalid original pixel or contradictory missing reason")
            } else {
                try independentRequire(frame.missingReason.map { !$0.isEmpty && $0.utf8.count <= 4096 } == true, "Missing observations require a reason; no interpolation")
            }
            previous = time; previousIndex = frame.frameIndex
        }
        try independentRequire(frames.filter { $0.originalPixel != nil }.count >= 3, "Insufficient original observations")
    }
    static func seconds(_ time: CMTime, minus origin: CMTime) throws -> Double {
        let difference = CMTimeSubtract(time, origin)
        try independentRequire(difference.isNumeric && !difference.flags.contains(.hasBeenRounded) && difference.seconds.isFinite, "Inexact or overflowing rational timestamp subtraction")
        return difference.seconds
    }
    private enum CodingKeys: String, CodingKey { case camera, frames, contactTime, configuration }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(camera: c.decode(IndependentBallisticCamera.self, forKey: .camera), frames: c.decode([IndependentBallisticFrame].self, forKey: .frames), contactTime: c.decode(IndependentBallFrameTime.self, forKey: .contactTime), configuration: c.decode(IndependentBallisticConfiguration.self, forKey: .configuration))
    }
}

public struct IndependentBallisticIteration: Codable, Sendable {
    public let weightedSSEBefore: Double, weightedSSEAfter: Double, scaledStepNorm: Double, scaledJacobianCondition: Double
}
public struct IndependentBallisticRawMotion: Codable, Sendable {
    /// [xb,yb,vx,vy,vzb], with dt = t - contactTime and Z = r + vzb*dt - g*dt²/2.
    public let contactParameters: [Double]
    public let positionFirstObservedMeters: [Double]
    public let velocityFirstObservedMetersPerSecond: [Double]
    public let velocityFirstObservedNormMetersPerSecond: Double
    /// Python parity coordinates [x0,y0,vx*T,vy*T,vz0*T], T = contact - first observation.
    public let scaledFirstObservationParameters: [Double]
}
public struct IndependentBallisticResult: Codable, Sendable {
    public let status: String
    public let rawMotion: IndependentBallisticRawMotion?
    public let observedFrameIndices: [Int], missingFrameIndices: [Int]
    public let reprojectionPixels: [IndependentBallisticPixel], residualsPixels: [Double]
    public let reprojectionRMSPixels: Double?, reprojectionMaximumPixels: Double?
    public let minimumDepthMeters: Double?, minimumHeightMeters: Double?, scaledJacobianCondition: Double?
    public let allResidualsWithinBound: Bool, aboveGroundAllObservations: Bool
    public let iterations: [IndependentBallisticIteration]
    public let qualificationReasons: [String]
    // Immutable computed outputs cannot be promoted by decoded flags. Optional values
    // are explicitly encoded as null so consumers cannot mistake absence for zero.
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    public var speedKilometersPerHour: Double? { nil }
    public var physicalAccuracyValidated: Bool { false }
    public var cameraQualified: Bool { false }
    public var human: Bool { false }
    public var formal: Bool { false }
    public var production: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case status, rawMotion, observedFrameIndices, missingFrameIndices, reprojectionPixels, residualsPixels, reprojectionRMSPixels, reprojectionMaximumPixels, minimumDepthMeters, minimumHeightMeters, scaledJacobianCondition, allResidualsWithinBound, aboveGroundAllObservations, iterations, qualificationReasons
        case acceptedCamera, velocity, speedKilometersPerHour, physicalAccuracyValidated, cameraQualified, human, formal, production, nativeEndToEndSpeedAccepted, twentyPercentAcceptanceEligible
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(rawMotion, forKey: .rawMotion)
        try c.encode(observedFrameIndices, forKey: .observedFrameIndices); try c.encode(missingFrameIndices, forKey: .missingFrameIndices)
        try c.encode(reprojectionPixels, forKey: .reprojectionPixels); try c.encode(residualsPixels, forKey: .residualsPixels)
        try c.encode(reprojectionRMSPixels, forKey: .reprojectionRMSPixels); try c.encode(reprojectionMaximumPixels, forKey: .reprojectionMaximumPixels)
        try c.encode(minimumDepthMeters, forKey: .minimumDepthMeters); try c.encode(minimumHeightMeters, forKey: .minimumHeightMeters); try c.encode(scaledJacobianCondition, forKey: .scaledJacobianCondition)
        try c.encode(allResidualsWithinBound, forKey: .allResidualsWithinBound); try c.encode(aboveGroundAllObservations, forKey: .aboveGroundAllObservations)
        try c.encode(iterations, forKey: .iterations); try c.encode(qualificationReasons, forKey: .qualificationReasons)
        for key in [CodingKeys.acceptedCamera, .velocity, .speedKilometersPerHour] { try c.encodeNil(forKey: key) }
        for key in [CodingKeys.physicalAccuracyValidated, .cameraQualified, .human, .formal, .production, .nativeEndToEndSpeedAccepted, .twentyPercentAcceptanceEligible] { try c.encode(false, forKey: key) }
    }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status); rawMotion = try c.decodeIfPresent(IndependentBallisticRawMotion.self, forKey: .rawMotion)
        observedFrameIndices = try c.decode([Int].self, forKey: .observedFrameIndices); missingFrameIndices = try c.decode([Int].self, forKey: .missingFrameIndices)
        reprojectionPixels = try c.decode([IndependentBallisticPixel].self, forKey: .reprojectionPixels); residualsPixels = try c.decode([Double].self, forKey: .residualsPixels)
        reprojectionRMSPixels = try c.decodeIfPresent(Double.self, forKey: .reprojectionRMSPixels); reprojectionMaximumPixels = try c.decodeIfPresent(Double.self, forKey: .reprojectionMaximumPixels)
        minimumDepthMeters = try c.decodeIfPresent(Double.self, forKey: .minimumDepthMeters); minimumHeightMeters = try c.decodeIfPresent(Double.self, forKey: .minimumHeightMeters); scaledJacobianCondition = try c.decodeIfPresent(Double.self, forKey: .scaledJacobianCondition)
        allResidualsWithinBound = try c.decode(Bool.self, forKey: .allResidualsWithinBound); aboveGroundAllObservations = try c.decode(Bool.self, forKey: .aboveGroundAllObservations)
        iterations = try c.decode([IndependentBallisticIteration].self, forKey: .iterations); qualificationReasons = try c.decode([String].self, forKey: .qualificationReasons)
    }
    init(status: String, rawMotion: IndependentBallisticRawMotion?, observedFrameIndices: [Int], missingFrameIndices: [Int], reprojectionPixels: [IndependentBallisticPixel], residualsPixels: [Double], reprojectionRMSPixels: Double?, reprojectionMaximumPixels: Double?, minimumDepthMeters: Double?, minimumHeightMeters: Double?, scaledJacobianCondition: Double?, allResidualsWithinBound: Bool, aboveGroundAllObservations: Bool, iterations: [IndependentBallisticIteration], qualificationReasons: [String]) {
        self.status = status; self.rawMotion = rawMotion; self.observedFrameIndices = observedFrameIndices; self.missingFrameIndices = missingFrameIndices; self.reprojectionPixels = reprojectionPixels; self.residualsPixels = residualsPixels; self.reprojectionRMSPixels = reprojectionRMSPixels; self.reprojectionMaximumPixels = reprojectionMaximumPixels; self.minimumDepthMeters = minimumDepthMeters; self.minimumHeightMeters = minimumHeightMeters; self.scaledJacobianCondition = scaledJacobianCondition; self.allResidualsWithinBound = allResidualsWithinBound; self.aboveGroundAllObservations = aboveGroundAllObservations; self.iterations = iterations; self.qualificationReasons = qualificationReasons
    }
}

/// One fixed-camera, five-parameter diagnostic; no camera fitting, model inference,
/// loss search, interpolation, or qualification of physical speed.
public enum IndependentBallisticDiagnostic {
    struct Key: CodingKey { var stringValue: String; var intValue: Int? { nil }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    static func rejectQualifiedClaims(_ decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for name in ["qualified", "accepted", "cameraMeasured", "camera_measured", "human_annotation", "formal_review", "physicalAccuracyValidated", "cameraQualified", "human", "formal", "production", "nativeEndToEndSpeedAccepted", "twentyPercentAcceptanceEligible", "physical_accuracy_validated", "camera_qualified", "native_end_to_end_speed_accepted", "twenty_percent_acceptance_eligible", "speed_model_accepted"] {
            let key = Key(stringValue: name)!
            if c.contains(key) { try independentRequire(try c.decode(Bool.self, forKey: key) == false, "Diagnostic input cannot assert qualification: \(name)") }
        }
        for name in ["acceptedCamera", "accepted_camera", "accepted_K", "accepted_velocity", "accepted_speed_kmh", "velocity", "speedKilometersPerHour", "speed_kmh"] {
            let key = Key(stringValue: name)!
            if c.contains(key) { try independentRequire(try c.decodeNil(forKey: key), "Diagnostic input cannot supply public accepted values: \(name)") }
        }
    }
    static func norm(_ x: [Double]) -> Double { x.reduce(0) { hypot($0, $1) } }
    static func mul(_ a: [Double], _ x: [Double]) -> [Double] { (0..<3).map { row in (0..<3).reduce(0.0) { $0+a[row*3+$1]*x[$1] } } }
    /// Householder QR with column pivoting. Gram matrices are never used to solve.
    static func solve(_ matrix: [[Double]], _ target: [Double]) throws -> [Double] {
        let m = matrix.count, n = 5
        var a = matrix, b = target, permutation = Array(0..<n)
        try independentRequire(m >= n && b.count == m && a.allSatisfy { $0.count == n && $0.allSatisfy(\.isFinite) } && b.allSatisfy(\.isFinite), "Nonfinite least squares system")
        var scale = 0.0
        for k in 0..<n {
            var pivot = k, largest = -1.0
            for j in k..<n { let length = norm((k..<m).map { a[$0][j] }); if length > largest { largest = length; pivot = j } }
            if pivot != k { for i in 0..<m { a[i].swapAt(k, pivot) }; permutation.swapAt(k, pivot) }
            let length = norm((k..<m).map { a[$0][k] }); scale = max(scale, length)
            try independentRequire(length > max(1e-14, scale*1e-10), "Rank deficient motion system")
            var v = (k..<m).map { a[$0][k] }; v[0] += (v[0] >= 0 ? length : -length)
            let vn = norm(v); v = v.map { $0/vn }
            for j in k..<n {
                let dot = (k..<m).reduce(0.0) { $0 + v[$1-k]*a[$1][j] }
                for i in k..<m { a[i][j] -= 2*v[i-k]*dot }
            }
            let dot = (k..<m).reduce(0.0) { $0 + v[$1-k]*b[$1] }
            for i in k..<m { b[i] -= 2*v[i-k]*dot }
        }
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            x[i] = (b[i] - ((i+1)..<n).reduce(0.0) { $0+a[i][$1]*x[$1] })/a[i][i]
        }
        var out = x
        for i in 0..<n { out[permutation[i]] = x[i] }
        try independentRequire(out.allSatisfy(\.isFinite), "Nonfinite least squares solution")
        return out
    }
    /// Jacobi eigenvalues of the column-scaled Gram matrix, for condition diagnostics only.
    static func condition(_ j: [[Double]]) throws -> Double {
        let n = 5, norms = (0..<5).map { col in norm(j.map { $0[col] }) }
        try independentRequire(norms.allSatisfy { $0 > 1e-12 && $0.isFinite }, "Zero Jacobian column")
        var a = (0..<n).map { i in (0..<n).map { k in j.reduce(0.0) { $0 + ($1[i]/norms[i])*($1[k]/norms[k]) } } }
        for _ in 0..<200 {
            var p = 0, q = 1
            for i in 0..<n { for k in (i+1)..<n { if abs(a[i][k]) > abs(a[p][q]) { p = i; q = k } } }
            if abs(a[p][q]) < 1e-15 { break }
            let angle = 0.5*atan2(2*a[p][q], a[q][q]-a[p][p]), c = cos(angle), s = sin(angle)
            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            for k in 0..<n where k != p && k != q {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c*akp-s*akq; a[p][k] = a[k][p]; a[k][q] = s*akp+c*akq; a[q][k] = a[k][q]
            }
            a[p][p] = c*c*app-2*s*c*apq+s*s*aqq; a[q][q] = s*s*app+2*s*c*apq+c*c*aqq; a[p][q] = 0; a[q][p] = 0
        }
        let values = (0..<n).map { a[$0][$0] }
        try independentRequire(values.allSatisfy(\.isFinite) && values.min()! > 0, "Rank deficient scaled Jacobian")
        return sqrt(values.max()!/values.min()!)
    }
    public static func fit(_ input: IndependentBallisticInput) throws -> IndependentBallisticResult {
        try input.validate()
        let observed = input.frames.filter { $0.originalPixel != nil }, missing = input.frames.filter { $0.originalPixel == nil }.map(\.frameIndex)
        let reasons = ["Fixed camera and lens priors are assumptions, not measured calibration.", "Contact time, gravity and ball radius are assumptions; collision freedom, drag and spin are unverified.", "No independent physical speed truth, human review, formal acceptance or production qualification."] + input.camera.assumptions
        var iterations: [IndependentBallisticIteration] = []
        func rejected(_ reason: String) -> IndependentBallisticResult {
            .init(status: "rejected", rawMotion: nil, observedFrameIndices: observed.map(\.frameIndex), missingFrameIndices: missing, reprojectionPixels: [], residualsPixels: [], reprojectionRMSPixels: nil, reprojectionMaximumPixels: nil, minimumDepthMeters: nil, minimumHeightMeters: nil, scaledJacobianCondition: nil, allResidualsWithinBound: false, aboveGroundAllObservations: false, iterations: iterations, qualificationReasons: reasons+[reason])
        }
        do {
            let first = try observed[0].time.mediaTime(), contact = try input.contactTime.mediaTime()
            let T = try IndependentBallisticInput.seconds(contact, minus: first)
            try independentRequire(T > 0, "Nonpositive flight span")
            let times = try observed.map { try IndependentBallisticInput.seconds($0.time.mediaTime(), minus: first) }
            let g = input.configuration.gravity, r = input.configuration.contactCenterHeight, bound = input.configuration.residualBoundPixels
            let K = input.camera.rowMajorK, R = input.camera.rowMajorR, t = input.camera.t
            // Match the frozen Python scaling and stopping norm. Equivalent to the
            // public contact-centered parameters; camera remains constant throughout.
            let Bs = times.map { tm in [[1.0,0,tm/T,0,0], [0,1,0,tm/T,0], [0,0,0,0,(tm-T)/T]] }
            let bs = times.map { [0.0,0,r+0.5*g*(T*T-$0*$0)] }
            var A: [[Double]] = [], target: [Double] = []
            for i in observed.indices {
                let p = observed[i].originalPixel!, ry = (p.y-K[5])/K[4], rx = (p.x-K[2]-K[1]*ry)/K[0]
                let rayNorm = norm([rx,ry,1]), ray = [rx,ry,1].map { $0/rayNorm }
                let rb = zip(mul(R, bs[i]),t).map(+)
                let RB = (0..<3).map { row in (0..<5).map { col in (0..<3).reduce(0.0) { $0+R[row*3+$1]*Bs[i][$1][col] } } }
                for row in 0..<3 {
                    // (I - ray ray^T) row, spelled out so older compilers type-check it in time
                    var P = [Double](repeating: 0, count: 3)
                    for m in 0..<3 { P[m] = (row == m ? 1.0 : 0.0) - ray[row] * ray[m] }
                    var a = [Double](repeating: 0, count: 5)
                    for col in 0..<5 { for m in 0..<3 { a[col] += P[m] * RB[m][col] / bound } }
                    A.append(a)
                    var b = 0.0
                    for m in 0..<3 { b += P[m] * rb[m] / bound }
                    target.append(-b)
                }
            }
            var theta = try solve(A,target)
            func evaluate(_ par: [Double]) throws -> (res: [Double], J: [[Double]], pixels: [IndependentBallisticPixel], heights: [Double], depths: [Double]) {
                var residual: [Double] = [], jacobian: [[Double]] = [], pixels: [IndependentBallisticPixel] = [], heights: [Double] = [], depths: [Double] = []
                for i in observed.indices {
                    let xyz = (0..<3).map { row in zip(Bs[i][row],par).reduce(bs[i][row]) { $0+$1.0*$1.1 } }
                    let xc = zip(mul(R,xyz),t).map(+)
                    try independentRequire(xc.allSatisfy(\.isFinite) && xc[2] > 0.1, "Nonpositive or near motion depth")
                    let h = mul(K,xc), px = h[0]/h[2], py = h[1]/h[2]
                    let obs = observed[i].originalPixel!
                    residual += [(px-obs.x)/bound,(py-obs.y)/bound]
                    pixels.append(.init(x:px,y:py)); heights.append(xyz[2]); depths.append(xc[2])
                    for row in 0..<2 {
                        var D = [Double](repeating: 0, count: 3)
                        for m in 0..<3 {
                            let direct: Double = K[row * 3 + m] / h[2]
                            let perspective: Double = h[row] * K[6 + m] / (h[2] * h[2])
                            D[m] = (direct - perspective) / bound
                        }
                        var DR = [Double](repeating: 0, count: 3)
                        for col in 0..<3 { for m in 0..<3 { DR[col] += D[m] * R[m * 3 + col] } }
                        var J = [Double](repeating: 0, count: 5)
                        for col in 0..<5 { for m in 0..<3 { J[col] += DR[m] * Bs[i][m][col] } }
                        jacobian.append(J)
                    }
                }
                try independentRequire(residual.allSatisfy(\.isFinite), "Nonfinite reprojection")
                return (residual,jacobian,pixels,heights,depths)
            }
            for _ in 0..<input.configuration.maximumGaussNewtonIterations {
                let e = try evaluate(theta), cond = try condition(e.J)
                try independentRequire(cond <= input.configuration.maximumScaledJacobianCondition, "Motion Jacobian condition exceeds bound")
                let step = try solve(e.J,e.res.map(-)), trial = zip(theta,step).map(+), next = try evaluate(trial)
                let before = e.res.reduce(0) { $0+$1*$1 }, after = next.res.reduce(0) { $0+$1*$1 }, length = norm(step)
                try independentRequire(before.isFinite && after.isFinite && length.isFinite && cond.isFinite, "Nonfinite Gauss-Newton objective, step or condition")
                iterations.append(.init(weightedSSEBefore:before,weightedSSEAfter:after,scaledStepNorm:length,scaledJacobianCondition:cond))
                try independentRequire(after <= before+1e-9*max(1,before), "Gauss-Newton objective increased; no retry")
                theta = trial
                if length < 1e-10 { break }
            }
            let e = try evaluate(theta), cond = try condition(e.J)
            try independentRequire(cond <= input.configuration.maximumScaledJacobianCondition, "Final Jacobian condition exceeds bound")
            let errors = observed.indices.map { hypot(e.pixels[$0].x-observed[$0].originalPixel!.x,e.pixels[$0].y-observed[$0].originalPixel!.y) }
            let v = [theta[2]/T,theta[3]/T,theta[4]/T], p0 = [theta[0],theta[1],r-v[2]*T+0.5*g*T*T]
            let contactParameters = [p0[0]+v[0]*T,p0[1]+v[1]*T,v[0],v[1],v[2]-g*T]
            let reconstructedContactHeight = p0[2]+v[2]*T-0.5*g*T*T
            let velocityNorm = norm(v), rms = norm(errors)/sqrt(Double(errors.count))
            try independentRequire((v+p0+contactParameters+theta+errors).allSatisfy(\.isFinite) && velocityNorm.isFinite && rms.isFinite && reconstructedContactHeight.isFinite && abs(reconstructedContactHeight-r) < 1e-8, "Nonfinite derived motion or violated contact constraint")
            let raw = IndependentBallisticRawMotion(contactParameters:contactParameters,positionFirstObservedMeters:p0,velocityFirstObservedMetersPerSecond:v,velocityFirstObservedNormMetersPerSecond:velocityNorm,scaledFirstObservationParameters:theta)
            let above = e.heights.min()! >= r-1e-6, within = errors.allSatisfy { $0 <= bound }
            return .init(status: above && within ? "unqualified_fixed_camera_motion_diagnostic" : "fixed_camera_motion_quality_rejected", rawMotion:raw, observedFrameIndices:observed.map(\.frameIndex), missingFrameIndices:missing, reprojectionPixels:e.pixels,residualsPixels:errors,reprojectionRMSPixels:rms,reprojectionMaximumPixels:errors.max(),minimumDepthMeters:e.depths.min(),minimumHeightMeters:e.heights.min(),scaledJacobianCondition:cond,allResidualsWithinBound:within,aboveGroundAllObservations:above,iterations:iterations,qualificationReasons:reasons + (above ? [] : ["Observed center below assumed ground contact height"]) + (within ? [] : ["Radial residual exceeds frozen engineering bound"]))
        } catch { return rejected(error.localizedDescription) }
    }
}
