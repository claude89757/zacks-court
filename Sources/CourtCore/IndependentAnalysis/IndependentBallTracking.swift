import Foundation
import CoreMedia

/// Pixel candidates and a past-only association baseline. This module estimates
/// image motion only; it does not infer semantic ball identity or physical speed.
public enum IndependentBallTrackingError: Error {
    case invalidHeatmap, invalidTransform, invalidTimestamp, invalidCandidate, invalidConfiguration
}

public struct IndependentBallImageTransform: Codable, Equatable, Sendable {
    public let originalWidth: Int, originalHeight: Int
    public let cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int
    public init(originalWidth: Int, originalHeight: Int, cropX: Int = 0, cropY: Int = 0,
                cropWidth: Int? = nil, cropHeight: Int? = nil) throws {
        let w = cropWidth ?? originalWidth, h = cropHeight ?? originalHeight
        guard originalWidth > 0, originalHeight > 0, originalWidth <= 16384, originalHeight <= 16384,
              cropX >= 0, cropY >= 0, w > 0, h > 0,
              Double(cropX) + Double(w) <= Double(originalWidth),
              Double(cropY) + Double(h) <= Double(originalHeight) else { throw IndependentBallTrackingError.invalidTransform }
        self.originalWidth = originalWidth; self.originalHeight = originalHeight
        self.cropX = cropX; self.cropY = cropY; self.cropWidth = w; self.cropHeight = h
    }
    func original(_ x: Int, _ y: Int, width: Int, height: Int) -> [Int] {
        [Int(Double(cropX) + Double(x)*Double(cropWidth)/Double(width)),
         Int(Double(cropY) + Double(y)*Double(cropHeight)/Double(height))]
    }
}

public struct IndependentBallGridCandidate: Codable, Equatable, Sendable {
    public let identifier: Int
    public let box: [Int]
    public let originalXY: [Int]
    public let equivalentXY: [Double]
    public let peak: Float
    public let mean: Double
    public let pixelArea: Int
    /// Heat-weighted centre of the component in source pixels (cell centres), not rounded to the model grid.
    public var centroidXY: [Double]? = nil
    /// Decoded invalid boxes are rejected by the tracker, never indexed or
    /// multiplied unsafely by this public convenience property.
    public var boxArea: Int {
        guard box.count == 4, box[2] > 0, box[3] > 0 else { return 0 }
        let (area, overflow) = box[2].multipliedReportingOverflow(by: box[3])
        return overflow ? 0 : area
    }
}

public struct IndependentBallCandidateBank: Codable, Sendable {
    public let candidates: [IndependentBallGridCandidate]
    public let totalComponents: Int
    public let truncatedComponents: Int

    /// Eight-connected binary components, bbox centres, strict threshold. This
    /// is the candidate-bank rule; ties use raster seed rather than OpenCV's
    /// version-dependent component IDs. It is not an exact Python tie-order port.
    public static func extract(_ heatmap: [Float], width: Int = 512, height: Int = 288,
                               threshold: Float = 0.3, topK: Int = 20,
                               transform: IndependentBallImageTransform) throws -> Self {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, width <= 512, height <= 288, !overflow, count <= 512*288, heatmap.count == count,
              threshold.isFinite, threshold >= 0, threshold < 1, topK > 0, topK <= 20,
              heatmap.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw IndependentBallTrackingError.invalidHeatmap }
        // Revalidate decoded transforms; Codable can bypass a custom initializer.
        _ = try IndependentBallImageTransform(originalWidth: transform.originalWidth, originalHeight: transform.originalHeight,
            cropX: transform.cropX, cropY: transform.cropY, cropWidth: transform.cropWidth, cropHeight: transform.cropHeight)
        var visited = [Bool](repeating: false, count: count), components: [IndependentBallGridCandidate] = []
        for seed in 0..<count where !visited[seed] && heatmap[seed] > threshold {
            visited[seed] = true
            var stack = [seed], minX = seed%width, maxX = minX, minY = seed/width, maxY = minY
            var area = 0, peak: Float = 0, sum = 0.0, sumX = 0.0, sumY = 0.0
            while let index = stack.popLast() {
                let x = index%width, y = index/width, value = heatmap[index]
                area += 1; sum += Double(value); peak = max(peak, value)
                sumX += Double(value) * (Double(x) + 0.5); sumY += Double(value) * (Double(y) + 0.5)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for yy in max(0, y-1)...min(height-1, y+1) {
                    for xx in max(0, x-1)...min(width-1, x+1) {
                        let next = yy*width+xx
                        if !visited[next] && heatmap[next] > threshold { visited[next] = true; stack.append(next) }
                    }
                }
            }
            let w = maxX-minX+1, h = maxY-minY+1
            let point = transform.original(minX+w/2, minY+h/2, width: width, height: height)
            components.append(.init(identifier: seed+1, box: [minX,minY,w,h], originalXY: point,
                equivalentXY: [Double(point[0])*1280/Double(transform.originalWidth), Double(point[1])*720/Double(transform.originalHeight)],
                peak: peak, mean: sum/Double(area), pixelArea: area,
                centroidXY: sum > 0 ? [Double(transform.cropX) + sumX/sum*Double(transform.cropWidth)/Double(width),
                                       Double(transform.cropY) + sumY/sum*Double(transform.cropHeight)/Double(height)] : nil))
        }
        components.sort {
            if $0.peak != $1.peak { return $0.peak > $1.peak }
            if $0.boxArea != $1.boxArea { return $0.boxArea > $1.boxArea }
            return $0.identifier < $1.identifier
        }
        return .init(candidates: Array(components.prefix(topK)), totalComponents: components.count,
                     truncatedComponents: max(0, components.count-topK))
    }
}

public struct IndependentBallFrameTime: Codable, Equatable, Sendable {
    public let sourcePTS: Int64
    public let timeBaseNumerator: Int32, timeBaseDenominator: Int32
    public init(sourcePTS: Int64, timeBaseNumerator: Int32 = 1, timeBaseDenominator: Int32) throws {
        self.sourcePTS = sourcePTS; self.timeBaseNumerator = timeBaseNumerator; self.timeBaseDenominator = timeBaseDenominator
        _ = try mediaTime()
    }
    func mediaTime() throws -> CMTime {
        guard timeBaseNumerator > 0, timeBaseDenominator > 0 else { throw IndependentBallTrackingError.invalidTimestamp }
        let value = CMTimeMultiply(CMTime(value: sourcePTS, timescale: timeBaseDenominator), multiplier: timeBaseNumerator)
        guard value.isNumeric, !value.flags.contains(.hasBeenRounded), value.seconds.isFinite else { throw IndependentBallTrackingError.invalidTimestamp }
        return value
    }
}

public struct IndependentBallTrackSelection: Codable, Sendable {
    public let time: IndependentBallFrameTime
    public let candidate: IndependentBallGridCandidate?
    public let linkedToPast: Bool
    public let resetReason: String?
    public let missingReason: String?
    public let incrementalCost: Double
}

/// Call only on the independent analysis queue. No frame buffers are retained.
public final class IndependentCausalBallTracker {
    private struct Seen { let time: CMTime; let xy: [Double] }
    private let period: Double
    private var sourceID: String?, transform: IndependentBallImageTransform?, previousInput: CMTime?
    private var history: [Seen] = []
    public init(nominalFramesPerSecond: Double = 60) throws {
        guard nominalFramesPerSecond.isFinite, nominalFramesPerSecond > 0, nominalFramesPerSecond <= 240 else { throw IndependentBallTrackingError.invalidConfiguration }
        let period = 1/nominalFramesPerSecond
        guard period.isFinite, period > 0 else { throw IndependentBallTrackingError.invalidConfiguration }
        self.period = period
    }
    public func reset() { sourceID = nil; transform = nil; previousInput = nil; history.removeAll() }

    public func select(candidates: [IndependentBallGridCandidate], time: IndependentBallFrameTime,
                       sourceID: String, transform: IndependentBallImageTransform, gapBefore: Bool = false) throws -> IndependentBallTrackSelection {
        do {
            return try selectValidated(candidates: candidates, time: time, sourceID: sourceID, transform: transform, gapBefore: gapBefore)
        } catch {
            reset()
            throw error
        }
    }
    private func selectValidated(candidates: [IndependentBallGridCandidate], time: IndependentBallFrameTime,
                                 sourceID: String, transform: IndependentBallImageTransform, gapBefore: Bool) throws -> IndependentBallTrackSelection {
        _ = try IndependentBallImageTransform(originalWidth: transform.originalWidth, originalHeight: transform.originalHeight,
            cropX: transform.cropX, cropY: transform.cropY, cropWidth: transform.cropWidth, cropHeight: transform.cropHeight)
        let now = try time.mediaTime()
        guard !sourceID.isEmpty else { reset(); throw IndependentBallTrackingError.invalidTimestamp }
        var reason: String?
        if self.sourceID != sourceID { history.removeAll(); previousInput = nil; reason = "source_changed" }
        if let old = self.transform, old != transform { history.removeAll(); previousInput = nil; reason = "image_transform_changed" }
        if let previousInput {
            guard CMTimeCompare(now, previousInput) > 0 else { reset(); throw IndependentBallTrackingError.invalidTimestamp }
            if CMTimeSubtract(now, previousInput).seconds > 1.5*period { history.removeAll(); reason = "source_gap" }
        }
        if gapBefore { history.removeAll(); reason = "source_gap" }
        if let last = history.last, CMTimeSubtract(now,last.time).seconds > 0.20 { history.removeAll(); reason = "last_seen_timeout" }
        guard candidates.count <= 20, Set(candidates.map(\.identifier)).count == candidates.count else { throw IndependentBallTrackingError.invalidCandidate }
        for c in candidates {
            guard c.originalXY.count == 2, c.equivalentXY.count == 2, c.peak.isFinite, c.peak > 0, c.peak <= 1,
                  c.equivalentXY.allSatisfy(\.isFinite), c.box.count == 4,
                  c.identifier > 0, c.mean.isFinite, c.mean >= 0, c.mean <= 1,
                  c.box[0] >= 0, c.box[0] < 512, c.box[1] >= 0, c.box[1] < 288,
                  c.box[2] > 0, c.box[2] <= 512-c.box[0], c.box[3] > 0, c.box[3] <= 288-c.box[1],
                  c.pixelArea > 0, c.pixelArea <= c.boxArea,
                  c.originalXY[0] >= 0, c.originalXY[0] < transform.originalWidth,
                  c.originalXY[1] >= 0, c.originalXY[1] < transform.originalHeight,
                  c.originalXY[0] >= transform.cropX, c.originalXY[0] < transform.cropX+transform.cropWidth,
                  c.originalXY[1] >= transform.cropY, c.originalXY[1] < transform.cropY+transform.cropHeight,
                  abs(c.equivalentXY[0]-Double(c.originalXY[0])*1280/Double(transform.originalWidth)) < 1e-9,
                  abs(c.equivalentXY[1]-Double(c.originalXY[1])*720/Double(transform.originalHeight)) < 1e-9
            else { throw IndependentBallTrackingError.invalidCandidate }
        }
        self.sourceID = sourceID; self.transform = transform; previousInput = now
        var selected: IndependentBallGridCandidate?, bestCost = 2.5
        for candidate in candidates {
            var cost = -log(max(Double(candidate.peak), 1e-6))
            if let last = history.last {
                let dt = CMTimeSubtract(now,last.time).seconds
                guard dt.isFinite, dt > 0 else { reset(); throw IndependentBallTrackingError.invalidTimestamp }
                let displacement = hypot(candidate.equivalentXY[0]-last.xy[0], candidate.equivalentXY[1]-last.xy[1])
                if displacement > 8+3000*dt { continue }
                var prediction = last.xy
                if history.count == 2 {
                    let earlier = history[0], oldDT = CMTimeSubtract(last.time,history[0].time).seconds
                    guard oldDT.isFinite, oldDT > 0 else { reset(); throw IndependentBallTrackingError.invalidTimestamp }
                    prediction = [last.xy[0]+(last.xy[0]-earlier.xy[0])*dt/oldDT,
                                  last.xy[1]+(last.xy[1]-earlier.xy[1])*dt/oldDT]
                }
                let residual = hypot(candidate.equivalentXY[0]-prediction[0], candidate.equivalentXY[1]-prediction[1]), sigma = 8+800*dt
                if residual > 3*sigma { continue }
                cost += 0.5*pow(residual/sigma, 2)
            }
            if cost < bestCost || (cost == bestCost && (selected == nil || candidate.identifier < selected!.identifier)) {
                selected = candidate; bestCost = cost
            }
        }
        let linked = selected != nil && !history.isEmpty
        if let selected {
            history.append(.init(time: now, xy: selected.equivalentXY))
            if history.count > 2 { history.removeFirst() }
        }
        return .init(time: time, candidate: selected, linkedToPast: linked, resetReason: reason,
                     missingReason: selected == nil ? (candidates.isEmpty ? "no_candidate" : "association_rejected") : nil,
                     incrementalCost: bestCost)
    }
}
