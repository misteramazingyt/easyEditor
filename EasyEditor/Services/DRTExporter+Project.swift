import Foundation
import AVFoundation

/// Turn a project into the flat track layout Resolve works in.
///
/// The app's timeline is FCP-shaped: a magnetic storyline with connected clips
/// stacked above and below it. Resolve has no storyline — just V1 upward and
/// A1 downward — so the storyline becomes a video track like any other and the
/// stacking slots fan out around it in the order they are drawn.
///
/// Keyed takes are the reason this exporter exists. Each one needs its matte on
/// the track directly beneath it, the matte set to Lum and the take to
/// Foreground; so a stack level holding any keyed take gets two tracks instead
/// of one, and the matte goes in the lower.
extension DRTExporter {

    /// Frames per second everything is measured in. The same 30 the FCPXML
    /// export uses, so the two describe the same edit.
    static let frameRate: Double = 30

    /// Media paths are only known once the archive has been unpacked, so they
    /// are written as this token and rewritten by `relink.py`. A token rather
    /// than a guess: a wrong-but-plausible path fails silently inside Resolve,
    /// where an obviously fake one does not.
    static let mediaToken = "__EASYEDITOR_MEDIA__"

    struct Package {
        let timeline: Timeline
        /// What could not cross over, for the README.
        let notes: [String]
    }

    static func timeline(for project: VideoProject,
                         media: [UUID: FCPXMLExporter.Media]) async -> Package {
        var sources: [String: Source] = [:]
        var notes: [String] = []

        // One description per file, read from the file itself: Resolve trusts
        // what the pool entry says about a clip rather than re-reading it, so
        // a wrong frame count or resolution here is a wrong clip there.
        for clip in project.clips {
            guard let fileName = clip.fileName, let entry = media[clip.id] else { continue }
            let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            if sources[entry.fileName] == nil {
                sources[entry.fileName] = await source(at: url, named: entry.fileName,
                                                       fallback: entry)
            }
            if let matteName = entry.matteName, sources[matteName] == nil {
                // The matte is rendered beside the take and matches it frame
                // for frame, so it is described the same way.
                var matte = sources[entry.fileName]
                    ?? Source(url: url, name: matteName, directory: mediaToken)
                // Rendered beside the take and stat'd from there.
                matte.url = FilePaths.mediaURL(projectID: project.id,
                                               fileName: matteName)
                matte.name = matteName
                matte.codec = "avc1"
                matte.audio = nil
                sources[matteName] = matte
            }
        }

        func frames(_ seconds: Double) -> Int {
            max(1, Int((seconds * frameRate).rounded()))
        }

        // MARK: Video, bottom to top

        // Stacking slots in drawing order, with the storyline in the middle.
        // Only slots that actually hold visible clips get a track.
        let visible = project.clips.filter {
            $0.kind != .music && $0.kind != .voiceover && $0.kind != .sfx
                && media[$0.id] != nil && $0.isPlaceholder != true
        }
        var video: [[Clip]] = []
        for level in Set(visible.map(\.stackIndex)).sorted() {
            let atLevel = visible.filter { $0.stackIndex == level }
                .sorted { project.start(of: $0) < project.start(of: $1) }
            var mattes: [Clip] = []
            var takes: [Clip] = []
            for clip in atLevel {
                guard let entry = media[clip.id],
                      let source = sources[entry.fileName] else { continue }
                let start = frames(project.start(of: clip))
                let duration = frames(clip.effectiveDuration)
                let keyed = entry.matteName.flatMap { sources[$0] }
                // A take, the matte that keys it and its own audio move
                // together; anything unkeyed with no sound needs no group.
                let group = (keyed != nil || entry.hasAudio) ? clip.id : nil
                takes.append(Clip(source: source, start: start, duration: duration,
                                  mediaStart: frames(clip.trimStart),
                                  composite: keyed == nil
                                      ? DRTBlobs.Composite.normal
                                      : DRTBlobs.Composite.foreground,
                                  group: group))
                if let keyed {
                    mattes.append(Clip(source: keyed, start: start, duration: duration,
                                       mediaStart: frames(clip.trimStart),
                                       composite: DRTBlobs.Composite.lum,
                                       group: group))
                }
            }
            // The matte has to sit under the take it belongs to, so a level
            // that has any gets a track of its own below.
            if !mattes.isEmpty { video.append(mattes) }
            if !takes.isEmpty { video.append(takes) }
        }
        if video.isEmpty { video = [[]] }

        // MARK: Audio

        // A dedicated audio lane becomes a track; so does each level of video
        // whose clips brought sound with them, since in Resolve a clip's audio
        // is a separate item on a separate track.
        var audio: [[Clip]] = []
        let audioLanes = project.clips.filter {
            [.music, .voiceover, .sfx].contains($0.kind) && media[$0.id] != nil
        }
        for level in Set(audioLanes.map(\.stackIndex)).sorted(by: >) {
            let clips = audioLanes.filter { $0.stackIndex == level }
                .sorted { project.start(of: $0) < project.start(of: $1) }
                .compactMap { clip -> Clip? in
                    guard let entry = media[clip.id],
                          var source = sources[entry.fileName] else { return nil }
                    source.isVideo = false
                    return Clip(source: source, start: frames(project.start(of: clip)),
                                duration: frames(clip.effectiveDuration),
                                mediaStart: frames(clip.trimStart))
                }
            if !clips.isEmpty { audio.append(clips) }
        }
        for level in Set(visible.map(\.stackIndex)).sorted() {
            let clips = visible.filter { $0.stackIndex == level }
                .sorted { project.start(of: $0) < project.start(of: $1) }
                .compactMap { clip -> Clip? in
                    guard let entry = media[clip.id], entry.hasAudio,
                          var source = sources[entry.fileName], source.audio != nil else {
                        return nil
                    }
                    // Same file, same pool entry — only the item is separate,
                    // and it belongs to the same group as the picture.
                    source.isVideo = false
                    return Clip(source: source, start: frames(project.start(of: clip)),
                                duration: frames(clip.effectiveDuration),
                                mediaStart: frames(clip.trimStart),
                                group: clip.id)
                }
            if !clips.isEmpty { audio.append(clips) }
        }

        // MARK: What stayed behind

        // Only what the .drt drops and the FCPXML keeps — everything both
        // formats lose is listed once, by the packager.
        if project.clips.contains(where: { $0.speed != 1 }) {
            notes.append("Clip speed rides in the FCPXML, not the .drt; in the .drt the "
                         + "clips come in at their trimmed length, at normal speed.")
        }
        if project.clips.contains(where: { $0.volume != 1 || $0.isMuted }) {
            notes.append("Clip volume and mutes ride in the FCPXML, not the .drt.")
        }

        let render = project.aspect.renderSize
        return Package(
            timeline: Timeline(name: project.name, width: Int(render.width),
                               height: Int(render.height), rate: frameRate,
                               video: video, audio: audio),
            notes: notes)
    }

    /// Read what Resolve needs to know about one file.
    private static func source(at url: URL, named name: String,
                               fallback: FCPXMLExporter.Media) async -> Source {
        var source = Source(url: url, name: name, directory: mediaToken)
        source.width = Int(fallback.size.width)
        source.height = Int(fallback.size.height)
        source.rate = frameRate
        source.frames = max(1, Int((fallback.duration * frameRate).rounded()))
        source.byteSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0

        // A still has no video track to read, and Resolve wants it described
        // as one frame rather than as however long the app holds it for.
        if fallback.clip.kind == .image {
            source.isStill = true
            source.frames = 1
            return source
        }

        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                source.rate = Double(rate)
            }
            if let duration = try? await asset.load(.duration).seconds, duration > 0 {
                source.frames = max(1, Int((duration * source.rate).rounded()))
            }
            source.codec = await fourCC(of: track) ?? "avc1"
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first {
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            var audio = Source.Audio()
            audio.sampleRate = Int(basic?.mSampleRate ?? 48_000)
            audio.channels = Int(basic?.mChannelsPerFrame ?? 2)
            let duration = (try? await asset.load(.duration).seconds) ?? fallback.duration
            audio.samples = Int(duration * Double(audio.sampleRate))
            audio.codec = name.lowercased().hasSuffix(".wav") ? "Linear PCM" : "AAC"
            source.audio = audio
        }
        return source
    }

    /// Resolve names a codec by its four-character code, which is what the
    /// format description carries.
    private static func fourCC(of track: AVAssetTrack) async -> String? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)
    }
}
