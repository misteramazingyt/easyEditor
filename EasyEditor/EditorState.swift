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
                    project.append(.image(fileName: fileName, at: playback.currentTime))
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
            project.append(.audio(kind: .music, fileName: fileName,
                                  duration: duration, at: playback.currentTime))
        }
    }

    func addTitle(_ payload: TextPayload, placement: OverlayPlacement) {
        pushUndo()
        var clip = TimelineClip.title(payload, placement: placement, at: playback.currentTime)
        clip.trimEnd = 3
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
        project.append(clip)
    }

    func addVoiceover(fileName: String, duration: Double, at offset: Double) {
        pushUndo()
        project.append(.audio(kind: .voiceover, fileName: fileName,
                              duration: duration, at: offset))
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
        guard var first = project.clip(id) else { return }
        let time = playback.currentTime
        let start = project.start(of: first)
        let local = time - start
        guard local > 0.1, local < first.effectiveDuration - 0.1 else {
            errorMessage = "Move the playhead inside the clip to split it."
            return
        }
        pushUndo()
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
