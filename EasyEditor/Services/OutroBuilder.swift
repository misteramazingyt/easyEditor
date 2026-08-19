import Foundation
import AVFoundation

/// The house outros. Each is a single portrait animation on black, laid over
/// the end of the timeline with a screen blend — black screens to nothing, so
/// the animation floats over the footage with no keying and no matte.
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

    /// Bundled resource, and the name it takes inside a project's media dir.
    var resource: String {
        switch self {
        case .exciting: return "outro-exciting"
        case .mystical: return "outro-mystical"
        }
    }

    var fileName: String { resource + ".mp4" }
}

enum OutroBuilder {

    enum BuildError: LocalizedError {
        case missingAsset(String)

        var errorDescription: String? {
            switch self {
            case .missingAsset(let name):
                return "The outro asset “\(name)” is missing from the app bundle."
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
            guard let source = Bundle.main.url(forResource: style.resource, withExtension: "mp4") else {
                throw BuildError.missingAsset(style.fileName)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let asset = AVURLAsset(url: destination)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        guard length > 0.1 else { throw BuildError.missingAsset(style.fileName) }

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
}
