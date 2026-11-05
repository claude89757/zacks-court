import Foundation

/// JSON bodies of the protocol v2 message kinds (docs/camera-side-analysis.md §4).
/// Fields are optional where the message is additive, so a v2 peer ignores fields it does not know.
public enum PeerRole: String, Codable, Sendable { case camera, display }

public struct WireHello: Codable, Sendable {
    public var role: PeerRole
    /// User-visible device name.
    public var device: String
    /// Hardware model identifier such as iPhone18,2.
    public var hardware: String
    public var app: String
    public var modelVersion: String?
    /// Display: its open session (metadata without shots), so the camera can adopt it or resolve a
    /// conflict. Camera: its open session, if any.
    public var session: CourtSession?
    /// Optional features this peer handles (Phase 3). Older v2 peers omit it, and a peer only uses
    /// a feature the other side lists, so new commands never reach a build that cannot decode them.
    public var capabilities: [String]?
    /// Camera cuts per-shot clips on request (`WireControl.Command.clip`).
    public static let clips = "clips"
    /// Camera makes line calls with the settings of `WireControl.Command.hawkEye`.
    public static let hawkEye = "hawkEye"
    /// Camera takes challenges (`WireControl.Command.challenge`) and stores them on shot rows.
    public static let challenge = "challenge"
    public init(role: PeerRole, device: String, hardware: String, app: String, modelVersion: String? = nil, session: CourtSession? = nil, capabilities: [String]? = nil) {
        self.role = role; self.device = String(device.prefix(80)); self.hardware = String(hardware.prefix(40))
        self.app = String(app.prefix(40)); self.modelVersion = modelVersion; self.session = session
        self.capabilities = capabilities.map { Array($0.prefix(16).map { String($0.prefix(40)) }) }
    }
}

/// Device conditions the camera reports at 1 Hz. Unknown values stay nil, never 0.
public struct CameraDeviceState: Codable, Equatable, Sendable {
    public var battery: Double?
    public var charging: Bool?
    public var lowPowerMode = false
    /// ProcessInfo.ThermalState name: nominal, fair, serious, critical.
    public var thermal = "nominal"
    /// AVCaptureDevice.SystemPressureState level (iOS only).
    public var pressure: String?
    public var freeBytes: Int64?
    /// "live" (preview on screen) or "standby" (black, dimmed).
    public var screen = "live"
    public init() {}
}

public struct CameraAnalysisStatus: Codable, Equatable, Sendable {
    public var available = false
    public var reason: String?
    public var streamID: UUID?
    public var latestPTS: Double?
    public var analyzedPTS: Double?
    public var processedFrames = 0
    public var inferenceMilliseconds = 0.0
    public var pendingFrames = 0
    public var restarts = 0
    public var calibration: TennisCourtCalibrationState?
    public var modelVersion: String?
    public var limitations: [String] = []
    /// Automatic court diagnostics (in-house lane); nil from older v2 cameras.
    public var court: CameraCourtDiagnostics?
    public init() {}
}

public struct CameraStatus: Codable, Equatable, Sendable {
    public var capturing = false
    public var recording = false
    public var saving = false
    public var fps = 0
    public var captureDrops: UInt64 = 0
    public var recordingSeconds: Double?
    public var sessionID: UUID?
    public var analysis = CameraAnalysisStatus()
    public var device = CameraDeviceState()
    /// Load-shedding level 0–4 (docs/camera-side-analysis.md §7).
    public var shed = 0
    public var shedReason: String?
    /// What raised `shed`: `heat`, `pressure`, `lowPower` or `lag` (analysis behind capture). nil at L0
    /// or from an older v2 camera.
    public var shedCause: String?
    public var warnings: [String] = []
    public var near: TennisHandedness = .right
    public var far: TennisHandedness = .right
    public var previewing = false
    public var people: AnalysisSnapshot?
    /// State of the camera's session `sessionID` (nil with no session, or from an older v2 camera).
    /// Displays compare it with their mirror once a second and re-sync when they disagree.
    public var sessionState: SessionState?
    /// The camera is finishing a pause or finish (stopping the recording, sealing analysis); session
    /// commands sent now are refused. nil from an older v2 camera.
    public var busy: Bool?
    /// Digital zoom of the capture (1 = no zoom). nil when not capturing, without zoom, or from an
    /// older v2 camera.
    public var zoom: Double?
    /// Line-call settings in use (nil from an older v2 camera).
    public var hawkEye: HawkEyeSettings?
    public init() {}

    public static func == (lhs: CameraStatus, rhs: CameraStatus) -> Bool {
        lhs.capturing == rhs.capturing && lhs.recording == rhs.recording && lhs.saving == rhs.saving &&
            lhs.fps == rhs.fps && lhs.captureDrops == rhs.captureDrops && lhs.recordingSeconds == rhs.recordingSeconds &&
            lhs.sessionID == rhs.sessionID && lhs.analysis == rhs.analysis && lhs.device == rhs.device &&
            lhs.shed == rhs.shed && lhs.shedReason == rhs.shedReason && lhs.shedCause == rhs.shedCause && lhs.warnings == rhs.warnings &&
            lhs.near == rhs.near && lhs.far == rhs.far &&
            lhs.previewing == rhs.previewing && lhs.people?.pts == rhs.people?.pts &&
            lhs.sessionState == rhs.sessionState && lhs.busy == rhs.busy && lhs.zoom == rhs.zoom &&
            lhs.hawkEye == rhs.hawkEye
    }
}

/// Display → camera commands, and the camera's replies (`command == .reply`).
public struct WireControl: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case start, pause, resume, finish, marker, handedness, preview, wake, reply
        /// Manual court corners and the still frame to tap them on, from displays before they were removed.
        /// Kept so such a command still decodes and gets a refusal instead of no answer.
        case corners, still
        /// Display → replaced camera: another camera took this display; stop reconnecting.
        case superseded
        /// Recording transfer: `label` names the file, `offset` resumes a partial copy.
        case transfer, cancelTransfer
        /// Short clip of a recording (Phase 3, only to a camera whose hello lists `WireHello.clips`):
        /// `stream`, source PTS window `sourcePTS`…`endPTS`, `label` the clip file name. Cancelled
        /// with `cancelTransfer`.
        case clip
        /// Line-call settings `hawkEye` (only to a camera whose hello lists `WireHello.hawkEye`). The
        /// camera echoes them in `CameraStatus.hawkEye`.
        case hawkEye
        /// Challenge a shot's line call (only to a camera whose hello lists `WireHello.challenge`):
        /// `shot`, or the newest shot when nil; `format` the lines to use when Hawk-Eye was never set.
        /// The camera stores the result on the row (`TennisShotEvent.challenge`) and sends the row to
        /// every display, which plays the replay.
        case challenge
    }
    public var id = UUID()
    public var command: Command
    public var sessionID: UUID?
    /// start: the display's session metadata, adopted by the camera (same ID, title, kind, markers).
    public var session: CourtSession?
    public var label: String?
    public var date: Date?
    public var sourcePTS: Double?
    /// clip: end of the source PTS window that starts at `sourcePTS`.
    public var endPTS: Double?
    /// clip: capture stream of the window.
    public var stream: UUID?
    public var near: TennisHandedness?
    public var far: TennisHandedness?
    /// hawkEye: the settings to use from now on.
    public var hawkEye: HawkEyeSettings?
    /// challenge: the shot (nil: the newest) and the singles/doubles lines to judge it by.
    public var shot: UUID?
    public var format: HawkEyeFormat?
    public var enabled: Bool?
    public var offset: Int64?
    public var replyTo: UUID?
    public var ok: Bool?
    public var message: String?
    public init(_ command: Command, sessionID: UUID? = nil) { self.command = command; self.sessionID = sessionID }
    public static func reply(to request: WireControl, ok: Bool, message: String? = nil) -> WireControl {
        var value = WireControl(.reply, sessionID: request.sessionID)
        value.replyTo = request.id; value.ok = ok; value.message = message.map { String($0.prefix(300)) }
        return value
    }
}

/// Camera → display shot rows. Live messages carry only rows that changed; a resync after
/// (re)connect carries the whole ledger of the open or most recent session in parts.
public struct WireAnalysis: Codable, Sendable {
    /// nil for rows outside any session (dashboard before recording starts).
    public var sessionID: UUID?
    public var events: [TennisShotEvent]
    public var calibration: TennisCourtCalibrationState?
    public var modelVersion: String?
    public var resync: Bool?
    public var part: Int?
    public var parts: Int?
    public init(sessionID: UUID?, events: [TennisShotEvent], calibration: TennisCourtCalibrationState? = nil, modelVersion: String? = nil) {
        self.sessionID = sessionID; self.events = events; self.calibration = calibration; self.modelVersion = modelVersion
    }
    public static let resyncChunk = 200
    /// Full-ledger resync messages; always at least one so the display can clear stale rows.
    public static func resync(sessionID: UUID?, events: [TennisShotEvent], calibration: TennisCourtCalibrationState?, modelVersion: String?) -> [WireAnalysis] {
        let chunks = stride(from: 0, to: max(events.count, 1), by: resyncChunk).map { Array(events[$0..<min(events.count, $0 + resyncChunk)]) }
        return chunks.enumerated().map { index, rows in
            var message = WireAnalysis(sessionID: sessionID, events: rows, calibration: calibration, modelVersion: modelVersion)
            message.resync = true; message.part = index; message.parts = chunks.count
            return message
        }
    }
}

public extension StreamPacket {
    /// A JSON-bodied control-plane packet (hello, status, control, analysis, session).
    static func message<T: Encodable>(_ kind: WireKind, _ body: T) throws -> StreamPacket {
        let encoder = JSONEncoder()
        return StreamPacket(header: StreamHeader(kind: kind.rawValue), payload: try encoder.encode(body))
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !payload.isEmpty else { throw CourtError.message("消息内容为空：\(header.kind)") }
        return try JSONDecoder().decode(type, from: payload)
    }
    var wireKind: WireKind? { WireKind(rawValue: header.kind) }
}
