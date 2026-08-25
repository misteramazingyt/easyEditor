import Foundation
import CoreGraphics
import UIKit

/// Framing and animation: what the canvas box and the lozenges drive.
extension EditorState {

    /// Where the playhead sits inside a clip. Keys are timed from a clip's own
    /// start, so this is the currency the tracks speak.
    func localTime(of clip: TimelineClip) -> Double {
        max(0, playback.currentTime - project.start(of: clip))
    }

    /// The framing showing right now — the animated value if the clip has
    /// keys, otherwise its resting one.
    func liveTransform(of clip: TimelineClip) -> ClipTransform {
        clip.transform(at: playback.currentTime, clipStart: project.start(of: clip))
    }

    func liveComposite(of clip: TimelineClip) -> CompositeValue {
        clip.composite(at: playback.currentTime, clipStart: project.start(of: clip))
    }

    func motionMarker(of clip: TimelineClip) -> KeyframeMarker {
        clip.motionKeys?.marker(at: localTime(of: clip)) ?? .off
    }

    func compositeMarker(of clip: TimelineClip) -> KeyframeMarker {
        clip.compositeKeys?.marker(at: localTime(of: clip)) ?? .off
    }

    // MARK: - Changing things

    /// Change the framing. Once a clip is keyed, every change lands as a key at
    /// the playhead rather than moving the whole clip — which is the difference
    /// between animating something and repositioning it.
    func updateTransform(_ id: UUID, live: Bool = false,
                         _ change: (inout ClipTransform) -> Void) {
        guard var clip = project.clip(id) else { return }
        if !live { markUndoPoint() }
        var value = liveTransform(of: clip)
        change(&value)
        if var keys = clip.motionKeys, keys.isActive {
            keys.set(value, at: localTime(of: clip))
            clip.motionKeys = keys
        } else {
            clip.setBaseTransform(value)
        }
        project.update(clip)
    }

    func updateComposite(_ id: UUID, live: Bool = false,
                         _ change: (inout CompositeValue) -> Void) {
        guard var clip = project.clip(id) else { return }
        if !live { markUndoPoint() }
        var value = liveComposite(of: clip)
        change(&value)
        if var keys = clip.compositeKeys, keys.isActive {
            keys.set(value, at: localTime(of: clip))
            clip.compositeKeys = keys
        } else {
            clip.setBaseComposite(value)
        }
        project.update(clip)
    }

    // MARK: - Dragging a handle

    /// While a handle is held the value goes to the live store and the frame
    /// on screen is re-rendered. Nothing is written to the project and nothing
    /// is rebuilt, so the picture keeps up with the finger.
    /// Lift the layer out of the composition and get a still of it for the
    /// view to carry. The player re-renders the scene without it once; from
    /// then until release, nothing has to be decoded at all.
    func beginTransformDrag(_ clip: TimelineClip) {
        LiveTransformStore.shared.setDragging(true)
        guard LayerPreviewCache.shared.cached(clip.id) != nil || clip.kind == .video else {
            return
        }
        if LayerPreviewCache.shared.cached(clip.id) != nil {
            LiveTransformStore.shared.setHidden(clip.id)
            playback.refreshFrame()
            return
        }
        let local = localTime(of: clip)
        let projectID = project.id
        Task { @MainActor in
            guard await LayerPreviewCache.shared.frame(for: clip, projectID: projectID,
                                                       at: local) != nil,
                  LiveTransformStore.shared.isDragging else { return }
            LiveTransformStore.shared.setHidden(clip.id)
            playback.refreshFrame()
        }
    }

    /// The still the view should draw while dragging, if there is one.
    func dragPreview(for id: UUID) -> UIImage? {
        guard LiveTransformStore.shared.hiddenClipID == id else { return nil }
        return LayerPreviewCache.shared.cached(id)
    }

    func dragTransform(_ id: UUID, to value: ClipTransform) {
        LiveTransformStore.shared.set(value, for: id)
        playback.refreshFrame()
    }

    /// Release: the value lands in the project once — one undo step, one
    /// rebuild — and the live override is dropped in the same breath so the
    /// picture never flickers back to where it was.
    func commitTransform(_ id: UUID, to value: ClipTransform) {
        LiveTransformStore.shared.setDragging(false)
        LiveTransformStore.shared.setHidden(nil)
        guard var clip = project.clip(id) else {
            LiveTransformStore.shared.set(nil, for: id)
            return
        }
        if var keys = clip.motionKeys, keys.isActive {
            keys.set(value, at: localTime(of: clip))
            clip.motionKeys = keys
        } else {
            clip.setBaseTransform(value)
        }
        project.update(clip)
        LiveTransformStore.shared.set(nil, for: id)
    }

    func cancelTransformDrag(_ id: UUID) {
        LiveTransformStore.shared.setDragging(false)
        LiveTransformStore.shared.setHidden(nil)
        LiveTransformStore.shared.set(nil, for: id)
        playback.refreshFrame()
    }

    /// A layer's rect for a framing the project doesn't know about yet.
    func canvasFrame(of clip: TimelineClip, using transform: ClipTransform) -> CGRect? {
        guard let natural = layerSizes[clip.id], natural.width > 0 else { return nil }
        let canvas = project.aspect.renderSize
        let width = clip.usesPlacement
            ? canvas.width * transform.scale
            : natural.width * transform.scale
        let stretch = transform.heightScale / max(0.0001, transform.scale)
        let height = width * natural.height / max(1, natural.width) * stretch
        return CGRect(x: canvas.width * transform.centerX - width / 2,
                      y: canvas.height * transform.centerY - height / 2,
                      width: width, height: height)
    }

    // MARK: - The lozenges

    /// Off: start the track here, pinning what the clip is doing now. On a key:
    /// take that key out. Anywhere else on an animated clip: pin the value it
    /// is already showing, so the next change animates from here.
    func toggleMotionKey(_ id: UUID) {
        guard var clip = project.clip(id) else { return }
        markUndoPoint()
        let at = localTime(of: clip)
        var keys = clip.motionKeys ?? KeyframeTrack<ClipTransform>()
        if keys.index(at: at) != nil {
            keys.removeKey(at: at)
        } else {
            keys.set(liveTransform(of: clip), at: at)
        }
        clip.motionKeys = keys.isActive ? keys : nil
        project.update(clip)
        Haptics.selection()
    }

    func toggleCompositeKey(_ id: UUID) {
        guard var clip = project.clip(id) else { return }
        markUndoPoint()
        let at = localTime(of: clip)
        var keys = clip.compositeKeys ?? KeyframeTrack<CompositeValue>()
        if keys.index(at: at) != nil {
            keys.removeKey(at: at)
        } else {
            keys.set(liveComposite(of: clip), at: at)
        }
        clip.compositeKeys = keys.isActive ? keys : nil
        project.update(clip)
        Haptics.selection()
    }

    func setMotionEasing(_ id: UUID, _ easing: EasingCurve) {
        guard var clip = project.clip(id), var keys = clip.motionKeys else { return }
        markUndoPoint()
        keys.setEasing(easing, at: localTime(of: clip))
        clip.motionKeys = keys
        project.update(clip)
    }

    func setCompositeEasing(_ id: UUID, _ easing: EasingCurve) {
        guard var clip = project.clip(id), var keys = clip.compositeKeys else { return }
        markUndoPoint()
        keys.setEasing(easing, at: localTime(of: clip))
        clip.compositeKeys = keys
        project.update(clip)
    }

    /// The easing on the key the playhead is inside, for the picker to show.
    func motionEasing(of clip: TimelineClip) -> EasingCurve {
        guard let keys = clip.motionKeys,
              let index = keys.governingIndex(at: localTime(of: clip)) else { return .sine }
        return keys.keys[index].easing
    }

    func compositeEasing(of clip: TimelineClip) -> EasingCurve {
        guard let keys = clip.compositeKeys,
              let index = keys.governingIndex(at: localTime(of: clip)) else { return .sine }
        return keys.keys[index].easing
    }

    // MARK: - Canvas geometry

    /// Which visual layer is under this point on the canvas, topmost first.
    /// Unit coordinates, y down, matching how placements are stored.
    func layer(atCanvasPoint point: CGPoint) -> TimelineClip? {
        let canvas = project.aspect.renderSize
        let now = playback.currentTime
        let candidates = project.clips
            .filter { $0.isVisual && $0.isPlaceholder != true }
            .filter { clip in
                let start = project.start(of: clip)
                return now >= start - 0.001 && now < start + clip.effectiveDuration
            }
            .sorted { $0.stackIndex > $1.stackIndex }
        for clip in candidates {
            guard let box = canvasFrame(of: clip) else { continue }
            // Undo the layer's own rotation and it becomes a plain rect test.
            let angle = -liveTransform(of: clip).rotation * .pi / 180
            let dx = point.x * canvas.width - box.midX
            let dy = point.y * canvas.height - box.midY
            let rx = dx * cos(angle) - dy * sin(angle)
            let ry = dx * sin(angle) + dy * cos(angle)
            if abs(rx) <= box.width / 2 && abs(ry) <= box.height / 2 { return clip }
        }
        return nil
    }

    /// A layer's rect in render coordinates at the playhead, y down.
    ///
    /// Stills are sized by the scale directly — it is their width as a fraction
    /// of the canvas. Video scales the aspect fit the compositor already does,
    /// so 1 is the framing you get untouched.
    func canvasFrame(of clip: TimelineClip) -> CGRect? {
        canvasFrame(of: clip, using: liveTransform(of: clip))
    }
}

// MARK: - Length

extension EditorState {

    /// Read a length the way you would say it: "30s", "1.5m", "90". A bare
    /// number is seconds, because that is what people mean.
    static func parseLength(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var multiplier = 1.0
        if trimmed.hasSuffix("m") {
            multiplier = 60
            trimmed.removeLast()
        } else if trimmed.hasSuffix("s") {
            trimmed.removeLast()
        }
        guard let value = Double(trimmed.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value > 0 else { return nil }
        return value * multiplier
    }

    /// Set a clip's length outright. Footage can only be as long as the file
    /// it came from, so video and audio clamp; stills and titles will hold a
    /// frame for as long as you like.
    ///
    /// Returns what the clip actually ended up at, so the field can show you
    /// when a request was cut short rather than silently ignoring it.
    @discardableResult
    func setLength(_ id: UUID, seconds: Double) -> Double {
        guard var clip = project.clip(id) else { return 0 }
        markUndoPoint()
        let wanted = max(0.1, seconds)
        switch clip.kind {
        case .image, .title:
            clip.trimEnd = clip.trimStart + wanted
        case .video, .music, .voiceover, .sfx:
            // The trim window runs at source speed; the timeline sees it
            // divided by the speed, so a 2x clip needs twice the window.
            let window = wanted * max(0.1, clip.speed)
            let available = max(0, clip.assetDuration - clip.trimStart)
            clip.trimEnd = clip.trimStart + min(window, available)
        }
        project.update(clip)
        return clip.effectiveDuration
    }
}
