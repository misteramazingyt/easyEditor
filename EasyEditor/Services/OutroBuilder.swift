import Foundation
import AVFoundation

/// The house outros. Each is a single portrait animation on black, laid over
/// the end of the timeline with a screen blend — black screens to nothing, so
/// the animation floats over the footage with no keying and no matte.
///
/// The media lives on the web rather than in the app bundle, so the build
/// stays small and a re-cut outro reaches every install without shipping a new
/// IPA. It's fetched into the project the first time you insert it.
enum OutroStyle: String, CaseIterable, Identifiable {
    case exciting, mystical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exciting: return "Exciting"
        case .mystical: return "Mystical"
        }
    }

    var subtitle: String {
        switch self {
        case .exciting: return "Retro logo build with the sting"
        case .mystical: return "Slow write-on"
        }
    }

    var systemImage: String {
        switch self {
        case .exciting: return "sparkles"
        case .mystical: return "moon.stars"
        }
    }

    var remoteURL: URL {
        switch self {
        case .exciting:
            return URL(string: "https://file.garden/adsy8IqfImsnsZZL/misteramazingOutro916.mp4")!
        case .mystical:
            return URL(string: "https://file.garden/adsy8IqfImsnsZZL/outro_writeon_916_fast.mp4")!
        }
    }

    var fileName: String { "outro-" + rawValue + ".mp4" }
}

enum OutroBuilder {

    enum BuildError: LocalizedError {
        case downloadFailed(String)
        case unplayable

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason):
                return "Couldn't download the outro: \(reason)"
            case .unplayable:
                return "The downloaded outro couldn't be read."
            }
        }
    }

    struct Result {
        var project: VideoProject
        /// Where to park the playhead so the outro is visible straight away.
        var jumpTo: Double
    }

    /// Lay the chosen outro over the end of the timeline. It keeps its own
    /// audio and finishes exactly where the storyline does, so nothing gets
    /// longer unless the timeline is shorter than the animation itself.
    static func appendOutro(_ style: OutroStyle, to project: VideoProject) async throws -> Result {
        var project = project
        let media = FilePaths.mediaDirectory(projectID: project.id)
        let destination = media.appendingPathComponent(style.fileName)

        if !FileManager.default.fileExists(atPath: destination.path) {
            try await download(style.remoteURL, to: destination)
        }

        let asset = AVURLAsset(url: destination)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        guard length > 0.1 else {
            // A truncated or error-page download would sit here forever.
            try? FileManager.default.removeItem(at: destination)
            throw BuildError.unplayable
        }

        let end = project.duration
        let offset = max(0, end - length)

        var clip = TimelineClip(kind: .video, lane: .broll, fileName: style.fileName,
                                assetDuration: length, trimStart: 0, trimEnd: length,
                                offset: offset)
        clip.laneIndex = max(1, project.maxStackAbove + 1)   // above everything
        clip.blend = .screen                                 // black drops out
        clip.isMuted = false                                 // the cue comes with it
        project.append(clip)

        return Result(project: project, jumpTo: offset)
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        do {
            // download(from:) streams to disk — no 9 MB sitting in memory.
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: temporary)
                throw BuildError.downloadFailed("server said \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as BuildError {
            throw error
        } catch {
            throw BuildError.downloadFailed(error.localizedDescription)
        }
    }
}
