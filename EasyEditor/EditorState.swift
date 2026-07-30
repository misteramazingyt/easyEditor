import Foundation
import SwiftUI
import PhotosUI
import Combine
import CoreImage

/// Per-editing-session state: the project value, selection, zoom, undo stack,
/// and the debounced pipeline that turns edits into a playable composition.
@MainActor
final class EditorState: ObservableObject {

    @Published var project: VideoProject {
        didSet { projectChanged.send() }
    }
    @Published var selectedClipID: UUID?
    @Published var pixelsPerSecond: CGFloat = 60
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isRebuilding = false
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var toast: String?
    @Published private(set) var isGeneratingCaptions = false
    @Published private(set) var isProcessing = false
    /// Non-nil while auto b-roll runs; shows staged progress.
    @Published private(set) var autoBRollStatus: String?

    let playback = PlaybackController()

    private let engine = CompositionEngine()
    private let importer = MediaImportService()
    private let save: (VideoProject) -> Void
    private var undoStack: [VideoProject] = []
    private var redoStack: [VideoProject] = []
    private var toastTask: Task<Void, Never>?
    private let projectChanged = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []
    private var rebuildTask: Task<Void, Never>?

    var selectedClip: TimelineClip? {
        selectedClipID.flatMap { project.clip($0) }
    }

    init(project: VideoProject, save: @escaping (VideoProject) -> Void) {
        self.project = project
        self.save = save
        projectChanged
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.save(self.project)
                self.rebuild()
            }
            .store(in: &cancellables)
        // PlaybackController is a nested ObservableObject; forward its changes
        // so time-dependent views (playhead, transport) re-render.
        playback.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        playback.onItemFailed = { [weak self] message in
            self?.errorMessage = "Playback failed: \(message)"
        }
        rebuild()
    }

    // MARK: - Composition pipeline

    func rebuild() {
        rebuildTask?.cancel()
        let snapshot = project
        isRebuilding = true
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            let overlays = await self.engine.renderOverlayImages(project: snapshot)
            do {
                let built = try await self.engine.build(project: snapshot, overlayImages: overlays)
                guard !Task.isCancelled else { return }
                self.playback.install(built)
            } catch CompositionEngine.EngineError.noVideoContent {
                guard !Task.isCancelled else { return }
                self.playback.install(nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.playback.install(nil)
                Log.engine.error("Rebuild failed: \(error.localizedDescription)")
                self.errorMessage = "Couldn't build the preview: \(error.localizedDescription)"
            }
            self.isRebuilding = false
        }
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        canUndo = !undoStack.isEmpty
        canRedo = true
        if let id = selectedClipID, project.clip(id) == nil {
            selectedClipID = nil
        }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        canUndo = true
        canRedo = !redoStack.isEmpty
        if let id = selectedClipID, project.clip(id) == nil {
            selectedClipID = nil
        }
    }

    // MARK: - Toasts ("Clip reversed" style transient labels)

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Importing media

    func importPickedMedia(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        pushUndo()
        Task {
            var succeeded = 0
            for item in items {
                guard let imported = await importer.importPickerItem(item, projectID: project.id) else { continue }
                succeeded += 1
                switch imported {
                case .video(let fileName, let duration):
                    project.append(.video(fileName: fileName, duration: duration,
                                          order: project.nextPrimaryOrder))
                case .image(let fileName):
                    var clip = TimelineClip.image(fileName: fileName, at: playback.currentTime)
                    clip.laneIndex = freeStackIndex(for: clip, desired: 1)
                    project.append(clip)
                case .audio:
                    break
                }
            }
            isImporting = false
            if succeeded == 0 {
                errorMessage = "Couldn't import the selected item\(items.count == 1 ? "" : "s"). "
                    + "If it's an iCloud video, make sure it has finished downloading and try again."
            }
        }
    }

    func importMusic(from url: URL) {
        pushUndo()
        Task {
            guard let imported = await importer.importAudioFile(url, projectID: project.id),
                  case .audio(let fileName, let duration) = imported else {
                errorMessage = "Couldn't import that audio file."
                return
            }
            var clip = TimelineClip.audio(kind: .music, fileName: fileName,
                                          duration: duration, at: playback.currentTime)
            clip.laneIndex = freeStackIndex(for: clip, desired: -1)
            project.append(clip)
        }
    }

    func addTitle(_ payload: TextPayload, placement: OverlayPlacement) {
        pushUndo()
        var clip = TimelineClip.title(payload, placement: placement, at: playback.currentTime)
        clip.trimEnd = 3
        clip.laneIndex = freeStackIndex(for: clip, desired: 1)
        project.append(clip)
        selectedClipID = clip.id
    }

    func addSFX(_ effect: SFXLibrary.Effect) {
        guard let (fileName, duration) = SFXLibrary.copyIntoProject(effect, projectID: project.id) else {
            errorMessage = "Couldn't add that sound effect."
            return
        }
        pushUndo()
        var clip = TimelineClip.audio(kind: .sfx, fileName: fileName,
                                      duration: duration, at: playback.currentTime)
        clip.lane = .voice
        clip.laneIndex = freeStackIndex(for: clip, desired: -1)
        project.append(clip)
    }

    func addVoiceover(fileName: String, duration: Double, at offset: Double) {
        pushUndo()
        var clip = TimelineClip.audio(kind: .voiceover, fileName: fileName,
                                      duration: duration, at: offset)
        clip.laneIndex = freeStackIndex(for: clip, desired: -1)
        project.append(clip)
    }

    /// Download a web image and drop it on the timeline at the playhead.
    func importWebImage(from url: URL, placement: OverlayPlacement? = nil) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let fileName = importer.saveImageData(data, projectID: project.id) else {
                errorMessage = "That image couldn't be decoded."
                return false
            }
            pushUndo()
            var clip = TimelineClip.image(fileName: fileName, at: playback.currentTime)
            if let placement { clip.placement = placement }
            clip.laneIndex = freeStackIndex(for: clip, desired: 1)
            project.append(clip)
            selectedClipID = clip.id
            showToast("Image added")
            return true
        } catch {
            errorMessage = "Image download failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Clip editing

    func mutate(_ id: UUID, _ change: (inout TimelineClip) -> Void) {
        guard var clip = project.clip(id) else { return }
        pushUndo()
        change(&clip)
        project.update(clip)
    }

    /// Live variant used by drags: mutates without pushing undo per event.
    /// Call `beginGesture()` once when the drag starts.
    func mutateLive(_ id: UUID, _ change: (inout TimelineClip) -> Void) {
        guard var clip = project.clip(id) else { return }
        change(&clip)
        project.update(clip)
    }

    func beginGesture() {
        pushUndo()
    }

    func deleteClip(_ id: UUID) {
        pushUndo()
        project.remove(id)
        if selectedClipID == id { selectedClipID = nil }
    }

    func duplicateClip(_ id: UUID) {
        guard var copy = project.clip(id) else { return }
        pushUndo()
        copy.id = UUID()
        if copy.lane == .primary {
            copy.order += 1
            // Shift everything after the original down one slot.
            for c in project.primaryClips where c.order >= copy.order && c.id != copy.id {
                var moved = c
                moved.order += 1
                project.update(moved)
            }
        } else {
            copy.offset += copy.effectiveDuration
        }
        project.append(copy)
        selectedClipID = copy.id
    }

    /// Split the clip under the playhead at the playhead.
    func splitClip(_ id: UUID) {
        guard let clip = project.clip(id) else { return }
        guard canSplit(clip, at: playback.currentTime) else {
            errorMessage = "Move the playhead inside the clip to split it."
            return
        }
        pushUndo()
        performSplit(clip, at: playback.currentTime)
    }

    /// Scissors: split every clip under the playhead — storyline and
    /// connected clips alike — in one stroke.
    func splitAllAtPlayhead() {
        let time = playback.currentTime
        let candidates = project.clips.filter { canSplit($0, at: time) }
        guard !candidates.isEmpty else {
            errorMessage = "No clips under the playhead to split."
            return
        }
        pushUndo()
        // Primary clips descending by order so the +1 shifts from earlier
        // splits never touch clips we haven't processed yet.
        let primaries = candidates.filter { $0.lane == .primary }
            .sorted { $0.order > $1.order }
        let connected = candidates.filter { $0.lane != .primary }
        for clip in primaries + connected {
            if let current = project.clip(clip.id) {
                performSplit(current, at: time)
            }
        }
        showToast("Split \(candidates.count) clip\(candidates.count == 1 ? "" : "s")")
        Haptics.drop()
    }

    private func canSplit(_ clip: TimelineClip, at time: Double) -> Bool {
        let local = time - project.start(of: clip)
        return local > 0.1 && local < clip.effectiveDuration - 0.1
    }

    private func performSplit(_ clip: TimelineClip, at time: Double) {
        var first = clip
        let start = project.start(of: first)
        let local = time - start
        var second = first
        second.id = UUID()
        switch first.kind {
        case .video, .music, .voiceover, .sfx:
            let sourceSplit = first.trimStart + local * first.speed
            first.trimEnd = sourceSplit
            second.trimStart = sourceSplit
        case .image, .title:
            first.trimEnd = local
            second.trimEnd = second.trimEnd - local
            second.trimStart = 0
        }
        if first.lane == .primary {
            first.transitionToNext = nil
            second.order = first.order + 1
            for c in project.primaryClips where c.order > first.order {
                var moved = c
                moved.order += 1
                project.update(moved)
            }
        } else {
            second.offset = start + local
        }
        project.update(first)
        project.append(second)
    }

    // MARK: - Magnetic moves (called from timeline drags)

    /// Move a primary clip to a new storyline position (magnetic reorder).
    func reorderPrimary(_ id: UUID, to newIndex: Int) {
        guard let clip = project.clip(id), clip.lane == .primary else { return }
        var ordered = project.primaryClips.filter { $0.id != id }
        let index = max(0, min(newIndex, ordered.count))
        var moved = clip
        ordered.insert(moved, at: index)
        for (i, c) in ordered.enumerated() {
            if c.id == id {
                moved.order = i
                project.update(moved)
            } else if c.order != i {
                var copy = c
                copy.order = i
                project.update(copy)
            }
        }
    }

    /// Move a clip to a stacking slot: 0 joins the magnetic storyline
    /// (video only); +n floats above it; -n sits below with the audio.
    /// If the target slot is occupied at that time, the clip bumps outward
    /// to the nearest free slot, FCP style.
    func moveToStack(_ id: UUID, rowIndex: Int, timelineTime: Double) {
        guard var clip = project.clip(id) else { return }
        if rowIndex == 0 {
            guard clip.kind == .video else { return }
            moveToLane(id, lane: .primary, timelineTime: timelineTime)
            return
        }
        switch clip.kind {
        case .video:
            guard rowIndex >= 1 else { return }
            clip.lane = .broll
        case .image:
            guard rowIndex >= 1 else { return }
            clip.lane = .images
        case .title:
            guard rowIndex >= 1 else { return }
            clip.lane = .titles
        case .music, .voiceover, .sfx:
            guard rowIndex <= -1 else { return }
        }
        if project.clip(id)?.lane == .primary {
            clip.transitionToNext = nil
        }
        clip.offset = max(0, timelineTime)
        clip.laneIndex = freeStackIndex(for: clip, desired: rowIndex)
        project.update(clip)
        project.renumberPrimary()
    }

    /// Walk outward from the desired slot until the clip's time range is free.
    private func freeStackIndex(for clip: TimelineClip, desired: Int) -> Int {
        let direction = desired > 0 ? 1 : -1
        let start = clip.offset
        let end = start + clip.effectiveDuration
        var index = desired
        for _ in 0..<24 {
            let occupied = project.clips(stackedAt: index)
                .contains { other in
                    other.id != clip.id
                        && other.offset < end
                        && start < other.offset + other.effectiveDuration
                }
            if !occupied { return index }
            index += direction
        }
        return index
    }

    /// Move a clip into a different lane (the FCP "connect"/"overwrite" moves).
    /// `timelineTime` is where the clip should land.
    func moveToLane(_ id: UUID, lane: Lane, timelineTime: Double) {
        guard var clip = project.clip(id) else { return }
        guard Lane.allowed(for: clip.kind).contains(lane) else { return }
        let oldLane = clip.lane
        clip.lane = lane
        if lane == .primary {
            // Joining the storyline: order determined by drop time.
            let starts = project.primaryStartTimes
            let ordered = project.primaryClips.filter { $0.id != id }
            var index = ordered.count
            for (i, c) in ordered.enumerated() {
                let mid = (starts[c.id] ?? 0) + c.effectiveDuration / 2
                if timelineTime < mid { index = i; break }
            }
            clip.transitionToNext = nil
            project.update(clip)
            reorderPrimary(id, to: index)
        } else {
            if oldLane == .primary {
                clip.transitionToNext = nil
            }
            clip.offset = max(0, timelineTime)
            project.update(clip)
            project.renumberPrimary()
        }
    }

    // MARK: - Auto B-Roll

    func runAutoBRoll(_ settings: AutoBRollService.Settings,
                      desktopService: DesktopLibraryService?,
                      pexelsKey: String) {
        guard autoBRollStatus == nil else { return }
        guard project.primaryClips.contains(where: { $0.kind == .video }) else {
            errorMessage = "Add a video with speech before generating b-roll."
            return
        }
        autoBRollStatus = "Transcribing…"
        Task {
            defer { autoBRollStatus = nil }
            guard await CaptionService.authorize() else {
                errorMessage = "Speech recognition permission is off. Enable it in Settings → EasyEditor."
                return
            }
            let mentions: [AutoBRollService.Mention]
            do {
                mentions = try await AutoBRollService.detectMentions(project: project,
                                                                     settings: settings)
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                return
            }
            guard !mentions.isEmpty else {
                errorMessage = "No visual mentions found — try lowering the confidence threshold or enabling more coverage."
                return
            }
            pushUndo()
            let pexels = pexelsKey.isEmpty ? nil : PexelsService(apiKey: pexelsKey)
            let minDuration = Double(settings.minDurationFrames) / 30
            let imageDuration = max(minDuration, 2.2)
            var added = 0

            for (index, mention) in mentions.enumerated() {
                autoBRollStatus = "\(index + 1)/\(mentions.count): \(mention.text)"
                var placed = 0

                // Video first when requested and Pexels is configured.
                if settings.media != .images, let pexels,
                   let hit = try? await pexels.searchVideo(mention.text),
                   let (data, _) = try? await URLSession.shared.data(from: hit.downloadURL) {
                    let temp = FilePaths.tempDirectory
                        .appendingPathComponent(UUID().uuidString + ".mp4")
                    try? data.write(to: temp)
                    if let imported = await importer.importVideoFile(temp, projectID: project.id,
                                                                    deleteSource: true),
                       case .video(let fileName, let duration) = imported {
                        var clip = TimelineClip.video(fileName: fileName, duration: duration, order: 0)
                        clip.lane = .broll
                        clip.offset = mention.timelineTime
                        clip.trimEnd = min(duration, max(minDuration, 3.5))
                        clip.isMuted = true
                        clip.laneIndex = freeStackIndex(for: clip, desired: 1)
                        clip.inOut = InOutSettings()
                        project.append(clip)
                        added += 1
                        placed += 1
                    }
                }

                // Stills: primary media, remaining slots, or video fallback.
                let wantStills = settings.media != .video
                    || (settings.fallbackToStills && placed == 0)
                if wantStills && placed < settings.maxAssetsPerMention {
                    let images = await searchBRollImages(mention.text,
                                                         source: settings.source,
                                                         desktopService: desktopService)
                    for image in images.prefix(settings.maxAssetsPerMention - placed) {
                        guard let (data, _) = try? await URLSession.shared.data(from: image.fullURL),
                              let fileName = importer.saveImageData(data, projectID: project.id) else {
                            continue
                        }
                        var clip = TimelineClip.image(
                            fileName: fileName,
                            at: mention.timelineTime + Double(placed) * imageDuration)
                        clip.trimEnd = imageDuration
                        clip.placement = Self.placement(for: settings.insertStyle)
                        clip.laneIndex = freeStackIndex(for: clip, desired: 1)
                        clip.inOut = InOutSettings()
                        project.append(clip)
                        added += 1
                        placed += 1
                    }
                }
            }
            if added == 0 {
                errorMessage = "Found \(mentions.count) mentions but couldn't fetch media for them — check the server/network."
            } else {
                showToast("Added \(added) b-roll clip\(added == 1 ? "" : "s")")
                Haptics.success()
            }
        }
    }

    private func searchBRollImages(_ query: String,
                                   source: AutoBRollService.MediaSource,
                                   desktopService: DesktopLibraryService?) async -> [WebImage] {
        if source != .web, let desktopService,
           let hits = try? await desktopService.search(query, count: 6), !hits.isEmpty {
            return hits
        }
        if source != .desktop,
           let hits = try? await WebImageSearchService().search(query), !hits.isEmpty {
            return hits
        }
        return []
    }

    private static func placement(for style: AutoBRollService.InsertStyle) -> OverlayPlacement {
        switch style {
        case .cutaway: return OverlayPlacement(centerX: 0.5, centerY: 0.5, widthFraction: 1.0)
        case .overlay: return OverlayPlacement(centerX: 0.72, centerY: 0.28, widthFraction: 0.5)
        case .fullFrame: return OverlayPlacement(centerX: 0.5, centerY: 0.5, widthFraction: 1.08)
        }
    }

    // MARK: - Reverse & freeze frame

    /// Rewrites the clip's media backwards (video only — audio is dropped)
    /// and mirrors the trim window so the same slice stays selected.
    func reverseClip(_ id: UUID) {
        guard let clip = project.clip(id), clip.kind == .video,
              let fileName = clip.fileName, !isProcessing else { return }
        isProcessing = true
        showToast("Reversing…")
        Task {
            defer { isProcessing = false }
            let newName = "reversed-\(UUID().uuidString).mov"
            let source = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            let dest = FilePaths.mediaURL(projectID: project.id, fileName: newName)
            do {
                try await MediaProcessingService.reverseVideo(source: source, destination: dest)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            beginGesture()
            mutateLive(id) { c in
                let duration = c.assetDuration
                let oldStart = c.trimStart, oldEnd = c.trimEnd
                c.fileName = newName
                c.trimStart = max(0, duration - oldEnd)
                c.trimEnd = max(c.trimStart + 0.05, duration - oldStart)
                c.isMuted = true // the reversed file has no audio track
            }
            await ThumbnailService.shared.invalidate(clipID: id)
            showToast("Clip reversed (audio removed)")
        }
    }

    /// TikTok Freeze: splits the clip at the playhead and inserts a
    /// 3-second still of the frame under the playhead.
    func freezeFrame(_ id: UUID) {
        guard let clip = project.clip(id), clip.kind == .video,
              clip.lane == .primary,
              let fileName = clip.fileName, !isProcessing else { return }
        let start = project.start(of: clip)
        let local = playback.currentTime - start
        guard local > 0.05, local < clip.effectiveDuration - 0.05 else {
            errorMessage = "Move the playhead inside the clip to freeze a frame."
            return
        }
        let sourceTime = clip.trimStart + local * clip.speed
        isProcessing = true
        showToast("Freezing frame…")
        Task {
            defer { isProcessing = false }
            let freezeName = "freeze-\(UUID().uuidString).mov"
            let source = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            let dest = FilePaths.mediaURL(projectID: project.id, fileName: freezeName)
            do {
                try await MediaProcessingService.writeStillVideo(
                    source: source, at: sourceTime, length: 3, to: dest)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            guard var first = project.clip(id) else { return }
            beginGesture()
            var second = first
            second.id = UUID()
            first.trimEnd = sourceTime
            first.transitionToNext = nil
            second.trimStart = sourceTime
            second.order = first.order + 2
            for c in project.primaryClips where c.order > first.order && c.id != first.id {
                var moved = c
                moved.order += 2
                project.update(moved)
            }
            var freeze = TimelineClip.video(fileName: freezeName, duration: 3,
                                            order: first.order + 1)
            freeze.isMuted = true
            project.update(first)
            project.append(freeze)
            project.append(second)
            showToast("Freeze frame added")
        }
    }

    /// TikTok's timeline speaker toggle: mute/unmute all original clip audio.
    func toggleOriginalAudio() {
        let anyAudible = project.primaryClips.contains { !$0.isMuted }
        pushUndo()
        for clip in project.primaryClips {
            var updated = clip
            updated.isMuted = anyAudible
            project.update(updated)
        }
        showToast(anyAudible ? "Original sound off" : "Original sound on")
    }

    var originalAudioEnabled: Bool {
        project.primaryClips.contains { !$0.isMuted }
    }

    // MARK: - Auto captions

    func generateCaptions() {
        guard !isGeneratingCaptions else { return }
        let videoClips = project.primaryClips.filter { $0.kind == .video && $0.fileName != nil }
        guard !videoClips.isEmpty else {
            errorMessage = "Add a video before generating captions."
            return
        }
        isGeneratingCaptions = true
        showToast("Transcribing audio…")
        Task {
            defer { isGeneratingCaptions = false }
            guard await CaptionService.authorize() else {
                errorMessage = "Speech recognition permission is off. Enable it in Settings → EasyEditor."
                return
            }
            var captions: [(text: String, start: Double, duration: Double)] = []
            let starts = project.primaryStartTimes
            for clip in videoClips {
                guard let fileName = clip.fileName else { continue }
                let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
                do {
                    let chunks = try await CaptionService.captions(
                        for: url, trimStart: clip.trimStart, trimEnd: clip.trimEnd)
                    let clipStart = starts[clip.id] ?? 0
                    for chunk in chunks {
                        let start = clipStart + (chunk.start - clip.trimStart) / clip.speed
                        let duration = max(0.6, chunk.duration / clip.speed)
                        captions.append((chunk.text, start, duration))
                    }
                } catch {
                    Log.engine.error("Caption transcription failed: \(error.localizedDescription)")
                }
            }
            guard !captions.isEmpty else {
                errorMessage = "Couldn't hear any speech to caption."
                return
            }
            pushUndo()
            for caption in captions {
                var clip = TimelineClip.title(
                    TextPayload(string: caption.text, style: .caption),
                    placement: .caption, at: caption.start)
                clip.trimEnd = caption.duration
                project.append(clip)
            }
            showToast("Added \(captions.count) captions")
        }
    }

    // MARK: - Connected-clip motion (In/Out, loop animation, compositing)

    /// Live-update a clip's In/Out settings; when Global is on, mirror them
    /// (plus focus) onto every other connected visual clip.
    func updateInOut(_ id: UUID, _ change: (inout InOutSettings) -> Void) {
        guard var clip = project.clip(id) else { return }
        var settings = clip.inOut ?? InOutSettings()
        change(&settings)
        clip.inOut = settings
        project.update(clip)
        if settings.isGlobal { syncGlobalMotion(from: clip) }
    }

    func setFocus(_ id: UUID, _ style: FocusStyle) {
        guard var clip = project.clip(id) else { return }
        clip.focus = style == .none ? nil : style
        project.update(clip)
        if clip.inOut?.isGlobal == true { syncGlobalMotion(from: clip) }
    }

    func updateLoop(_ id: UUID, _ change: (inout LoopAnimationSettings) -> Void) {
        guard var clip = project.clip(id) else { return }
        var settings = clip.loopFx ?? LoopAnimationSettings()
        change(&settings)
        clip.loopFx = settings
        project.update(clip)
        if settings.isGlobal { syncGlobalMotion(from: clip) }
    }

    func updateCompositing(_ id: UUID, _ change: (inout CompositingSettings) -> Void) {
        guard var clip = project.clip(id) else { return }
        var settings = clip.compositing ?? CompositingSettings()
        change(&settings)
        clip.compositing = settings
        project.update(clip)
    }

    /// Global = identical settings on every connected visual clip.
    private func syncGlobalMotion(from source: TimelineClip) {
        for other in project.clips
        where other.id != source.id && other.lane != .primary && other.isVisual {
            var updated = other
            if source.inOut?.isGlobal == true {
                updated.inOut = source.inOut
                updated.focus = source.focus
            }
            if source.loopFx?.isGlobal == true {
                updated.loopFx = source.loopFx
            }
            project.update(updated)
        }
    }

    // MARK: - Transitions

    func setTransition(afterClipID id: UUID, _ transition: Transition?) {
        mutate(id) { $0.transitionToNext = transition }
    }

    // MARK: - Playback helpers

    func togglePlayback() { playback.playPause() }

    func scrub(to time: Double) {
        playback.scrub(to: min(max(0, time), max(0, project.duration)))
    }

    func endScrub() { playback.endScrub() }
}
