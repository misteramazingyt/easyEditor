import Foundation
import AppleArchive
import System

/// Imports a GreenDeck `.gdproj` package (Apple Archive, lzfse) shared from
/// the GreenDeck app: extracts it, reads `manifest.json`, and builds a
/// VideoProject with the clips on the primary storyline in packaged order.
/// Contract: HANDOFF-greendeck-project-import.md (manifest version 1).
enum GreenDeckImportService {

    struct Manifest: Decodable {
        struct Clip: Decodable {
            let fileName: String
            let duration: Double?
            let recordedAt: Date?
            let notes: String?
        }
        let format: String
        let version: Int
        let name: String
        let exportedAt: Date?
        let clips: [Clip]
    }

    struct Result {
        let project: VideoProject
        let imported: Int
        let skipped: Int
    }

    enum ImportError: LocalizedError {
        case badArchive
        case missingManifest
        case wrongFormat
        case noClips

        var errorDescription: String? {
            switch self {
            case .badArchive:
                return "That file couldn't be opened as a GreenDeck project."
            case .missingManifest:
                return "The package has no readable manifest."
            case .wrongFormat:
                return "That package isn't a GreenDeck project."
            case .noClips:
                return "No importable clips were found in the package."
            }
        }
    }

    /// Extract, validate, and build. Consumes (deletes) the archive on
    /// success or failure — it's a copy in Documents/Inbox.
    static func importProject(from archiveURL: URL) async throws -> Result {
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { archiveURL.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let stagingDir = FilePaths.tempDirectory
            .appendingPathComponent("gdproj-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        try extract(archiveURL, to: stagingDir)

        let manifestURL = stagingDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ImportError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw ImportError.missingManifest
        }
        guard manifest.format == "greendeck-project" else {
            throw ImportError.wrongFormat
        }
        // version > 1: import what we understand (per the handoff contract).

        var project = VideoProject(name: manifest.name.isEmpty ? "GreenDeck Project" : manifest.name)
        let importer = MediaImportService()
        var imported = 0
        var skipped = 0

        // Storyline order = manifest array order; durations re-probed.
        for clip in manifest.clips {
            let extracted = stagingDir.appendingPathComponent(clip.fileName)
            guard FileManager.default.fileExists(atPath: extracted.path),
                  let media = await importer.importVideoFile(extracted,
                                                            projectID: project.id,
                                                            deleteSource: true),
                  case .video(let fileName, let duration) = media else {
                skipped += 1
                continue
            }
            project.append(.video(fileName: fileName, duration: duration,
                                  order: project.nextPrimaryOrder))
            imported += 1
        }
        guard imported > 0 else {
            // Remove any media dir the failed import may have created.
            ProjectStore().deleteMedia(projectID: project.id)
            throw ImportError.noClips
        }
        return Result(project: project, imported: imported, skipped: skipped)
    }

    /// Mirror of GreenDeck's ProjectHandoffService archiver (Apple Archive,
    /// lzfse) — it is NOT a zip.
    private static func extract(_ archive: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let readStream = ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []),
              let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream),
              let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream),
              let extractStream = ArchiveStream.extractStream(
                extractingTo: FilePath(dir.path), flags: [.ignoreOperationNotPermitted])
        else { throw ImportError.badArchive }
        defer { try? readStream.close() }
        defer { try? decompressStream.close() }
        defer { try? decodeStream.close() }
        defer { try? extractStream.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            throw ImportError.badArchive
        }
    }
}
