import Foundation
import AVFoundation
import CoreImage

/// Appends the house outro: a staggered four-element build where the music
/// arrives before anything visibly happens, ink floods the picture from a
/// corner, the logo animation screens over it, and the whole thing lands on
/// flat black.
///
/// Timings were measured off the reference render — they are the house look,
/// not parameters. Tune them here rather than exposing sliders.
enum OutroBuilder {

    // Offsets from T = the end of the storyline before the outro is added.
    private static let stingLead = 2.68        // sting starts here, under the tail
    private static let inkLead = 1.60
    private static let animationLead = 0.81
    private static let inkDuration = 2.03
    private static let animationDuration = 3.48
    private static let blackDuration = 2.75
    private static let stingTrimStart = 6.00   // only the tail of the cue is used
    private static let stingTrimEnd = 10.16
    private static let stingFadeIn = 1.80
    private static let stingVolume = 0.19      // −14.3 dB under the programme

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
        /// Where to park the playhead so the user sees what happened.
        var jumpTo: Double
    }

    /// Build the outro onto a copy of `project`. All four clips share one
    /// groupID, so the timeline treats them as a single object.
    static func appendOutro(to project: VideoProject) async throws -> Result {
        var project = project
        let media = FilePaths.mediaDirectory(projectID: project.id)

        let inkName = try stageAsset("ink-flood-matte", ext: "mp4",
                                     as: "outro-ink.mp4", in: media)
        let animationName = try stageAsset("retro-animation", ext: "mp4",
                                           as: "outro-animation.mp4", in: media)
        let stingName = try stageAsset("retro-sting", ext: "mp3",
                                       as: "outro-sting.mp3", in: media)

        // Black is generated so it matches whatever canvas the project uses.
        let size = project.aspect.renderSize
        let blackName = "outro-black-\(Int(size.width))x\(Int(size.height)).mov"
        let blackURL = media.appendingPathComponent(blackName)
        if !FileManager.default.fileExists(atPath: blackURL.path) {
            try await MediaProcessingService.writeSolidColorVideo(
                color: CIColor(red: 0, green: 0, blue: 0),
                size: size, length: blackDuration, to: blackURL)
        }

        // Probe rather than trusting the table, and never trim past the media.
        let inkLength = await duration(of: media.appendingPathComponent(inkName),
                                       fallback: inkDuration)
        let animationLength = await duration(of: media.appendingPathComponent(animationName),
                                             fallback: animationDuration)
        let stingLength = await duration(of: media.appendingPathComponent(stingName),
                                         fallback: stingTrimEnd)
        let blackLength = await duration(of: blackURL, fallback: blackDuration)

        let T = project.duration
        let group = UUID()

        // Ink — multiply: white is a no-op, black is the ink. No keying needed.
        var ink = TimelineClip(kind: .video, lane: .broll, fileName: inkName,
                               assetDuration: inkLength, trimStart: 0,
                               trimEnd: min(inkDuration, inkLength),
                               offset: max(0, T - inkLead))
        ink.laneIndex = 1
        ink.blend = .multiply
        ink.isMuted = true
        // Landscape master: a quarter turn covers a portrait canvas.
        ink.rotationQuarterTurns = project.aspect == .portrait916 ? 1 : 0
        ink.groupID = group

        // Animation — screen: black is a no-op, so the logo floats over the
        // ink and then sits on the black canvas looking unblended.
        var animation = TimelineClip(kind: .video, lane: .broll, fileName: animationName,
                                     assetDuration: animationLength, trimStart: 0,
                                     trimEnd: min(animationDuration, animationLength),
                                     offset: max(0, T - animationLead))
        animation.laneIndex = 2
        animation.blend = .screen
        animation.isMuted = true
        animation.groupID = group

        var sting = TimelineClip(kind: .music, lane: .music, fileName: stingName,
                                 assetDuration: stingLength,
                                 trimStart: min(stingTrimStart, max(0, stingLength - 0.5)),
                                 trimEnd: min(stingTrimEnd, stingLength),
                                 offset: max(0, T - stingLead))
        sting.laneIndex = -2
        sting.volume = stingVolume
        sting.fadeIn = stingFadeIn
        sting.groupID = group

        var black = TimelineClip.video(fileName: blackName, duration: blackLength,
                                       order: project.nextPrimaryOrder)
        black.trimEnd = min(blackDuration, blackLength)
        black.isMuted = true
        black.groupID = group

        // Black last: it becomes the final storyline clip, and the connected
        // members are already positioned against T.
        project.append(ink)
        project.append(animation)
        project.append(sting)
        project.append(black)

        return Result(project: project, jumpTo: max(0, T - stingLead))
    }

    /// Copy a bundled asset into the project's media directory once.
    private static func stageAsset(_ resource: String, ext: String,
                                   as fileName: String, in media: URL) throws -> String {
        let destination = media.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return fileName
        }
        guard let source = Bundle.main.url(forResource: resource, withExtension: ext) else {
            throw BuildError.missingAsset("\(resource).\(ext)")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return fileName
    }

    private static func duration(of url: URL, fallback: Double) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else {
            return fallback
        }
        return seconds
    }
}
