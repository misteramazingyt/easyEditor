import Foundation
import AVFoundation

/// Write a project out as FCPXML, which DaVinci Resolve reads.
///
/// Version 1.8 on purpose: it is the dialect Resolve is happiest with, and
/// nothing here needs anything newer. Times are rational numbers over a 600
/// timebase — FCPXML insists on exact arithmetic, and 600 divides 24, 25 and
/// 30 cleanly, so nothing lands between frames.
///
/// What crosses over: the storyline in order, every connected video, image and
/// audio clip on its own lane, with trims, speed and per-clip volume. What
/// does not: titles, filters, LUTs, masks, the aesthetic treatment and the
/// animation — Resolve has its own versions of all of those and no way to
/// receive ours, so they are listed in the README rather than silently lost.
enum FCPXMLExporter {

    private static let timebase = 600
    /// Spelled out rather than escaped: this file builds strings inside
    /// strings, and one more backslash is one more thing to get wrong.
    private static let newline = String(UnicodeScalar(10))

    /// FCPXML time: a rational number of seconds.
    private static func time(_ seconds: Double) -> String {
        let value = Int((seconds * Double(timebase)).rounded())
        return value == 0 ? "0s" : "\(value)/\(timebase)s"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    struct Media {
        let clip: TimelineClip
        let fileName: String
        let size: CGSize
        let duration: Double
        let hasVideo: Bool
        let hasAudio: Bool
        /// A keyed take, whose alpha travels beside it as a matte movie.
        var matteName: String?
    }

    /// Everything the XML needs to know about the files, read once.
    static func gather(project: VideoProject) async -> [UUID: Media] {
        var result: [UUID: Media] = [:]
        for clip in project.clips {
            guard let fileName = clip.fileName else { continue }
            let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if clip.kind == .image {
                let size = imageSize(at: url) ?? CGSize(width: 1080, height: 1920)
                // A still can be held for as long as you like, so the asset
                // has to be long enough for any clip cut from it — its own
                // clip length is not a ceiling the importer should inherit.
                result[clip.id] = Media(clip: clip, fileName: exportName(for: fileName),
                                        size: size, duration: 3600,
                                        hasVideo: true, hasAudio: false)
                continue
            }
            let asset = AVURLAsset(url: url)
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            var size = CGSize(width: 1920, height: 1080)
            if let video, let natural = try? await video.load(.naturalSize),
               let transform = try? await video.load(.preferredTransform) {
                let turned = abs(transform.b) == 1 && abs(transform.c) == 1
                size = turned ? CGSize(width: natural.height, height: natural.width) : natural
            }
            let duration = (try? await asset.load(.duration).seconds) ?? clip.assetDuration
            let keyed = await MatteExporter.hasAlpha(url: url)
            result[clip.id] = Media(clip: clip, fileName: exportName(for: fileName),
                                    size: size, duration: max(0.1, duration),
                                    hasVideo: video != nil, hasAudio: audio != nil,
                                    matteName: keyed ? MatteExporter.matteName(for: fileName) : nil)
        }
        return result
    }

    /// What the file is called inside the archive.
    ///
    /// Resolve reads a still whose name ends in digits as one frame of an
    /// image sequence and goes looking for its siblings — a single jpg came in
    /// as "name[6-125].jpg", 120 frames of nothing. A trailing letter is
    /// enough to stop it guessing.
    static func exportName(for fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension.lowercased()
        let stills: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif"]
        guard stills.contains(ext) else { return fileName }
        let base = url.deletingPathExtension().lastPathComponent
        guard let last = base.last, last.isNumber else { return fileName }
        return "\(base)-still.\(url.pathExtension)"
    }

    private static func imageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Build the document. `mediaFolder` is what the `src` paths are relative
    /// to once the archive has been unpacked.
    static func xml(for project: VideoProject, media: [UUID: Media],
                    mediaFolder: String = "Media") -> String {
        let render = project.aspect.renderSize
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.8">
          <resources>
            <format id="r0" name="EasyEditorFormat" frameDuration="20/600s" \
        width="\(Int(render.width))" height="\(Int(render.height))" \
        colorSpace="1-1-1 (Rec. 709)"/>

        """

        // One asset per file, and one format per distinct frame size: Resolve
        // uses the asset's own format to decide how to fit it into the
        // timeline, so a clip that is not the project's shape keeps its shape.
        var assetIDs: [UUID: String] = [:]
        var formatIDs: [String: String] = [:]
        var formats = ""
        var assets = ""
        var next = 1
        for clip in project.clips {
            guard let entry = media[clip.id] else { continue }
            let key = "\(Int(entry.size.width))x\(Int(entry.size.height))"
            let formatID: String
            if let existing = formatIDs[key] {
                formatID = existing
            } else if key == "\(Int(render.width))x\(Int(render.height))" {
                formatID = "r0"
                formatIDs[key] = formatID
            } else {
                formatID = "f\(next)"
                next += 1
                formatIDs[key] = formatID
                formats += """
                    <format id="\(formatID)" name="EasyEditor\(key)" frameDuration="20/600s" \
                width="\(Int(entry.size.width))" height="\(Int(entry.size.height))" \
                colorSpace="1-1-1 (Rec. 709)"/>

                """
            }
            let assetID = "a\(next)"
            next += 1
            assetIDs[clip.id] = assetID
            let src = "./\(mediaFolder)/\(entry.fileName)"
            assets += """
                <asset id="\(assetID)" name="\(escape(entry.fileName))" \
            src="\(escape(src))" start="0s" duration="\(time(entry.duration))" \
            hasVideo="\(entry.hasVideo ? 1 : 0)" hasAudio="\(entry.hasAudio ? 1 : 0)" \
            format="\(formatID)"\(entry.hasAudio ? " audioSources=\"1\" audioChannels=\"2\"" : "")/>

            """
        }
        // A keyed take and its matte belong together, so each becomes a
        // compound clip holding both: the colour on the spine, the matte on
        // the lane above it. FCPXML has no way to say "use that as alpha" --
        // no interchange format does -- so the wiring stays a step you take in
        // Resolve. But you take it once, inside the compound, and every use of
        // that compound on the timeline inherits it.
        var compoundIDs: [UUID: String] = [:]
        var compounds = ""
        for clip in project.clips {
            guard let entry = media[clip.id], let matteName = entry.matteName,
                  let colourID = assetIDs[clip.id], compoundIDs[clip.id] == nil else { continue }
            let matteID = "a\(next)"
            next += 1
            assets += matteAsset(id: matteID, name: matteName,
                                 src: "./\(mediaFolder)/\(matteName)",
                                 duration: entry.duration)
            let compoundID = "m\(next)"
            next += 1
            compoundIDs[clip.id] = compoundID
            compounds += compound(id: compoundID, colourID: colourID, matteID: matteID,
                                  entry: entry, matteName: matteName)
        }
        out += formats + assets + compounds
        out += "  </resources>\n"

        // MARK: The timeline

        let duration = max(1, project.duration)
        out += """
          <library>
            <event name="EasyEditor">
              <project name="\(escape(project.name))">
                <sequence format="r0" duration="\(time(duration))" tcStart="0s" \
        tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>

        """

        // FCPXML hangs connected clips off a spine element, and a connected
        // clip that lands outside every spine element has nowhere to go — it
        // is silently dropped. A storyline is rarely long enough to cover a
        // project on its own (ours is often one black placeholder holding a
        // few seconds open), so the spine is filled out with gaps until it
        // spans the whole timeline. Then everything has a host.
        struct Host {
            let clip: TimelineClip?     // nil = a gap
            let start: Double           // on the timeline
            let duration: Double
            var end: Double { start + duration }
            /// The host's own in-point, which is the base its children's
            /// offsets are measured from.
            var innerStart: Double { clip.map { $0.isPlaceholder == true ? 0 : $0.trimStart } ?? 0 }
        }

        let starts = project.primaryStartTimes
        var hosts: [Host] = []
        var cursor = 0.0
        for clip in project.primaryClips {
            let clipStart = starts[clip.id] ?? cursor
            if clipStart - cursor > 0.001 {
                hosts.append(Host(clip: nil, start: cursor, duration: clipStart - cursor))
            }
            // A placeholder is scaffolding holding time open, not footage.
            // Exported as a gap it does the same job without laying a black
            // rectangle under everything.
            if clip.isPlaceholder == true || media[clip.id] == nil {
                hosts.append(Host(clip: nil, start: clipStart, duration: clip.effectiveDuration))
            } else {
                hosts.append(Host(clip: clip, start: clipStart, duration: clip.effectiveDuration))
            }
            cursor = clipStart + clip.effectiveDuration
        }
        if duration - cursor > 0.001 {
            hosts.append(Host(clip: nil, start: cursor, duration: duration - cursor))
        }
        if hosts.isEmpty {
            hosts = [Host(clip: nil, start: 0, duration: duration)]
        }

        let connected = project.clips
            .filter { $0.lane != .primary && media[$0.id] != nil }
            .sorted { project.start(of: $0) < project.start(of: $1) }

        for (index, host) in hosts.enumerated() {
            let isLast = index == hosts.count - 1
            var children = ""
            for other in connected {
                let otherStart = project.start(of: other)
                // Belongs to the host it starts inside; anything running past
                // the end of the timeline lands on the last one.
                let inside = otherStart >= host.start - 0.001
                    && (otherStart < host.end - 0.001 || (isLast && otherStart >= host.start))
                guard inside else { continue }
                children += element(for: other, media: media, assetIDs: assetIDs,
                                    compoundIDs: compoundIDs,
                                    // A child's offset is in its host's own
                                    // time base, which begins at the host's
                                    // in-point — not at zero.
                                    offset: host.innerStart + (otherStart - host.start),
                                    indent: 10)
            }
            if let clip = host.clip {
                out += element(for: clip, media: media, assetIDs: assetIDs,
                               compoundIDs: compoundIDs,
                               offset: host.start, indent: 8, children: children)
            } else {
                let attributes = "name=\"Gap\" offset=\"\(time(host.start))\" "
                    + "start=\"0s\" duration=\"\(time(host.duration))\""
                let open = "        <gap \(attributes)"
                out += children.isEmpty
                    ? open + "/>" + newline
                    : open + ">" + newline + children + "        </gap>" + newline
            }
        }

        out += """
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
        return out
    }

    /// One clip. Storyline clips carry their timeline offset; connected ones
    /// carry an offset from the clip they hang on, plus the lane they sit in.
    private static func element(for clip: TimelineClip, media: [UUID: Media],
                                assetIDs: [UUID: String], compoundIDs: [UUID: String],
                                offset: Double, indent: Int,
                                children: String = "") -> String {
        guard let entry = media[clip.id] else { return "" }
        let pad = String(repeating: " ", count: indent)
        // A keyed take is placed as its compound; everything else as itself.
        let compoundID = compoundIDs[clip.id]
        guard let ref = compoundID ?? assetIDs[clip.id] else { return "" }
        let tag = compoundID != nil ? "ref-clip" : (entry.hasVideo ? "asset-clip" : "audio")
        var attributes = "ref=\"\(ref)\" offset=\"\(time(offset))\""
        attributes += " name=\"\(escape(entry.fileName))\""
        attributes += " start=\"\(time(clip.trimStart))\""
        attributes += " duration=\"\(time(clip.effectiveDuration))\""
        if clip.lane != .primary {
            attributes += " lane=\"\(clip.stackIndex)\""
        }
        var body = children
        // Speed is a time map in FCPXML: the clip's own time against the
        // timeline's, as two points.
        if clip.speed != 1, clip.kind == .video {
            let source = clip.trimEnd - clip.trimStart
            body += """
            \(pad)  <timeMap>
            \(pad)    <timept time="0s" value="0s" interp="linear"/>
            \(pad)    <timept time="\(time(clip.effectiveDuration))" value="\(time(source))" interp="linear"/>
            \(pad)  </timeMap>

            """
        }
        if clip.volume != 1 || clip.isMuted {
            let level = clip.isMuted ? 0 : clip.volume
            body += "\(pad)  <adjust-volume amount=\"\(String(format: "%.2f", level))\"/>\n"
        }
        if body.isEmpty {
            return "\(pad)<\(tag) \(attributes)/>\n"
        }
        return "\(pad)<\(tag) \(attributes)>\n\(body)\(pad)</\(tag)>\n"
    }

    /// The greyscale companion that carries a keyed take's alpha.
    private static func matteAsset(id: String, name: String, src: String,
                                   duration: Double) -> String {
        "    <asset id=\"\(id)\" name=\"\(escape(name))\" src=\"\(escape(src))\" "
            + "start=\"0s\" duration=\"\(time(duration))\" hasVideo=\"1\" hasAudio=\"0\" "
            + "format=\"r0\"/>" + newline
    }

    /// A take and its matte as one compound clip, named after the recording.
    private static func compound(id: String, colourID: String, matteID: String,
                                 entry: Media, matteName: String) -> String {
        let name = URL(fileURLWithPath: entry.fileName)
            .deletingPathExtension().lastPathComponent
        let span = time(entry.duration)
        var out = "    <media id=\"\(id)\" name=\"\(escape(name))\">" + newline
        out += "      <sequence format=\"r0\" duration=\"\(span)\" tcStart=\"0s\" "
            + "tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">" + newline
        out += "        <spine>" + newline
        out += "          <asset-clip ref=\"\(colourID)\" offset=\"0s\" "
            + "name=\"\(escape(entry.fileName))\" start=\"0s\" duration=\"\(span)\">" + newline
        out += "            <asset-clip ref=\"\(matteID)\" lane=\"1\" offset=\"0s\" "
            + "name=\"\(escape(matteName))\" start=\"0s\" duration=\"\(span)\"/>" + newline
        out += "          </asset-clip>" + newline
        out += "        </spine>" + newline
        out += "      </sequence>" + newline
        out += "    </media>" + newline
        return out
    }
}
