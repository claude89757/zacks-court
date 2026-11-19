import Foundation
import Observation
import CoreTransferable
import UniformTypeIdentifiers
import CourtCore

/// 「导入视频」: pick a tennis video, analyse it with the camera's in-house live lane
/// (`VideoImportRun`) and save it as an ordinary record in History. Only the bundled in-house
/// models are used; nothing here loads the S家 models.
@MainActor @Observable final class VideoImportModel {
    enum Phase: Equatable { case idle, loading, inspecting, ready, rejected, running, done }

    private(set) var phase: Phase = .idle
    private(set) var info: VideoImport.Info?
    /// Why the picked video cannot be analysed, or why the last run stopped.
    private(set) var message: String?
    private(set) var progress: VideoImportRun.Progress?
    private(set) var result: CourtSession?
    /// Set when this build has no in-house models (code-only or S家-only builds).
    let unavailableReason: String?
    var isRunning: Bool { phase == .running }
    var canPick: Bool { unavailableReason == nil && phase != .running && phase != .loading && phase != .inspecting }
    var canStart: Bool { unavailableReason == nil && (phase == .ready || phase == .done) && info != nil }

    @ObservationIgnored private let storageDirectory: URL
    @ObservationIgnored private let live: () -> IndependentLiveConfiguration
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var scoped = false
    @ObservationIgnored private var temporary = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancelReason: String?
    /// Called on the main actor once a record has been saved (the workspace reloads History).
    @ObservationIgnored var onSaved: ((CourtSession) -> Void)?

    init(storageDirectory: URL, bundle: Bundle = .main) {
        self.storageDirectory = storageDirectory
        unavailableReason = CourtAnalysisBackend.bundled(in: bundle).contains(.independent)
            ? nil : courtText("这个安装包没有自研分析模型，不能分析导入的视频。")
        live = { IndependentLiveConfiguration.bundled(bundle) }
    }

    // MARK: Picking

    /// Photos hands the video over as a copy; show that while it is being copied.
    func loadingFromPhotos() {
        guard canPick else { return }
        releaseSource(); generation = UUID()
        phase = .loading; info = nil; result = nil; progress = nil; message = nil
    }

    /// A file from the Files picker (read in place, security-scoped) or a Photos copy (`temporary`,
    /// deleted when no longer needed).
    func use(_ url: URL, temporary: Bool) {
        guard phase != .running else { if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }; return }
        releaseSource()
        let id = UUID(); generation = id
        self.url = url; self.temporary = temporary
        scoped = temporary ? false : url.startAccessingSecurityScopedResource()
        phase = .inspecting; info = nil; result = nil; progress = nil; message = nil
        Task { [self] in
            do {
                let checked = try await VideoImport.inspect(url)
                guard generation == id else { return }
                info = checked; phase = .ready
            } catch {
                guard generation == id else { return }
                info = nil; phase = .rejected; message = Self.text(error)
            }
        }
    }

    func pickFailed(_ text: String) {
        releaseSource(); phase = .idle; message = text
    }

    // MARK: Running

    func start() {
        guard canStart, let url, let info else { return }
        let id = generation
        phase = .running; message = nil; result = nil; cancelReason = nil
        progress = .init(stage: .loadingModel, analyzedSeconds: 0, totalSeconds: info.duration, shots: 0)
        let run = VideoImportRun(storageDirectory: storageDirectory, live: live())
        task = Task { [self] in
            do {
                let session = try await run.run(video: url, info: info, title: VideoImport.title(for: info.filename)) { [weak self] value in
                    guard let self, self.generation == id else { return }
                    self.progress = value
                }
                guard generation == id else { return }
                result = session; phase = .done
                onSaved?(session)
            } catch {
                guard generation == id else { return }
                phase = .ready
                message = error is CancellationError ? (cancelReason ?? courtText("已取消，没有保存记录。")) : Self.text(error)
            }
            task = nil
        }
    }

    /// Stops a run; the unfinished record and its recording are removed.
    func cancel(reason: String? = nil) {
        guard phase == .running else { return }
        cancelReason = reason
        task?.cancel()
    }

    /// The sheet is gone: stop any run and let go of the picked file.
    func close() {
        task?.cancel()
        releaseSource()
    }

    private func releaseSource() {
        if let url {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        url = nil; scoped = false; temporary = false
    }

    private static func text(_ error: Error) -> String {
        if let error = error as? CourtError, case .message(let text) = error { return text }
        return error.localizedDescription
    }

    /// Photos copies are made here and removed after use (or on the next launch's cleanup of tmp).
    nonisolated static var copiesDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VideoImport", isDirectory: true)
    }
}

/// A video picked from Photos, copied into the app's temporary folder.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            // One folder per copy keeps the original file name (it becomes the record's title).
            let folder = VideoImportModel.copiesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}
