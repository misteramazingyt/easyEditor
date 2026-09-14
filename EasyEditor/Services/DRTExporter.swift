import Foundation

/// Write a project out as a DaVinci Resolve timeline (.drt).
///
/// Why not FCPXML alone: no interchange format carries a composite mode, and
/// the composite mode is the whole trick that puts a keyed take's transparency
/// back — the matte set to Lum on the track below, the take above it set to
/// Foreground. Resolve's own .drt does carry it, so this writes one, and the
/// key comes in already made rather than needing a script run afterwards.
///
/// The format is not documented. Everything here was worked out by reading
/// files Resolve exported and checking what came back on import: the blob
/// serialisations live in `DRTBlobs`, the fixed scaffolding in the three XML
/// files bundled beside the app. Project-level settings ride along from that
/// template unchanged; everything that varies with the edit is generated.
///
/// The FCPXML export stays in the box beside this one. It is the readable,
/// documented format, and if a future Resolve stops reading what we write, it
/// is still a working way in.
enum DRTExporter {

    /// Anything Resolve treats as media has a stamp and a shape.
    struct Source: Equatable {
        /// The file on this device — where the shape and the stamp are read
        /// from.
        var url: URL
        var name: String
        /// The folder the file will be in once the archive is unpacked, which
        /// is not known here. Written into the timeline as it stands and
        /// rewritten by `relink.py`.
        var directory: String
        var isVideo = true
        /// A still is not a one-frame video: Resolve names no codec for it,
        /// writes one frame, and gives it a time map that lets the frame be
        /// held for any length. Claiming otherwise sends Resolve looking for
        /// frames that are not there, and the clip comes in offline.
        var isStill = false
        var width = 1080
        var height = 1920
        /// Length of the source media in frames, at `rate`.
        var frames = 0
        var rate: Double = 30
        /// The video codec's four-character code, as Resolve names it.
        var codec = "avc1"
        /// The file's size on disk, which is what a still's frame size is.
        var byteSize = 0
        var audio: Audio?

        struct Audio: Equatable {
            var sampleRate = 48_000
            var channels = 2
            /// Length of the source audio in samples, not frames.
            var samples = 0
            var codec = "AAC"
        }
    }

    /// One thing on one track.
    struct Clip {
        var source: Source
        /// Where it starts on the timeline, and how long it runs, in frames.
        var start: Int
        var duration: Int
        /// Where in the source media it starts, in frames.
        var mediaStart = 0
        /// Resolve's Composite Mode; 0 leaves the clip alone.
        var composite = DRTBlobs.Composite.normal
        /// Clips sharing a group move together on the timeline, the way
        /// Resolve links a clip's own picture and sound. A take, the matte
        /// that keys it, and its audio are one group.
        var group: UUID?
    }

    struct Timeline {
        var name: String
        var width: Int
        var height: Int
        var rate: Double
        /// Bottom to top: the first is V1.
        var video: [[Clip]]
        /// Likewise A1 upward.
        var audio: [[Clip]] = []
    }

    enum Failure: LocalizedError {
        case templateMissing

        var errorDescription: String? {
            switch self {
            case .templateMissing:
                return "The Resolve timeline template is missing from the app."
            }
        }
    }

    // MARK: - Building

    static func write(_ timeline: Timeline, to url: URL) throws {
        let data = try archive(timeline)
        try data.write(to: url, options: .atomic)
    }

    static func archive(_ timeline: Timeline) throws -> Data {
        guard var pool = resource("drt-mpfolder"),
              var sequence = resource("drt-sequence"),
              let project = resource("drt-project") else {
            throw Failure.templateMissing
        }

        let folder = match(#"<Sm2MpFolder DbId="([^"]+)""#, in: pool) ?? newID()
        // Two different identities: the tracks point at the Sm2Sequence, while
        // the file itself is named after the container that holds it.
        let sequenceID = match("<Sequence>([^<]+)</Sequence>", in: sequence) ?? newID()
        let containerID = match(#"<Sm2SequenceContainer DbId="([^"]+)""#, in: sequence) ?? newID()

        // MARK: Media pool — one entry per distinct file

        var entries = ""
        var refs: [URL: String] = [:]
        for track in timeline.video + timeline.audio {
            for clip in track where refs[clip.source.url] == nil {
                let id = newID()
                refs[clip.source.url] = id
                entries += poolEntry(clip.source, id: id, folder: folder)
            }
        }
        pool = replaceMediaVec(in: pool, with: entries)

        // MARK: Tracks

        // Every item needs its identity before any link can name it, so they
        // are handed out in one pass and the groups resolved in the next.
        var identities: [[String]] = []
        var members: [UUID: [String]] = [:]
        for track in timeline.video + timeline.audio {
            var row: [String] = []
            for clip in track {
                let id = newID()
                row.append(id)
                if let group = clip.group { members[group, default: []].append(id) }
            }
            identities.append(row)
        }
        /// The others in this clip's group — what its FieldsBlob names.
        func partners(of clip: Clip, _ id: String) -> [String] {
            guard let group = clip.group else { return [] }
            return (members[group] ?? []).filter { $0 != id }
        }

        var videoVec = "<VideoTrackVec>\n"
        for (index, clips) in timeline.video.enumerated() {
            var items = ""
            for (position, clip) in clips.enumerated() {
                let id = identities[index][position]
                items += "\n" + videoItem(clip, id: id, ref: refs[clip.source.url] ?? "",
                                          partners: partners(of: clip, id))
            }
            videoVec += track(fields: Fixed.trackFields, type: 0,
                              // V1 carries a subtype Resolve reads as the base
                              // video track; the rest are plain.
                              subType: index == 0 ? 1_354_633_184 : 0,
                              sequence: sequenceID, items: items)
        }
        videoVec += " </VideoTrackVec>"

        var audioVec = "<AudioTrackVec/>"
        if !timeline.audio.isEmpty {
            audioVec = "<AudioTrackVec>\n"
            for (index, clips) in timeline.audio.enumerated() {
                var items = ""
                for (position, clip) in clips.enumerated() {
                    let id = identities[timeline.video.count + index][position]
                    items += "\n" + audioItem(clip, id: id,
                                              ref: refs[clip.source.url] ?? "",
                                              rate: timeline.rate,
                                              partners: partners(of: clip, id))
                }
                audioVec += track(fields: Fixed.audioTrackFields, type: 1, subType: 0,
                                  sequence: sequenceID, items: items)
            }
            audioVec += " </AudioTrackVec>"
        }

        sequence = replace(#"<VideoTrackVec>[\s\S]*?</VideoTrackVec>|<VideoTrackVec/>"#,
                           in: sequence, with: videoVec)
        sequence = replace(#"<AudioTrackVec>[\s\S]*?</AudioTrackVec>|<AudioTrackVec/>"#,
                           in: sequence, with: audioVec)

        // MARK: Identity

        // The timeline is identified by name as well as by id, and the name is
        // written twice — on the media pool entry and on the Sm2Timeline
        // inside it. Leave either behind and Resolve recognises a timeline it
        // already has, and the import quietly does nothing.
        let templateName = match(
            "<Sm2MpTimelineClip[^>]*>\\s*<FieldsBlob>[0-9a-fA-F]*</FieldsBlob>\\s*<Name>([^<]*)",
            in: pool) ?? "EasyEditor"
        pool = pool.replacingOccurrences(of: "<Name>\(templateName)</Name>",
                                         with: "<Name>\(escape(timeline.name))</Name>")
        if let old = match("<Resolution>([0-9a-fA-F]+)</Resolution>", in: pool) {
            let fresh = DRTBlobs.resolution(width: timeline.width,
                                            height: timeline.height).hexadecimal
            pool = pool.replacingOccurrences(of: "<Resolution>\(old)</Resolution>",
                                             with: "<Resolution>\(fresh)</Resolution>")
        }
        if let old = match("<FrameRate>([0-9a-fA-F]+)</FrameRate>", in: pool) {
            let fresh = DRTBlobs.frameRate(timeline.rate).hexadecimal
            pool = pool.replacingOccurrences(of: "<FrameRate>\(old)</FrameRate>",
                                             with: "<FrameRate>\(fresh)</FrameRate>")
        }

        // Every identity carried over from the template has to be replaced, or
        // Resolve matches the timeline to one it already holds. Remapping
        // consistently keeps every cross-reference intact while making the
        // whole thing new.
        var files = ["project.xml": project,
                     "MediaPool/Master/MpFolder.xml": pool,
                     Fixed.sequencePath(containerID): sequence]
        files = remapIdentities(in: files)

        var zip = ZipWriter()
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            zip.add(path, Data(text.utf8))
        }
        return zip.archive()
    }

    // MARK: - Media pool entries

    private static func poolEntry(_ source: Source, id: String, folder: String) -> String {
        let embedded = embeddedAudio(source)
        if !source.isVideo {
            return """
               <Element>
                <Sm2MpAudioClip DbId="\(id)">
                 <FieldsBlob>\(Fixed.poolFields)</FieldsBlob>
                 <Name>\(escape(source.name))</Name>
                 <MpFolder>\(folder)</MpFolder>
                 <UniqueMediaPoolItemId>\(newID())</UniqueMediaPoolItemId>
                 <MarkIn/>
                 <MarkInVideo/>
                 <MarkInAudio/>
                 <MarkOut/>
                 <MarkOutVideo/>
                 <MarkOutAudio/>
                 <CurPlayheadPosition/>
                 <PinsBA/>
                 <VirtualAudioTracksBA/>
                 <EmbeddedAudioVec>\(embedded)</EmbeddedAudioVec>
                </Sm2MpAudioClip>
               </Element>

            """
        }
        return """
           <Element>
            <Sm2MpVideoClip DbId="\(id)">
             <FieldsBlob>\(Fixed.poolFields)</FieldsBlob>
             <Name>\(escape(source.name))</Name>
             <MpFolder>\(folder)</MpFolder>
             <UniqueMediaPoolItemId>\(newID())</UniqueMediaPoolItemId>
             <MarkIn/>
             <MarkInVideo/>
             <MarkInAudio/>
             <MarkOut/>
             <MarkOutVideo/>
             <MarkOutAudio/>
             <CurPlayheadPosition>1</CurPlayheadPosition>
             <PinsBA/>
             <VirtualAudioTracksBA/>
             <MatteVec/>
             <AudioSource>AUDIO_SOURCE_EMBEDDED</AudioSource>
             <PTZRPresetType>0</PTZRPresetType>
             <SlateTC>-68719476737</SlateTC>
             <Video>
              <BtVideoInfo DbId="\(newID())">
               <FieldsBlob/>
               <Clip>\(clipBlob(source, hasAudio: source.audio != nil))</Clip>
               <Time>\(timeBlob(source))</Time>
               <Geometry>\(geometryBlob(source))</Geometry>
               <Radiometry>\(source.isStill ? Fixed.stillRadiometry : Fixed.radiometry)</Radiometry>
               <Proxy>\(proxyBlob())</Proxy>
               <VideoMetadata>\(metadataBlob())</VideoMetadata>
               <MediaMetadata/>
               <Type>STANDARD_CLIP</Type>
               <Eye>SUB_TRACK_MONO</Eye>
              </BtVideoInfo>
             </Video>
             <EmbeddedAudioVec>\(embedded)</EmbeddedAudioVec>
            </Sm2MpVideoClip>
           </Element>

        """
    }

    private static func embeddedAudio(_ source: Source) -> String {
        guard let audio = source.audio else { return "" }
        let clip = source.isVideo
            ? clipBlob(source, hasAudio: true)
            : audioClipBlob(source, codec: audio.codec)
        return """

              <Element>
               <BtAudioInfo DbId="\(newID())">
                <FieldsBlob/>
                <Clip>\(clip)</Clip>
                <TracksBA>\(tracksBlob(audio))</TracksBA>
                <MediaMetadata/>
               </BtAudioInfo>
              </Element>

        """
    }

    // MARK: - Timeline items

    private static func videoItem(_ clip: Clip, id: String, ref: String,
                                  partners: [String]) -> String {
        let source = clip.source
        return """
              <Element>
               <Sm2TiVideoClip DbId="\(id)">
                <FieldsBlob>\(linkedItemFields(partners))</FieldsBlob>
                <PrettyType/>
                <Name>\(escape(source.name))</Name>
                <Start>\(clip.start)</Start>
                <Duration>\(clip.duration)</Duration>
                <LinkedItemSync/>
                <WasDisbanded>false</WasDisbanded>
                <MarkersBA/>
                <UiMemento>0</UiMemento>
                <Flags>0</Flags>
                <PriorityIndex>0</PriorityIndex>
                <EffectFiltersBA>\(DRTBlobs.effectFilters(composite: clip.composite))</EffectFiltersBA>
                <ImportExportMetadataBA/>
                <RenderTextEnabled>true</RenderTextEnabled>
                <RenderTextGanged>true</RenderTextGanged>
                <RenderTextPrefixed>true</RenderTextPrefixed>
                <In/>
                <MixedFrameRateAlignment>0</MixedFrameRateAlignment>
                <MediaRef>\(ref)</MediaRef>
                <MediaStartTime>\(clip.mediaStart)</MediaStartTime>
                <MediaFilePath>\(escape(exportPath(source)))</MediaFilePath>
                <MediaReelNumber/>
                <MediaFrameRate>\(DRTBlobs.mediaFrameRate(source.rate))</MediaFrameRate>
                <MediaTimemapBA>\(timemap(source))</MediaTimemapBA>
                <LastChangedTime>0</LastChangedTime>
                <LastRenderedTime>0</LastRenderedTime>
                <IsMarkedForCaching>false</IsMarkedForCaching>
                <IsForceConformed>true</IsForceConformed>
                <MatchConflictState>0</MatchConflictState>
                <UseOppositeSrcForLeftEye>false</UseOppositeSrcForLeftEye>
                <UseOppositeSrcForRightEye>false</UseOppositeSrcForRightEye>
                <RenderCacheBA/>
                <CurrentSelectorIdx>305</CurrentSelectorIdx>
                <IsPreConformed>false</IsPreConformed>
                <PreConformMediaExtents>\(DRTBlobs.preConformExtents)</PreConformMediaExtents>
                <MediaMetadata/>
                <Thumbnail>
                 <BtThumnail DbId="\(newID())">
                  <FieldsBlob/>
                  <ImgWidth>-1</ImgWidth>
                  <ImgHeight>-1</ImgHeight>
                  <Buffer/>
                 </BtThumnail>
                </Thumbnail>
                <ThumbnailDirtyFlag>true</ThumbnailDirtyFlag>
               </Sm2TiVideoClip>
              </Element>

        """
    }

    private static func audioItem(_ clip: Clip, id: String, ref: String,
                                  rate: Double, partners: [String]) -> String {
        let source = clip.source
        return """
              <Element>
               <Sm2TiAudioClip DbId="\(id)">
                <FieldsBlob>\(linkedItemFields(partners, audio: true))</FieldsBlob>
                <PrettyType/>
                <Name>\(escape(source.name))</Name>
                <Start>\(clip.start)</Start>
                <Duration>\(clip.duration)</Duration>
                <LinkedItemSync/>
                <WasDisbanded>false</WasDisbanded>
                <MarkersBA/>
                <UiMemento>0</UiMemento>
                <Flags>0</Flags>
                <PriorityIndex>0</PriorityIndex>
                <EffectFiltersBA/>
                <ImportExportMetadataBA/>
                <RenderTextEnabled>false</RenderTextEnabled>
                <RenderTextGanged>false</RenderTextGanged>
                <RenderTextPrefixed>false</RenderTextPrefixed>
                <In/>
                <MixedFrameRateAlignment>0</MixedFrameRateAlignment>
                <MediaRef>\(ref)</MediaRef>
                <MediaStartTime>\(clip.mediaStart)</MediaStartTime>
                <MediaFilePath>\(escape(exportPath(source)))</MediaFilePath>
                <MediaReelNumber/>
                <MediaFrameRate>\(DRTBlobs.mediaFrameRate(rate))</MediaFrameRate>
                <MediaTimemapBA>\(DRTBlobs.timemap(frames: source.frames, rate: source.rate))</MediaTimemapBA>
                <LastChangedTime>0</LastChangedTime>
                <LastRenderedTime>0</LastRenderedTime>
                <IsMarkedForCaching>false</IsMarkedForCaching>
                <IsForceConformed>true</IsForceConformed>
                <MatchConflictState>0</MatchConflictState>
                <UseOppositeSrcForLeftEye>false</UseOppositeSrcForLeftEye>
                <UseOppositeSrcForRightEye>false</UseOppositeSrcForRightEye>
                <RenderCacheBA/>
                <VirtualAudioTrackBA>\(Fixed.virtualAudioTrack)</VirtualAudioTrackBA>
                <MediaTrackIdx>0</MediaTrackIdx>
               </Sm2TiAudioClip>
              </Element>

        """
    }

    private static func track(fields: String, type: Int, subType: Int,
                              sequence: String, items: String) -> String {
        """
          <Element>
           <Sm2TiTrack DbId="\(newID())">
            <FieldsBlob>\(fields)</FieldsBlob>
            <Type>\(type)</Type>
            <SubType>\(subType)</SubType>
            <Flags>0</Flags>
            <Sequence>\(sequence)</Sequence>
            <Items>\(items)</Items>
            <FusionCompHolderItems/>
            <UserDefinedName/>
            <LayersVec/>
           </Sm2TiTrack>
          </Element>

        """
    }

    // MARK: - Blobs that describe one file

    private static func clipBlob(_ source: Source, hasAudio: Bool) -> String {
        let directory = source.directory
        let name = source.name
        var payload = DRTBlobs.string(1, directory)
        payload.append(DRTBlobs.string(2, name))
        payload.append(DRTBlobs.string(3, stamp(source.url)))
        // Resolve names a codec for a clip and none for a still.
        if !source.isStill { payload.append(DRTBlobs.string(5, source.codec)) }
        payload.append(DRTBlobs.string(6, name))
        payload.append(DRTBlobs.string(7, newID()))
        payload.append(DRTBlobs.number(13, UInt64(modified(source.url) * 1_000_000)))
        if hasAudio || source.isStill { payload.append(DRTBlobs.number(14, 2)) }
        payload.append(DRTBlobs.number(15, 4))
        payload.append(DRTBlobs.number(16, 100))
        payload.append(DRTBlobs.number(18, source.isStill ? 8_214 : 16_384))
        return DRTBlobs.wrap(payload)
    }

    /// The same, for a file Resolve sees as audio only: no second filename,
    /// no identity, and a larger read-ahead.
    private static func audioClipBlob(_ source: Source, codec: String) -> String {
        var payload = DRTBlobs.string(1, source.directory)
        payload.append(DRTBlobs.string(2, source.name))
        payload.append(DRTBlobs.string(3, stamp(source.url)))
        payload.append(DRTBlobs.string(5, codec))
        payload.append(DRTBlobs.number(13, UInt64(modified(source.url) * 1_000_000)))
        payload.append(DRTBlobs.number(15, 4))
        payload.append(DRTBlobs.number(16, 100))
        payload.append(DRTBlobs.number(18, 32_768))
        return DRTBlobs.wrap(payload)
    }

    private static func tracksBlob(_ audio: Source.Audio) -> String {
        // TracksBA is a key/value document whose one field, keyed by the
        // track's index, is another key/value document.
        let inner = DRTBlobs.keyValue([
            .text("UniqueId", newID()),
            .int("StartTime", .long, 0),
            .int("SampleRate", .uint, audio.sampleRate),
            .int("NumChannels", .int, audio.channels),
            .int("IdxTrack", .int, 0),
            .int("Duration", .int64, audio.samples),
            .text("DbType", "BtAudioTrack"),
            .text("CodecName", audio.codec),
            .int("BitDepth", .uint, DRTBlobs.bitDepth(forCodec: audio.codec)),
        ])
        return DRTBlobs.keyValue([.data("0", Data(hexadecimal: inner))])
    }

    private static func timeBlob(_ source: Source) -> String {
        DRTBlobs.keyValue([
            .text("UniqueId", newID()),
            .int("StartFrame", .int, 0),
            // A still has exactly one frame however long it is held for.
            .int("NumFrames", .int, source.isStill ? 1 : source.frames),
            .data("FrameRate", DRTBlobs.frameRate(source.rate)),
            .text("DbType", "BtVideoTime"),
        ])
    }

    private static func geometryBlob(_ source: Source) -> String {
        var fields: [DRTBlobs.Field] = [.text("UniqueId", newID())]
        // Resolve writes a scan type for a still and none for a clip.
        if source.isStill { fields.append(.int("ScanType", .int, 0)) }
        fields.append(.data("Resolution", DRTBlobs.resolution(width: source.width,
                                                              height: source.height)))
        // Bytes a frame occupies; for a still the frame is the whole file.
        fields.append(.int("FrameSize", .int, source.isStill
                           ? source.byteSize
                           : source.width * source.height * 3 / 2))
        fields.append(.text("DbType", "BtGeometry"))
        return DRTBlobs.keyValue(fields)
    }

    /// How much of the source the item may reach.
    ///
    /// A clip with real frames names its last one. A still has only one frame
    /// but can be held for any length, so it carries a ramp instead.
    private static func timemap(_ source: Source) -> String {
        guard source.isStill else {
            return DRTBlobs.timemap(frames: source.frames, rate: source.rate)
        }
        let limit = 60_000.0
        var keyframes = Data(hexadecimal: "800a000a0909")
        withUnsafeBytes(of: limit.bitPattern.littleEndian) { keyframes.append(contentsOf: $0) }
        return DRTBlobs.keyValue([
            .double("YMin", -1),
            .double("YMax", -1),
            .double("XMax", limit),
            .text("UniqueId", newID()),
            .data("KeyframesBA", keyframes),
            .text("DbType", "Sm2TimeMap"),
        ])
    }

    /// A timeline item's FieldsBlob, naming the items it moves with.
    ///
    /// Resolve writes this compressed; raw is the same payload and reads back
    /// the same, which is what makes it writable here at all.
    private static func linkedItemFields(_ partners: [String],
                                         audio: Bool = false) -> String {
        guard !partners.isEmpty else {
            return audio ? Fixed.audioItemFields : Fixed.itemFields
        }
        let document = Data(hexadecimal: DRTBlobs.keyValue(
            partners.enumerated().map { .text("\($0.offset)", $0.element) }))
        var inner = DRTBlobs.bytes(1, document)
        inner.append(Data(hexadecimal: "a80100"))
        var middle = DRTBlobs.bytes(1, inner)
        middle.append(Data(hexadecimal: "2001"))
        var payload = DRTBlobs.bytes(1, middle)
        payload.append(Data(hexadecimal: audio
            ? "7804"
            : "1210000000000000000600000000ffffffff980101"))
        return DRTBlobs.wrap(payload)
    }

    private static func proxyBlob() -> String {
        DRTBlobs.keyValue([
            .text("UniqueId", newID()),
            .text("DbType", "BtVideoProxy"),
            .int("DataManagerID", .int, 50),
        ])
    }

    private static func metadataBlob() -> String {
        DRTBlobs.keyValue([
            .text("UniqueId", newID()),
            .text("DbType", "BtVideoMetadata"),
        ])
    }

    /// Where the file will be once the archive is unpacked.
    private static func exportPath(_ source: Source) -> String {
        source.directory + "/" + source.name
    }

    private static func modified(_ url: URL) -> Double {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                    as? Date) ?? nil
        return (date ?? Date()).timeIntervalSince1970
    }

    /// Resolve writes the file's modification date in C's `asctime` shape,
    /// with a single-digit day unpadded.
    private static func stamp(_ url: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: modified(url)))
    }

    // MARK: - The template

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "xml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    /// Keep the timeline clip the template carries, drop any source media, and
    /// put ours in its place. The timeline clip's closing `</Element>` has to
    /// be found by depth: the version table nested inside it holds `<Element>`
    /// blocks of its own, and taking the first one truncates the entry and
    /// leaves the XML unbalanced — which Resolve accepts and then silently
    /// imports nothing from.
    private static func replaceMediaVec(in pool: String, with entries: String) -> String {
        guard let open = pool.range(of: "<MediaVec>"),
              let close = pool.range(of: "</MediaVec>") else { return pool }
        let body = String(pool[open.upperBound..<close.lowerBound])
        let keep = body.prefix(elementEnd(of: body))
        return String(pool[..<open.upperBound]) + keep + "\n" + entries
            + String(pool[close.lowerBound...])
    }

    private static func elementEnd(of text: String) -> Int {
        let open = Array("<Element>"), close = Array("</Element>")
        let characters = Array(text)
        var index = 0
        var depth = 0
        var started = false
        while index < characters.count {
            if matches(characters, at: index, open) {
                depth += 1
                started = true
                index += open.count
            } else if matches(characters, at: index, close) {
                depth -= 1
                index += close.count
                if started, depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return characters.count
    }

    private static func matches(_ characters: [Character], at index: Int,
                                _ needle: [Character]) -> Bool {
        guard index + needle.count <= characters.count else { return false }
        for offset in 0..<needle.count where characters[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    /// The sequence file is named after the container it holds.
    private enum Fixed {
        static func sequencePath(_ id: String) -> String { "SeqContainer/\(id).xml" }

        // Lifted out of DRTs Resolve exported, not transcribed: these are the
        // same for every clip and the template carries no source media to read
        // them back from.
        static let poolFields =
            "000000020000001b800a180a040a0230041210000000000000000600000000ffffffff"
        static let radiometry = "80089403100228108801329001d080a006980100d80100"
        static let stillRadiometry = "8010022810980100d80100"
        static let trackFields =
            "000000010000000100000012004e0075006d004c00610079006500720073000000020000000000"
        static let itemFields =
            "000000020000001f800a070a03a8010020011210000000000000000600000000ffffffff980101"
        static let audioTrackFields =
            "000000010000000200000012004e0075006d004c0061007900650072007300000002000000"
            + "00000000003e004500780063006c0075006400650054007200610063006b00460072006f00"
            + "6d00530065007100750065006e0063006500430061006300680069006e0067000000010001"
        static let audioItemFields = "000000020000000c800a070a03a8010020017804"
        static let virtualAudioTrack =
            "000000010000000200000014004300680061006e006e0065006c0073004200410000000c00"
            + "0000000c000000020000000100004001000000120041007500640069006f005400790070"
            + "0065000000020000000001"
    }

    // MARK: - Identity

    private static func newID() -> String { UUID().uuidString.lowercased() }

    private static let uuidPattern = try? NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private static let blobPattern = try? NSRegularExpression(pattern: ">([0-9a-fA-F]{32,})<")

    /// Give every identity in the archive a new value, consistently.
    ///
    /// The same identities also appear inside the hex blobs, as UTF-16 text,
    /// where a text replace cannot see them — and Resolve reads them there too.
    /// A UUID is always 36 characters, so swapping one inside a blob leaves
    /// every length field in that blob untouched.
    private static func remapIdentities(in files: [String: String]) -> [String: String] {
        guard let uuidPattern, let blobPattern else { return files }
        var remap: [String: String] = [:]
        for text in files.values {
            let range = NSRange(text.startIndex..., in: text)
            for result in uuidPattern.matches(in: text, range: range) {
                guard let found = Range(result.range, in: text) else { continue }
                let key = String(text[found])
                if remap[key] == nil { remap[key] = newID() }
            }
        }

        var out: [String: String] = [:]
        for (path, text) in files {
            var updated = text
            for (old, fresh) in remap {
                updated = updated.replacingOccurrences(of: old, with: fresh)
            }
            // Then the copies hiding inside the blobs.
            let range = NSRange(updated.startIndex..., in: updated)
            var rewritten = ""
            var cursor = updated.startIndex
            for result in blobPattern.matches(in: updated, range: range) {
                guard let whole = Range(result.range, in: updated),
                      let inner = Range(result.range(at: 1), in: updated) else { continue }
                rewritten += updated[cursor..<whole.lowerBound]
                var bytes = Data(hexadecimal: String(updated[inner]))
                for (old, fresh) in remap {
                    bytes = replace(old, with: fresh, in: bytes)
                }
                rewritten += ">" + bytes.hexadecimal + "<"
                cursor = whole.upperBound
            }
            rewritten += updated[cursor...]

            // The sequence file is named after the container it holds.
            var name = path
            for (old, fresh) in remap where name.contains(old) {
                name = name.replacingOccurrences(of: old, with: fresh)
                break
            }
            out[name] = rewritten
        }
        return out
    }

    /// Swap a UUID inside a blob, in each of the encodings one can appear in.
    private static func replace(_ old: String, with fresh: String, in data: Data) -> Data {
        var out = data
        for encoding in [String.Encoding.utf16BigEndian, .utf16LittleEndian, .utf8] {
            guard let needle = old.data(using: encoding),
                  let replacement = fresh.data(using: encoding),
                  needle.count == replacement.count else { continue }
            out = out.replacingBytes(needle, with: replacement)
        }
        return out
    }

    // MARK: - Text

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              let found = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    /// Replaced by hand rather than by template: these carry file paths, and
    /// a regex replacement reads every backslash and `$` in one as a
    /// substitution.
    private static func replace(_ pattern: String, in text: String,
                                with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              let found = Range(result.range, in: text) else { return text }
        return String(text[..<found.lowerBound]) + replacement + String(text[found.upperBound...])
    }
}

extension Data {
    init(hexadecimal: String) {
        var out = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while let next = hexadecimal.index(index, offsetBy: 2, limitedBy: hexadecimal.endIndex) {
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { break }
            out.append(byte)
            index = next
        }
        self = out
    }

    func replacingBytes(_ needle: Data, with replacement: Data) -> Data {
        guard !needle.isEmpty, count >= needle.count else { return self }
        var out = Data(capacity: count)
        var index = startIndex
        while index < endIndex {
            if index + needle.count <= endIndex, self[index..<index + needle.count] == needle {
                out.append(replacement)
                index += needle.count
            } else {
                out.append(self[index])
                index += 1
            }
        }
        return out
    }
}
