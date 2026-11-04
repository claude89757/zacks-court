import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import CourtCore

/// A record's diagnostic package for the share sheet: built only when a destination is picked (the
/// record JSON, its logs, the camera's capture logs around it and a summary, zipped; no video).
struct DiagnosticPackage: Transferable, Sendable {
    let session: CourtSession
    let storageDirectory: URL

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Zacks Court Diagnostics", isDirectory: true) }
    /// Removes packages left from earlier shares (called when the app starts).
    static func clearLeftovers() { try? FileManager.default.removeItem(at: folder) }

    func build() throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        return try DiagnosticBundle.build(session: session, storageDirectory: storageDirectory, into: Self.folder)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { package in SentTransferredFile(try package.build()) }
    }
}
