import Foundation

/// Centralized, lazily-created locations for all on-disk app data.
/// Everything lives under the app's Documents directory so it survives launches.
enum FilePaths {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var projectsDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("Projects", isDirectory: true))
    }

    static var projectsStoreURL: URL {
        documentsDirectory.appendingPathComponent("projects.json")
    }

    /// Per-project media directory (imported videos/images/audio, voiceovers).
    static func mediaDirectory(projectID: UUID) -> URL {
        ensure(projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true))
    }

    static func mediaURL(projectID: UUID, fileName: String) -> URL {
        mediaDirectory(projectID: projectID).appendingPathComponent(fileName)
    }

    static var exportsDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("Exports", isDirectory: true))
    }

    /// Generated (synthesized) sound-effect files, shared across projects.
    static var sfxDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("SFX", isDirectory: true))
    }

    static var tempDirectory: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent("EasyEditor", isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
