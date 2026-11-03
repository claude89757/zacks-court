import Foundation
import CoreMedia
import simd

/// Raw observations made for one delivered capture frame. These do not establish a calibrated,
/// undistorted pinhole camera, a pixel transform, or a physical speed measurement.
public struct CaptureFrameMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let captureSequence: UInt64
    public let sourcePTS: SourceTime
    public let deliveredWidth: Int
    public let deliveredHeight: Int
    public let intrinsic: IntrinsicObservation
    public let deliveryState: DeliveryState
    public let connection: ConnectionObservation
    public let device: DeviceObservation
    public let intrinsicPixelTransformVerified: Bool
    public let undistortedPinholeVerified: Bool

    public enum DeliveryState: String, Codable, Sendable { case enabled, disabled, unsupported }
    public enum OmissionReason: String, Codable, Sendable {
        case invalidSourcePTS, sourcePTSMismatch, deliveredDimensionsMismatch, encoderDimensionsMismatch
    }

    /// Retains the exact CMTime representation, including epoch and flags (not just seconds).
    public struct SourceTime: Codable, Sendable, Equatable {
        public let value: Int64
        public let timescale: Int32
        public let epoch: Int64
        public let flags: UInt32
        public init(_ time: CMTime) {
            value = time.value; timescale = time.timescale; epoch = time.epoch; flags = time.flags.rawValue
        }
        public var cmTime: CMTime { CMTime(value: value, timescale: timescale, flags: CMTimeFlags(rawValue: flags), epoch: epoch) }
        public var isNumeric: Bool {
            let numericFlags = CMTimeFlags.valid.rawValue | CMTimeFlags.hasBeenRounded.rawValue
            return flags & ~numericFlags == 0 && cmTime.isNumeric && timescale > 0 && cmTime.seconds.isFinite
        }
    }

    public struct IntrinsicObservation: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case available, missing, invalid }
        public enum Reason: String, Codable, Sendable {
            case attachmentMissing, wrongAttachmentType, wrongByteCount, unsupportedMatrixLayout, nonFiniteMatrix, invalidLogicalMatrix
        }
        public let status: Status
        public let reason: Reason?
        /// Nine logical entries in column-major order. SIMD padding is never retained.
        public let columnMajor9: [Float]?
        public let attachmentByteCount: Int?

        private init(status: Status, reason: Reason?, columnMajor9: [Float]? = nil, attachmentByteCount: Int? = nil) {
            self.status = status; self.reason = reason; self.columnMajor9 = columnMajor9; self.attachmentByteCount = attachmentByteCount
        }
        public static var missing: Self { Self(status: .missing, reason: .attachmentMissing) }

        /// CoreMedia's attachment is CFData containing a native matrix_float3x3: three padded
        /// SIMD3 columns (48 bytes), not a packed array of nine floats (36 bytes).
        public static func from(sampleBuffer: CMSampleBuffer) -> Self {
            from(attachment: CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil))
        }
        public static func from(attachment: CFTypeRef?) -> Self {
            guard let attachment else { return .missing }
            guard CFGetTypeID(attachment) == CFDataGetTypeID() else { return Self(status: .invalid, reason: .wrongAttachmentType) }
            let data = unsafeBitCast(attachment, to: CFData.self)
            let count = CFDataGetLength(data)
            guard MemoryLayout<simd_float3x3>.size == 48, MemoryLayout<simd_float3x3>.stride == 48,
                  MemoryLayout<SIMD3<Float>>.stride == 16 else {
                return Self(status: .invalid, reason: .unsupportedMatrixLayout, attachmentByteCount: count)
            }
            guard count == 48 else { return Self(status: .invalid, reason: .wrongByteCount, attachmentByteCount: count) }
            // Copy into an aligned local value; do not bind/load a possibly unaligned Data pointer.
            var matrix = simd_float3x3()
            withUnsafeMutableBytes(of: &matrix) { bytes in
                CFDataGetBytes(data, CFRange(location: 0, length: count), bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
            let values = (0..<3).flatMap { column in (0..<3).map { row in matrix[column][row] } }
            guard values.allSatisfy(\.isFinite) else { return Self(status: .invalid, reason: .nonFiniteMatrix, attachmentByteCount: count) }
            return Self(status: .available, reason: nil, columnMajor9: values, attachmentByteCount: count)
        }

        private enum CodingKeys: String, CodingKey { case status, reason, columnMajor9, attachmentByteCount }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let status = try c.decode(Status.self, forKey: .status)
            let reason = try c.decodeIfPresent(Reason.self, forKey: .reason)
            let count = try c.decodeIfPresent(Int.self, forKey: .attachmentByteCount)
            // Bound allocation even for untrusted JSON arrays; observations have exactly nine entries.
            var values: [Float]? = nil
            if c.contains(.columnMajor9), !(try c.decodeNil(forKey: .columnMajor9)) {
                var entries = try c.nestedUnkeyedContainer(forKey: .columnMajor9)
                guard entries.count == 9 else {
                    self.init(status: .invalid, reason: .invalidLogicalMatrix, attachmentByteCount: count); return
                }
                values = try (0..<9).map { _ in try entries.decode(Float.self) }
            }
            if status == .available {
                guard count == 48, let values, values.count == 9, values.allSatisfy(\.isFinite), reason == nil else {
                    self.init(status: .invalid, reason: .invalidLogicalMatrix, attachmentByteCount: count); return
                }
                self.init(status: .available, reason: nil, columnMajor9: values, attachmentByteCount: count)
            } else {
                self.init(status: status, reason: reason ?? (status == .missing ? .attachmentMissing : .invalidLogicalMatrix), attachmentByteCount: count)
            }
        }
    }

    public struct ConnectionObservation: Codable, Sendable, Equatable {
        public let rotationDegrees: Double?
        public let mirrored: Bool?
        public let preferredStabilization: Int?
        public let activeStabilization: Int?
        public init(rotationDegrees: Double? = nil, mirrored: Bool? = nil, preferredStabilization: Int? = nil, activeStabilization: Int? = nil) {
            self.rotationDegrees = rotationDegrees.flatMap { $0.isFinite ? $0 : nil }
            self.mirrored = mirrored; self.preferredStabilization = preferredStabilization; self.activeStabilization = activeStabilization
        }
        private enum CodingKeys: String, CodingKey { case rotationDegrees, mirrored, preferredStabilization, activeStabilization }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees), mirrored: try c.decodeIfPresent(Bool.self, forKey: .mirrored),
                      preferredStabilization: try c.decodeIfPresent(Int.self, forKey: .preferredStabilization), activeStabilization: try c.decodeIfPresent(Int.self, forKey: .activeStabilization))
        }
    }

    public struct DeviceObservation: Codable, Sendable, Equatable {
        public enum Timing: String, Codable, Sendable { case callbackQueryNotFrameLocked = "callback_query_not_frame_locked" }
        public let observationTiming: Timing
        public let zoomFactor: Double?
        public let exposureDuration: SourceTime?
        public let iso: Double?
        public let lensPosition: Double?
        public init(zoomFactor: Double? = nil, exposureDuration: CMTime? = nil, iso: Double? = nil, lensPosition: Double? = nil) {
            observationTiming = .callbackQueryNotFrameLocked
            self.zoomFactor = zoomFactor.flatMap { $0.isFinite ? $0 : nil }
            self.exposureDuration = exposureDuration.map(SourceTime.init).flatMap { $0.isNumeric ? $0 : nil }
            self.iso = iso.flatMap { $0.isFinite ? $0 : nil }
            self.lensPosition = lensPosition.flatMap { $0.isFinite ? $0 : nil }
        }
        private enum CodingKeys: String, CodingKey { case observationTiming, zoomFactor, exposureDuration, iso, lensPosition }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            _ = try c.decode(Timing.self, forKey: .observationTiming)
            self.init(zoomFactor: try c.decodeIfPresent(Double.self, forKey: .zoomFactor),
                      exposureDuration: try c.decodeIfPresent(SourceTime.self, forKey: .exposureDuration)?.cmTime,
                      iso: try c.decodeIfPresent(Double.self, forKey: .iso), lensPosition: try c.decodeIfPresent(Double.self, forKey: .lensPosition))
        }
    }

    public init(captureSequence: UInt64, sourcePTS: CMTime, deliveredWidth: Int, deliveredHeight: Int,
                intrinsic: IntrinsicObservation, deliveryState: DeliveryState,
                connection: ConnectionObservation = .init(), device: DeviceObservation = .init()) {
        schemaVersion = 1; self.captureSequence = captureSequence; self.sourcePTS = SourceTime(sourcePTS)
        self.deliveredWidth = deliveredWidth; self.deliveredHeight = deliveredHeight
        self.intrinsic = intrinsic; self.deliveryState = deliveryState; self.connection = connection; self.device = device
        intrinsicPixelTransformVerified = false; undistortedPinholeVerified = false
    }

    /// Never discard a video frame because an observation was supplied for another frame.
    func omissionReason(pts: CMTime, deliveredWidth: Int, deliveredHeight: Int, encoderWidth: Int, encoderHeight: Int) -> OmissionReason? {
        guard sourcePTS.isNumeric else { return .invalidSourcePTS }
        guard sourcePTS == SourceTime(pts) else { return .sourcePTSMismatch }
        guard self.deliveredWidth > 0, self.deliveredHeight > 0,
              self.deliveredWidth == deliveredWidth, self.deliveredHeight == deliveredHeight else { return .deliveredDimensionsMismatch }
        guard deliveredWidth == encoderWidth, deliveredHeight == encoderHeight else { return .encoderDimensionsMismatch }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureSequence, sourcePTS, deliveredWidth, deliveredHeight, intrinsic, deliveryState, connection, device
        case intrinsicPixelTransformVerified, undistortedPinholeVerified
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(Bool.self, forKey: .intrinsicPixelTransformVerified) == false,
              try c.decode(Bool.self, forKey: .undistortedPinholeVerified) == false else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported capture observation schema or calibration claims"))
        }
        self.init(captureSequence: try c.decode(UInt64.self, forKey: .captureSequence), sourcePTS: try c.decode(SourceTime.self, forKey: .sourcePTS).cmTime,
                  deliveredWidth: try c.decode(Int.self, forKey: .deliveredWidth), deliveredHeight: try c.decode(Int.self, forKey: .deliveredHeight),
                  intrinsic: try c.decode(IntrinsicObservation.self, forKey: .intrinsic), deliveryState: try c.decode(DeliveryState.self, forKey: .deliveryState),
                  connection: try c.decode(ConnectionObservation.self, forKey: .connection), device: try c.decode(DeviceObservation.self, forKey: .device))
    }
}
