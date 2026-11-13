import Foundation
import CourtCore
#if os(iOS)
import Photos
#endif

/// What the player can hand to the share sheet or the photo library: a file already on this device,
/// or a shot still inside a local recording that is cut out first (a few seconds, no re-encoding).
struct PlaybackExport: Sendable {
    enum Source: Sendable {
        case file(URL)
        /// Source-PTS window of a shot inside a finished recording whose first frame is `firstPTS`.
        case cut(recording: URL, firstPTS: Double, duration: Double, start: Double, end: Double)
    }
    let source: Source
    /// File name the user sees after sharing or saving, with extension.
    let name: String
    /// "这一拍" or "整段录像", for button labels.
    let what: String

    /// A shot: the clip already on this device, or a cut from the local recording.
    static func shot(_ shot: TennisShotEvent, session: CourtSession?, source: Source) -> PlaybackExport {
        PlaybackExport(source: source, name: VideoExport.shotName(shot, session: session), what: courtText("这一拍"))
    }
    /// The shot's window, as the camera would cut it, out of a recording on this device.
    static func shot(_ shot: TennisShotEvent, session: CourtSession?, recording: URL, firstPTS: Double, duration: Double) -> PlaybackExport {
        let window = ClipExport.window(for: shot)
        return .shot(shot, session: session, source: .cut(recording: recording, firstPTS: firstPTS, duration: duration, start: window.start, end: window.end))
    }
    static func recording(_ url: URL) -> PlaybackExport {
        PlaybackExport(source: .file(url), name: url.lastPathComponent, what: courtText("整段录像"))
    }

    /// The file to share, under `name`. Cutting reads only a few seconds of the recording.
    func prepare() async throws -> URL {
        switch source {
        case .file(let url):
            return try VideoExport.named(url, name)
        case .cut(let recording, let firstPTS, let duration, let start, let end):
            let into = try VideoExport.freshFolder().appendingPathComponent(name)
            let from = max(0, start - firstPTS), to = min(duration, end - firstPTS)
            guard to > from else { throw CourtError.message(courtText("录像里没有这一拍的画面。")) }
            return try await ClipExport.cut(recording, firstPTS: firstPTS, from: from, to: to, into: into).url
        }
    }
}

/// Files handed out for sharing live in one temporary folder that is emptied before each export,
/// so sharing never leaves copies behind. Whole recordings are shared in place (they can be
/// gigabytes); a clip gets a readable name through a hard link, which takes no extra space.
enum VideoExport {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Zacks Court Export", isDirectory: true) }

    static func freshFolder() throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    /// Removes anything left from earlier exports (called when the app starts).
    static func clearLeftovers() { try? FileManager.default.removeItem(at: folder) }

    static func named(_ url: URL, _ name: String) throws -> URL {
        guard url.lastPathComponent != name else { return url }
        let target = try freshFolder().appendingPathComponent(name)
        do { try FileManager.default.linkItem(at: url, to: target) }
        catch { return url }   // another volume: share it under its own name rather than copy it
        return target
    }

    /// "ZacksCourt-20261103-1422-第12拍-正手-128kmh.mov": the session's start, the shot's number in
    /// the session, the stroke and the speed when there is a valid one.
    static func shotName(_ shot: TennisShotEvent, session: CourtSession?) -> String {
        var parts = ["ZacksCourt"]
        if let session {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
            parts.append(formatter.string(from: session.startedAt))
            let ordered = (session.tennisEvents ?? []).sorted { $0.sourcePTS < $1.sourcePTS }
            if let index = ordered.firstIndex(where: { $0.id == shot.id }) { parts.append(courtFormat("第%1$@拍", "\(index + 1)")) }
        }
        parts.append(shot.stroke.courtTitle)
        if let speed = shot.validSpeedKPH { parts.append("\(Int(speed.rounded()))kmh") }
        return parts.joined(separator: "-") + ".mov"
    }

    #if os(iOS)
    /// Adds the video to the photo library with add-only access.
    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CourtError.message(courtText("没有存入相册的权限。可在「设置 › Zacks Court › 照片」里选「仅添加照片」。"))
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions(); options.originalFilename = url.lastPathComponent
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }
    #endif
}
