import Foundation
import CoreGraphics

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
        guard let natural = layerSizes[clip.id], natural.width > 0 else { return nil }
        let canvas = project.aspect.renderSize
        let t = liveTransform(of: clip)
        let width = clip.usesPlacement ? canvas.width * t.scale : natural.width * t.scale
        let height = width * natural.height / max(1, natural.width)
        return CGRect(x: canvas.width * t.centerX - width / 2,
                      y: canvas.height * t.centerY - height / 2,
                      width: width, height: height)
    }
}
