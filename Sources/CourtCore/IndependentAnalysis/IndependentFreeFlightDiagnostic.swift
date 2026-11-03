import Foundation
import CoreMedia

/// Fixed assumed camera and original source observations. No contact timestamp is
/// accepted: all six trajectory parameters are estimated before deriving a root.
public struct IndependentFreeFlightInput: Codable, Sendable {
    public let camera: IndependentBallisticCamera
    public let frames: [IndependentBallisticFrame]
    public let configuration: IndependentBallisticConfiguration
    public init(camera: IndependentBallisticCamera, frames: [IndependentBallisticFrame], configuration: IndependentBallisticConfiguration) throws {
        self.camera = camera; self.frames = frames; self.configuration = configuration
        try validate()
    }
    public func validate() throws {
        try camera.validate(); try configuration.validate()
        try IndependentFreeFlightDiagnostic.require((32...4096).contains(frames.count), "Free flight requires 32...4096 original source entries")
        var previous: CMTime?, previousIndex = -1
        for f in frames {
            try IndependentFreeFlightDiagnostic.require(f.sourceID == camera.sourceID && f.frameIndex > previousIndex, "Foreign or unordered source frame")
            let time = try f.time.mediaTime()
            if let previous { try IndependentFreeFlightDiagnostic.require(CMTimeCompare(time, previous) > 0, "Duplicate or unordered exact source PTS") }
            if let p = f.originalPixel {
                try IndependentFreeFlightDiagnostic.require(p.x.isFinite && p.y.isFinite && p.x >= 0 && p.x < Double(camera.width) && p.y >= 0 && p.y < Double(camera.height) && f.missingReason == nil, "Invalid original pixel")
            } else {
                try IndependentFreeFlightDiagnostic.require(f.missingReason.map { !$0.isEmpty && $0.utf8.count <= 4096 } == true, "Missing source point requires reason; no interpolation")
            }
            previous = time; previousIndex = f.frameIndex
        }
        try IndependentFreeFlightDiagnostic.require(frames.filter { $0.originalPixel != nil }.count >= 32, "Free flight requires at least 32 actual observations")
    }
    private enum CodingKeys: String, CodingKey { case camera, frames, configuration }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let any = try decoder.container(keyedBy: IndependentBallisticDiagnostic.Key.self)
        for name in ["contactTime", "groundTime", "teacher_speed_kmh", "teacherXYZ"] {
            try IndependentFreeFlightDiagnostic.require(!any.contains(.init(stringValue: name)!), "Free-flight input cannot supply \(name)")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(camera: c.decode(IndependentBallisticCamera.self, forKey: .camera), frames: c.decode([IndependentBallisticFrame].self, forKey: .frames), configuration: c.decode(IndependentBallisticConfiguration.self, forKey: .configuration))
    }
}

public struct IndependentFreeFlightSystem: Encodable, Sendable {
    public let rank: Int
    public let columnScaledCondition: Double?
    public let singularValues: [Double]
    public let columnNorms: [Double]
}
public struct IndependentFreeFlightRawMotion: Encodable, Sendable {
    public let positionFirstObservedMeters: [Double]
    public let velocityFirstObservedMetersPerSecond: [Double]
    public let velocityFirstObservedNormMetersPerSecond: Double
    /// [x0,y0,z0,vx*T,vy*T,vz*T], T=last actual observation-first actual observation.
    public let scaledFirstObservationParameters: [Double]
}
public struct IndependentFreeFlightGroundRoot: Encodable, Sendable {
    /// Estimated floating-point duration, NOT an exact source PTS or an observed event.
    public let secondsAfterFirstObserved: Double
    public let extrapolationSecondsBeyondLastObserved: Double
    public let positionMeters: [Double]
    public let verticalVelocityMetersPerSecond: Double
    public let cameraDepthMeters: Double
}
public struct IndependentFreeFlightResult: Encodable, Sendable {
    public var status = "rejected"
    public var rawMotion: IndependentFreeFlightRawMotion?
    public var futureDownwardGroundRoot: IndependentFreeFlightGroundRoot?
    public var allGroundRootsSecondsAfterFirstObserved: [Double] = []
    public let firstObservedTime: IndependentBallFrameTime
    public let observedFrameIndices: [Int], missingFrameIndices: [Int]
    public var observationSpanSeconds: Double?
    public var initialSystem: IndependentFreeFlightSystem?, finalSystem: IndependentFreeFlightSystem?
    public var converged = false, rawAlgebraicQualityPassed = false
    public var allResidualsWithinBound = false, aboveGroundAllObservations = false
    public var reprojectionPixels: [IndependentBallisticPixel] = [], residualsPixels: [Double] = []
    public var reprojectionRMSPixels: Double?, reprojectionMaximumPixels: Double?
    public var minimumDepthMeters: Double?, minimumHeightMeters: Double?
    public var iterations: [IndependentBallisticIteration] = []
    public var qualityReasons: [String] = []
    public let assumptions: [String]
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    public var speedKilometersPerHour: Double? { nil }
    public var formal: Bool { false }
    public var human: Bool { false }
    public var production: Bool { false }
    public var cameraQualified: Bool { false }
    public var physicalAccuracyValidated: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case status, rawMotion, futureDownwardGroundRoot, allGroundRootsSecondsAfterFirstObserved, firstObservedTime, observedFrameIndices, missingFrameIndices, observationSpanSeconds, initialSystem, finalSystem, converged, rawAlgebraicQualityPassed, allResidualsWithinBound, aboveGroundAllObservations, reprojectionPixels, residualsPixels, reprojectionRMSPixels, reprojectionMaximumPixels, minimumDepthMeters, minimumHeightMeters, iterations, qualityReasons, assumptions
        case acceptedCamera, velocity, speedKilometersPerHour, formal, human, production, cameraQualified, physicalAccuracyValidated, nativeEndToEndSpeedAccepted, twentyPercentAcceptanceEligible
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(rawMotion, forKey: .rawMotion); try c.encode(futureDownwardGroundRoot, forKey: .futureDownwardGroundRoot)
        try c.encode(allGroundRootsSecondsAfterFirstObserved, forKey: .allGroundRootsSecondsAfterFirstObserved); try c.encode(firstObservedTime, forKey: .firstObservedTime)
        try c.encode(observedFrameIndices, forKey: .observedFrameIndices); try c.encode(missingFrameIndices, forKey: .missingFrameIndices); try c.encode(observationSpanSeconds, forKey: .observationSpanSeconds)
        try c.encode(initialSystem, forKey: .initialSystem); try c.encode(finalSystem, forKey: .finalSystem); try c.encode(converged, forKey: .converged); try c.encode(rawAlgebraicQualityPassed, forKey: .rawAlgebraicQualityPassed)
        try c.encode(allResidualsWithinBound, forKey: .allResidualsWithinBound); try c.encode(aboveGroundAllObservations, forKey: .aboveGroundAllObservations)
        try c.encode(reprojectionPixels, forKey: .reprojectionPixels); try c.encode(residualsPixels, forKey: .residualsPixels); try c.encode(reprojectionRMSPixels, forKey: .reprojectionRMSPixels); try c.encode(reprojectionMaximumPixels, forKey: .reprojectionMaximumPixels)
        try c.encode(minimumDepthMeters, forKey: .minimumDepthMeters); try c.encode(minimumHeightMeters, forKey: .minimumHeightMeters); try c.encode(iterations, forKey: .iterations); try c.encode(qualityReasons, forKey: .qualityReasons); try c.encode(assumptions, forKey: .assumptions)
        for k in [CodingKeys.acceptedCamera, .velocity, .speedKilometersPerHour] { try c.encodeNil(forKey: k) }
        for k in [CodingKeys.formal, .human, .production, .cameraQualified, .physicalAccuracyValidated, .nativeEndToEndSpeedAccepted, .twentyPercentAcceptanceEligible] { try c.encode(false, forKey: k) }
    }
}

public enum IndependentFreeFlightDiagnostic {
    static func require(_ value: Bool, _ reason: String) throws { if !value { throw IndependentBallisticError.invalid(reason) } }
    private static func norm(_ x: [Double]) -> Double { IndependentBallisticDiagnostic.norm(x) }
    private static func mul(_ a: [Double], _ x: [Double]) -> [Double] { IndependentBallisticDiagnostic.mul(a,x) }
    /// One-sided Jacobi SVD for diagnostics. It avoids squaring the condition
    /// number and preserves the short-span sixth singular direction near zero.
    private static func inspect(_ matrix: [[Double]]) throws -> (IndependentFreeFlightSystem, [[Double]], Bool) {
        try require(matrix.count >= 6 && matrix.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isFinite) }, "Invalid six-column system")
        let norms = (0..<6).map { k in norm(matrix.map { $0[k] }) }
        try require(norms.allSatisfy(\.isFinite), "Nonfinite system column norms")
        let zero = norms.contains { $0 <= 1e-12 }
        let normalized = matrix.map { row in (0..<6).map { row[$0]/(norms[$0] > 1e-12 ? norms[$0] : 1) } }
        var columns = (0..<6).map { j in normalized.map { $0[j] } }
        var done = false
        for _ in 0..<100 {
            var changed = false
            for a in 0..<5 { for b in (a+1)..<6 {
                let aa = columns[a].reduce(0) { $0+$1*$1 }, bb = columns[b].reduce(0) { $0+$1*$1 }
                let ab = zip(columns[a],columns[b]).reduce(0.0) { $0+$1.0*$1.1 }
                if aa == 0 || bb == 0 || abs(ab) <= 1e-14*sqrt(aa)*sqrt(bb) { continue }
                let angle = 0.5*atan2(2*ab,bb-aa), c = cos(angle), s = sin(angle)
                for row in columns[a].indices {
                    let x = columns[a][row], y = columns[b][row]
                    columns[a][row] = c*x-s*y; columns[b][row] = s*x+c*y
                }
                changed = true
            } }
            if !changed { done = true; break }
        }
        try require(done, "Singular-value diagnostic did not converge")
        let sv = columns.map(norm).sorted(by: >), rank = sv.filter { $0 > sv[0]*1e-10 }.count
        let ratio = sv[5] > 0 ? sv[0]/sv[5] : Double.infinity
        return (.init(rank:rank,columnScaledCondition:zero || !ratio.isFinite ? nil : ratio,singularValues:sv,columnNorms:norms),normalized,zero)
    }
    /// Six-column Householder QR; rank and condition were already inspected.
    /// No normal-equation solve or parameter-dependent alternative initialization.
    private static func qr(_ matrix: [[Double]], _ target: [Double]) throws -> [Double] {
        var a = matrix, b = target
        let m = a.count
        try require(b.count == m && b.allSatisfy(\.isFinite), "Nonfinite QR target")
        for k in 0..<6 {
            let length = norm((k..<m).map { a[$0][k] })
            try require(length > 0 && length.isFinite, "Singular QR system")
            var v = (k..<m).map { a[$0][k] }; v[0] += v[0] >= 0 ? length : -length
            let vn = norm(v); try require(vn > 0 && vn.isFinite, "Nonfinite QR reflector"); v = v.map { $0/vn }
            for j in k..<6 {
                let dot = (k..<m).reduce(0.0) { $0+v[$1-k]*a[$1][j] }
                for i in k..<m { a[i][j] -= 2*v[i-k]*dot }
            }
            let dot = (k..<m).reduce(0.0) { $0+v[$1-k]*b[$1] }
            for i in k..<m { b[i] -= 2*v[i-k]*dot }
        }
        var x = Array(repeating:0.0,count:6)
        for i in stride(from:5,through:0,by:-1) {
            x[i] = (b[i]-((i+1)..<6).reduce(0.0) { $0+a[i][$1]*x[$1] })/a[i][i]
        }
        try require(x.allSatisfy(\.isFinite), "Nonfinite QR solution"); return x
    }
    private static func solve(_ a: [[Double]], _ b: [Double], limit: Double) throws -> (solution: [Double]?, system: IndependentFreeFlightSystem) {
        let (system,scaled,zero) = try inspect(a)
        guard !zero, system.rank == 6, let condition = system.columnScaledCondition, condition <= limit else { return (nil,system) }
        let x = try qr(scaled,b); let result = zip(x,system.columnNorms).map { $0/$1 }
        try require(result.allSatisfy(\.isFinite), "Nonfinite unscaled QR result"); return (result,system)
    }
    public static func fit(_ input: IndependentFreeFlightInput) throws -> IndependentFreeFlightResult {
        try input.validate()
        let observed = input.frames.filter { $0.originalPixel != nil }, c = input.camera, config = input.configuration
        var result = IndependentFreeFlightResult(firstObservedTime:observed[0].time,observedFrameIndices:observed.map(\.frameIndex),missingFrameIndices:input.frames.filter { $0.originalPixel == nil }.map(\.frameIndex),assumptions:c.assumptions+[
            "Six parameters use only fixed assumed K/R/t, source PTS, pixels and constant gravity; no contact-time input.",
            "Ground radius enters only a post-fit root. Root seconds are floating estimates, not exact source PTS or measured contact.",
            "Engineering pixel bounds are not statistical sigma. Camera, court scale, distortion, collision freedom, drag and spin are unverified.",
            "Previously developed/exposed sources do not constitute blind physical accuracy validation."
        ])
        do {
            let first = try observed[0].time.mediaTime()
            let times = try observed.map { try IndependentBallisticInput.seconds($0.time.mediaTime(),minus:first) }
            let T = times.last!; try require(T > 0 && T.isFinite, "Invalid observation span"); result.observationSpanSeconds = T
            let pixels = observed.map { $0.originalPixel! }, k = c.rowMajorK, r = c.rowMajorR, g = config.gravity, bound = config.residualBoundPixels
            let bases = times.map { time in (0..<3).map { row in (0..<6).map { col in col == row ? 1.0 : (col == row+3 ? time/T : 0.0) } } }
            let offsets = times.map { [0.0,0,-0.5*g*$0*$0] }
            var A: [[Double]] = [], target: [Double] = []
            for i in times.indices {
                let yn = (pixels[i].y-k[5])/k[4], xn = (pixels[i].x-k[2]-k[1]*yn)/k[0]
                var ray = [xn,yn,1.0]; let length = norm(ray); try require(length.isFinite && length > 0, "Invalid camera bearing"); ray = ray.map { $0/length }
                let M = (0..<3).map { row in (0..<3).map { col in (row == col ? 1.0 : 0.0)-ray[row]*ray[col] } }
                let offset = zip(mul(r,offsets[i]),c.t).map(+)
                for row in 0..<3 {
                    let mr = (0..<3).map { col in (0..<3).reduce(0.0) { $0+M[row][$1]*r[$1*3+col] } }
                    A.append((0..<6).map { col in (0..<3).reduce(0.0) { $0+mr[$1]*bases[i][$1][col] }/bound })
                    target.append(-zip(M[row],offset).reduce(0.0) { $0+$1.0*$1.1 }/bound)
                }
            }
            let initial = try solve(A,target,limit:config.maximumScaledJacobianCondition); result.initialSystem = initial.system
            guard var theta = initial.solution else { result.qualityReasons.append("Linear initialization rank or condition rejected"); return result }
            func evaluate(_ th: [Double]) throws -> (residual:[Double],jacobian:[[Double]],world:[[Double]],depth:[Double],pixel:[IndependentBallisticPixel]) {
                var residual:[Double] = [], J:[[Double]] = [], world:[[Double]] = [], depth:[Double] = [], predicted:[IndependentBallisticPixel] = []
                for i in times.indices {
                    let x = (0..<3).map { row in zip(bases[i][row],th).reduce(offsets[i][row]) { $0+$1.0*$1.1 } }
                    let cc = zip(mul(r,x),c.t).map(+), h = mul(k,cc)
                    try require((x+cc+h).allSatisfy(\.isFinite) && cc[2] > 0.1, "Nonfinite or nonpositive camera depth")
                    let u = h[0]/h[2], v = h[1]/h[2]
                    predicted.append(.init(x:u,y:v)); world.append(x); depth.append(cc[2]); residual += [(u-pixels[i].x)/bound,(v-pixels[i].y)/bound]
                    for row in 0..<2 {
                        let quotient = (0..<3).map { col in ((row == col ? 1.0 : 0.0)/h[2])-(col == 2 ? h[row]/(h[2]*h[2]) : 0) }
                        let qk = (0..<3).map { col in (0..<3).reduce(0.0) { $0+quotient[$1]*k[$1*3+col] } }
                        let qkr = (0..<3).map { col in (0..<3).reduce(0.0) { $0+qk[$1]*r[$1*3+col] } }
                        J.append((0..<6).map { col in (0..<3).reduce(0.0) { $0+qkr[$1]*bases[i][$1][col] }/bound })
                    }
                }
                try require(residual.allSatisfy(\.isFinite) && J.allSatisfy { $0.allSatisfy(\.isFinite) }, "Nonfinite geometric residual or Jacobian")
                return (residual,J,world,depth,predicted)
            }
            for _ in 0..<config.maximumGaussNewtonIterations {
                let current = try evaluate(theta), before = current.residual.reduce(0) { $0+$1*$1 }
                try require(before.isFinite, "Nonfinite objective")
                let next = try solve(current.jacobian,current.residual.map(-),limit:config.maximumScaledJacobianCondition)
                result.finalSystem = next.system
                guard let step = next.solution else { result.qualityReasons.append("Geometric Jacobian rank or condition rejected"); return result }
                let trial = zip(theta,step).map(+), afterResidual = try evaluate(trial).residual, after = afterResidual.reduce(0) { $0+$1*$1 }, length = norm(step)
                try require(after.isFinite && length.isFinite, "Nonfinite objective or GN step")
                try require(after <= before+1e-9*max(1,before), "Full-step objective increase rejected; no line search")
                result.iterations.append(.init(weightedSSEBefore:before,weightedSSEAfter:after,scaledStepNorm:length,scaledJacobianCondition:next.system.columnScaledCondition!)); theta = trial
                if length < 1e-10 { result.converged = true; break }
            }
            let final = try evaluate(theta), system = try inspect(final.jacobian).0
            result.finalSystem = system
            let position = Array(theta[0..<3]), velocity = theta[3..<6].map { $0/T }, speed = norm(velocity)
            let errors = zip(final.pixel,pixels).map { hypot($0.x-$1.x,$0.y-$1.y) }, rms = norm(errors)/sqrt(Double(errors.count))
            try require((position+velocity+[speed,rms]+errors).allSatisfy(\.isFinite), "Nonfinite derived trajectory metric")
            result.rawMotion = .init(positionFirstObservedMeters:position,velocityFirstObservedMetersPerSecond:velocity,velocityFirstObservedNormMetersPerSecond:speed,scaledFirstObservationParameters:theta)
            result.reprojectionPixels = final.pixel; result.residualsPixels = errors; result.reprojectionRMSPixels = rms; result.reprojectionMaximumPixels = errors.max()
            result.minimumDepthMeters = final.depth.min(); result.minimumHeightMeters = final.world.map { $0[2] }.min()
            result.allResidualsWithinBound = errors.allSatisfy { $0 <= bound }; result.aboveGroundAllObservations = final.world.allSatisfy { $0[2] >= config.contactCenterHeight-1e-6 }
            let a = -0.5*g, b = velocity[2], z = position[2]-config.contactCenterHeight, disc = b*b-4*a*z
            try require(disc.isFinite, "Nonfinite contact discriminant")
            if disc >= 0 {
                let q = -0.5*(b+copysign(sqrt(disc),b))
                let roots = q == 0 ? [-b/(2*a)] : [q/a,z/q]
                try require(roots.allSatisfy(\.isFinite), "Nonfinite ground roots")
                result.allGroundRootsSecondsAfterFirstObserved = Array(Set(roots)).sorted()
                let eligible = result.allGroundRootsSecondsAfterFirstObserved.filter { $0 > T && b-g*$0 < 0 }
                if eligible.count == 1 {
                    let time = eligible[0], at = (0..<3).map { position[$0]+velocity[$0]*time+($0 == 2 ? -0.5*g*time*time : 0) }, vz = b-g*time
                    let depth = mul(r,at)[2]+c.t[2], beyond = time-T
                    try require((at+[vz,depth,beyond]).allSatisfy(\.isFinite), "Nonfinite derived contact")
                    result.futureDownwardGroundRoot = .init(secondsAfterFirstObserved:time,extrapolationSecondsBeyondLastObserved:beyond,positionMeters:at,verticalVelocityMetersPerSecond:vz,cameraDepthMeters:depth)
                }
            }
            if !result.converged { result.qualityReasons.append("Maximum GN iterations reached without step convergence") }
            if !result.allResidualsWithinBound { result.qualityReasons.append("Original radial residual bound exceeded") }
            if !result.aboveGroundAllObservations { result.qualityReasons.append("Observed trajectory penetrates assumed ground") }
            if system.rank != 6 || system.columnScaledCondition.map({ $0 > config.maximumScaledJacobianCondition }) != false { result.qualityReasons.append("Final Jacobian rank or condition rejected") }
            if let root = result.futureDownwardGroundRoot {
                if root.cameraDepthMeters <= 0.1 { result.qualityReasons.append("Predicted contact has invalid camera depth") }
            } else { result.qualityReasons.append("No unique future descending root after last actual observation") }
            result.rawAlgebraicQualityPassed = result.qualityReasons.isEmpty
            result.status = result.rawAlgebraicQualityPassed ? "unqualified_free_contact_diagnostic" : "free_contact_quality_rejected"
        } catch {
            result.status = "rejected"; result.qualityReasons.append(error.localizedDescription)
        }
        return result
    }
}
