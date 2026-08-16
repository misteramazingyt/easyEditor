import Foundation
import AVFoundation
import CoreImage

/// Everything AVFoundation needs to play or export a project.
struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix?
    let duration: Double
}

/// Translates a `VideoProject` into an AVMutableComposition plus custom
/// compositor instructions. Primary clips alternate between two video tracks
/// so transitions can overlap; every b-roll/audio clip gets its own track.
struct CompositionEngine {

    enum EngineError: Error {
        case noVideoContent
        case trackCreationFailed
    }

    private static let timescale: CMTimeScale = 600

    private struct PlacedVideo {
        let clip: TimelineClip
        let trackID: CMPersistentTrackID
        let orientation: CGAffineTransform
        let start: Double
        let end: Double
        let isBroll: Bool
    }

    /// Build the playable/exportable graph. `overlayImages` maps image/title
    /// clip IDs to pre-rendered CIImages (see `renderOverlayImages`).
    func build(project rawProject: VideoProject,
               overlayImages: [UUID: CIImage]) async throws -> BuiltComposition {
        // A clip still being recorded has no finished file yet.
        var project = rawProject
        project.clips.removeAll { $0.isLiveRecording == true }
        let composition = AVMutableComposition()
        let ordered = project.primaryClips.filter { $0.fileName != nil }
        guard !ordered.isEmpty else { throw EngineError.noVideoContent }

        guard let videoA = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioA = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioB = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EngineError.trackCreationFailed
        }

        var placed: [PlacedVideo] = []
        var mixParams: [AVMutableAudioMixInputParameters] = []
        let paramsA = AVMutableAudioMixInputParameters(track: audioA)
        let paramsB = AVMutableAudioMixInputParameters(track: audioB)
        mixParams.append(contentsOf: [paramsA, paramsB])

        // MARK: Primary storyline (magnetic, A/B alternating)
        let starts = project.primaryStartTimes
        for (index, clip) in ordered.enumerated() {
            guard let fileName = clip.fileName else { continue }
            let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
                Log.engine.error("No video track in \(fileName)")
                continue
            }
            let orientation = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let start = starts[clip.id] ?? 0
            let videoTrack = index.isMultiple(of: 2) ? videoA : videoB
            let audioTrack = index.isMultiple(of: 2) ? audioA : audioB
            let params = index.isMultiple(of: 2) ? paramsA : paramsB

            let requested = CMTimeRange(
                start: CMTime(seconds: clip.trimStart, preferredTimescale: Self.timescale),
                end: CMTime(seconds: min(clip.trimEnd, clip.assetDuration), preferredTimescale: Self.timescale))
            // Float rounding can push trimEnd a hair past the real media end,
            // which makes insertTimeRange throw — clamp to the track's range.
            let videoTrackRange = (try? await sourceVideo.load(.timeRange))
                ?? CMTimeRange(start: .zero, duration: asset.duration)
            let sourceRange = CMTimeRangeGetIntersection(requested, otherRange: videoTrackRange)
            guard sourceRange.duration.seconds > 0.04 else {
                Log.engine.error("Empty source range for \(fileName)")
                continue
            }
            let at = CMTime(seconds: start, preferredTimescale: Self.timescale)
            do {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: at)
            } catch {
                Log.engine.error("Video insert failed: \(error.localizedDescription)")
                continue
            }
            let effective = CMTime(seconds: clip.effectiveDuration, preferredTimescale: Self.timescale)
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                          toDuration: effective)
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                do {
                    let audioTrackRange = (try? await sourceAudio.load(.timeRange)) ?? videoTrackRange
                    let audioRange = CMTimeRangeGetIntersection(sourceRange, otherRange: audioTrackRange)
                    if audioRange.duration.seconds > 0.04 {
                        try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: at)
                        if clip.speed != 1 {
                            audioTrack.scaleTimeRange(CMTimeRange(start: at, duration: audioRange.duration),
                                                      toDuration: effective)
                        }
                        params.setVolume(clip.isMuted ? 0 : Float(clip.volume), at: at)
                    }
                } catch {
                    Log.engine.error("Audio insert failed: \(error.localizedDescription)")
                }
            }
            placed.append(PlacedVideo(clip: clip, trackID: videoTrack.trackID,
                                      orientation: orientation,
                                      start: start, end: start + clip.effectiveDuration,
                                      isBroll: false))
        }
        guard placed.contains(where: { !$0.isBroll }) else { throw EngineError.noVideoContent }

        // MARK: Connected b-roll (own track per clip; stacks over the storyline)
        let brolls = project.clips
            .filter { $0.kind == .video && $0.lane != .primary && $0.fileName != nil }
            .sorted { ($0.stackIndex, $0.offset) < ($1.stackIndex, $1.offset) }
        for clip in brolls {
            guard let fileName = clip.fileName,
                  let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let orientation = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let requested = CMTimeRange(
                start: CMTime(seconds: clip.trimStart, preferredTimescale: Self.timescale),
                end: CMTime(seconds: min(clip.trimEnd, clip.assetDuration), preferredTimescale: Self.timescale))
            let trackRange = (try? await sourceVideo.load(.timeRange))
                ?? CMTimeRange(start: .zero, duration: asset.duration)
            let sourceRange = CMTimeRangeGetIntersection(requested, otherRange: trackRange)
            guard sourceRange.duration.seconds > 0.04 else { continue }
            let at = CMTime(seconds: clip.offset, preferredTimescale: Self.timescale)
            do {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: at)
            } catch { continue }
            let effective = CMTime(seconds: clip.effectiveDuration, preferredTimescale: Self.timescale)
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                          toDuration: effective)
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: at)
                if clip.speed != 1 {
                    audioTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                              toDuration: effective)
                }
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.setVolume(clip.isMuted ? 0 : Float(clip.volume), at: .zero)
                mixParams.append(params)
            }
            placed.append(PlacedVideo(clip: clip, trackID: videoTrack.trackID,
                                      orientation: orientation,
                                      start: clip.offset, end: clip.offset + clip.effectiveDuration,
                                      isBroll: true))
        }

        // MARK: Music / voiceover / SFX
        let audioClips = project.clips.filter {
            [.music, .voiceover, .sfx].contains($0.kind) && $0.fileName != nil
        }
        for clip in audioClips {
            guard let fileName = clip.fileName,
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            let asset = AVURLAsset(url: url)
            guard let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            let requested = CMTimeRange(
                start: CMTime(seconds: clip.trimStart, preferredTimescale: Self.timescale),
                end: CMTime(seconds: min(clip.trimEnd, clip.assetDuration), preferredTimescale: Self.timescale))
            let trackRange = (try? await sourceAudio.load(.timeRange))
                ?? CMTimeRange(start: .zero, duration: asset.duration)
            let sourceRange = CMTimeRangeGetIntersection(requested, otherRange: trackRange)
            guard sourceRange.duration.seconds > 0.04 else { continue }
            let at = CMTime(seconds: clip.offset, preferredTimescale: Self.timescale)
            do {
                try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: at)
            } catch { continue }
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(clip.isMuted ? 0 : Float(clip.volume), at: .zero)
            mixParams.append(params)
        }

        // MARK: Compositor instructions
        let renderSize = project.aspect.renderSize
        let overlayClips = project.clips.filter {
            ($0.kind == .image || $0.kind == .title) && overlayImages[$0.id] != nil
        }
        let videoComposition = buildInstructions(
            project: project, placed: placed, overlayClips: overlayClips,
            overlayImages: overlayImages, renderSize: renderSize,
            compositionDuration: composition.duration.seconds)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: audioMix,
                                duration: composition.duration.seconds)
    }

    /// Pre-render every image/title clip once; the compositor stamps these per frame.
    func renderOverlayImages(project: VideoProject) async -> [UUID: CIImage] {
        var result: [UUID: CIImage] = [:]
        let canvasWidth = project.aspect.renderSize.width
        for clip in project.clips {
            switch clip.kind {
            case .title:
                if let payload = clip.text,
                   let image = OverlayRenderer.render(text: payload, canvasWidth: canvasWidth) {
                    result[clip.id] = image
                }
            case .image:
                if let fileName = clip.fileName {
                    let url = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
                    if let image = OverlayRenderer.render(imageURL: url, cutout: clip.cutout) {
                        result[clip.id] = image
                    }
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Focus windows (main-track blur/darken under connected clips)

    /// Union of visibility ranges of focus-enabled connected clips: the fade
    /// begins at the first clip's entrance and ends at the last clip's exit,
    /// so overlapping clips never stack fades.
    private struct FocusWindow {
        var start: Double
        var end: Double
        var fadeIn: Double
        var fadeOut: Double
        var style: FocusStyle
    }

    private func focusWindows(project: VideoProject) -> [FocusWindow] {
        let focusClips = project.clips
            .filter { $0.lane != .primary && $0.isVisual && ($0.focus ?? FocusStyle.none) != FocusStyle.none }
            .sorted { $0.offset < $1.offset }
        var windows: [FocusWindow] = []
        for clip in focusClips {
            let start = clip.offset
            let end = start + clip.effectiveDuration
            let fadeIn = clip.inOut?.begin.durationSeconds ?? 0.3
            let fadeOut = clip.inOut?.end.durationSeconds ?? 0.3
            if let last = windows.last, start <= last.end + 0.01 {
                windows[windows.count - 1].end = max(last.end, end)
                if end >= windows[windows.count - 1].end - 0.001 {
                    windows[windows.count - 1].fadeOut = fadeOut
                }
            } else {
                windows.append(FocusWindow(start: start, end: end,
                                           fadeIn: fadeIn, fadeOut: fadeOut,
                                           style: clip.focus ?? .none))
            }
        }
        return windows
    }

    private func focusAmount(_ window: FocusWindow, at t: Double) -> Double {
        if t <= window.start || t >= window.end { return 0 }
        if t < window.start + window.fadeIn {
            return (t - window.start) / max(0.01, window.fadeIn)
        }
        if t > window.end - window.fadeOut {
            return (window.end - t) / max(0.01, window.fadeOut)
        }
        return 1
    }

    // MARK: - Instruction tiling

    private func buildInstructions(project: VideoProject,
                                   placed: [PlacedVideo],
                                   overlayClips: [TimelineClip],
                                   overlayImages: [UUID: CIImage],
                                   renderSize: CGSize,
                                   compositionDuration: Double) -> AVMutableVideoComposition? {
        let epsilon = 1.0 / 240.0
        let duration = max(compositionDuration, project.duration)
        guard duration > 0 else { return nil }

        // Boundary times: clip edges, transition sub-midpoints, overlay edges.
        var boundaries: Set<Int> = [0, quantize(duration)]
        for p in placed {
            boundaries.insert(quantize(p.start))
            boundaries.insert(quantize(p.end))
        }
        let primaries = placed.filter { !$0.isBroll }.sorted { $0.start < $1.start }
        for i in 0..<max(0, primaries.count - 1) {
            let a = primaries[i], b = primaries[i + 1]
            // Overlap region is [b.start, a.end); fadeToBlack needs its midpoint.
            if a.clip.transitionToNext?.style == .fadeToBlack, b.start < a.end {
                boundaries.insert(quantize((b.start + a.end) / 2))
            }
        }
        for clip in overlayClips {
            boundaries.insert(quantize(clip.offset))
            boundaries.insert(quantize(clip.offset + clip.effectiveDuration))
        }
        let windows = focusWindows(project: project)
        for window in windows {
            boundaries.insert(quantize(window.start))
            boundaries.insert(quantize(min(window.end, window.start + window.fadeIn)))
            boundaries.insert(quantize(max(window.start, window.end - window.fadeOut)))
            boundaries.insert(quantize(window.end))
        }

        let times = boundaries.map { Double($0) / 600.0 }
            .filter { $0 >= 0 && $0 <= duration + epsilon }
            .sorted()

        var instructions: [CompositorInstruction] = []
        for i in 0..<max(0, times.count - 1) {
            // Boundaries are distinct quantized ticks, so every interval has
            // positive length; never skip one — a gap in the instruction
            // tiling makes the player item fail outright.
            let t0 = times[i], t1 = times[i + 1]
            let mid = (t0 + t1) / 2

            var layers: [CompositorLayer] = []
            let focusWindow = windows.first { $0.start - epsilon <= mid && mid < $0.end }

            func applyFocus(_ layer: inout CompositorLayer) {
                guard let focusWindow else { return }
                layer.focusStyle = focusWindow.style
                layer.focusStart = focusAmount(focusWindow, at: t0)
                layer.focusEnd = focusAmount(focusWindow, at: t1)
            }

            // Active primary clips (max two during a transition overlap).
            let active = primaries.filter { $0.start - epsilon <= mid && mid < $0.end - epsilon }
                .sorted { $0.start < $1.start }
            if active.count == 2 {
                let outgoing = active[0], incoming = active[1]
                let transition = outgoing.clip.transitionToNext ?? Transition()
                let regionStart = incoming.start
                let regionEnd = outgoing.end
                var a = layerConfig(for: outgoing, t0: t0, t1: t1,
                                    role: .outgoing, style: transition.style,
                                    regionStart: regionStart, regionEnd: regionEnd)
                var b = layerConfig(for: incoming, t0: t0, t1: t1,
                                    role: .incoming, style: transition.style,
                                    regionStart: regionStart, regionEnd: regionEnd)
                applyFocus(&a)
                applyFocus(&b)
                layers.append(a)
                layers.append(b)
            } else if let solo = active.first {
                var layer = layerConfig(for: solo, t0: t0, t1: t1,
                                        role: .solo, style: .none,
                                        regionStart: 0, regionEnd: 0)
                applyFocus(&layer)
                layers.append(layer)
            }

            // Connected video layers stack over the storyline, lowest slot first.
            for broll in placed.filter({ $0.isBroll })
                .sorted(by: { $0.clip.stackIndex < $1.clip.stackIndex }) {
                if broll.start - epsilon <= mid && mid < broll.end - epsilon {
                    var layer = layerConfig(for: broll, t0: t0, t1: t1,
                                            role: .solo, style: .none,
                                            regionStart: 0, regionEnd: 0)
                    layer.clipStart = broll.start
                    layer.clipEnd = broll.end
                    layer.inOut = broll.clip.inOut
                    layer.loop = broll.clip.loopFx
                    layer.compositing = broll.clip.compositing
                    layers.append(layer)
                }
            }

            // Still overlays (images/titles), lowest stacking slot first.
            var overlays: [CompositorOverlay] = []
            for clip in overlayClips.sorted(by: { $0.stackIndex < $1.stackIndex }) {
                let start = clip.offset, end = clip.offset + clip.effectiveDuration
                if start - epsilon <= mid && mid < end - epsilon,
                   let image = overlayImages[clip.id] {
                    overlays.append(CompositorOverlay(image: image,
                                                      placement: clip.placement ?? .image,
                                                      clipStart: start,
                                                      clipEnd: end,
                                                      inOut: clip.inOut,
                                                      loop: clip.loopFx,
                                                      compositing: clip.compositing))
                }
            }

            let range = CMTimeRange(
                start: CMTime(value: CMTimeValue(quantize(t0)), timescale: Self.timescale),
                end: CMTime(value: CMTimeValue(quantize(t1)), timescale: Self.timescale))
            instructions.append(CompositorInstruction(timeRange: range,
                                                      layers: layers, overlays: overlays))
        }
        guard !instructions.isEmpty else { return nil }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = LayeredCompositor.self
        videoComposition.instructions = instructions
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize
        return videoComposition
    }

    private enum LayerRole { case solo, outgoing, incoming }

    private func layerConfig(for placedClip: PlacedVideo, t0: Double, t1: Double,
                             role: LayerRole, style: TransitionStyle,
                             regionStart: Double, regionEnd: Double) -> CompositorLayer {
        let clip = placedClip.clip
        var layer = CompositorLayer(trackID: placedClip.trackID,
                                    orientation: placedClip.orientation,
                                    filter: clip.filter,
                                    adjustments: clip.adjustments,
                                    rotationQuarterTurns: clip.rotationQuarterTurns,
                                    isFlippedH: clip.isFlippedH,
                                    effect: clip.effect,
                                    mask: clip.mask,
                                    cutout: clip.cutout)
        layer.startOpacity = clip.effectiveOpacity
        layer.endOpacity = clip.effectiveOpacity
        guard role != .solo, regionEnd > regionStart else { return layer }

        // Normalized transition progress at this instruction's endpoints.
        let span = regionEnd - regionStart
        let p0 = min(1, max(0, (t0 - regionStart) / span))
        let p1 = min(1, max(0, (t1 - regionStart) / span))

        let baseOpacity = clip.effectiveOpacity
        switch (style, role) {
        case (.crossDissolve, .incoming), (.zoom, .incoming):
            layer.startOpacity = p0 * baseOpacity
            layer.endOpacity = p1 * baseOpacity
            if style == .zoom {
                layer.startScale = 1.25 - 0.25 * p0
                layer.endScale = 1.25 - 0.25 * p1
            }
        case (.fadeToBlack, .outgoing):
            // Fades out across the first half of the region.
            layer.startOpacity = (1 - min(1, p0 * 2)) * baseOpacity
            layer.endOpacity = (1 - min(1, p1 * 2)) * baseOpacity
        case (.fadeToBlack, .incoming):
            // Fades in across the second half.
            layer.startOpacity = max(0, p0 * 2 - 1) * baseOpacity
            layer.endOpacity = max(0, p1 * 2 - 1) * baseOpacity
        case (.slideLeft, .incoming):
            layer.startTranslationX = 1 - p0
            layer.endTranslationX = 1 - p1
        case (.slideRight, .incoming):
            layer.startTranslationX = -(1 - p0)
            layer.endTranslationX = -(1 - p1)
        default:
            break
        }
        return layer
    }

    /// Quantize seconds to 1/600 ticks so boundary comparisons are exact.
    private func quantize(_ seconds: Double) -> Int {
        Int((seconds * 600).rounded())
    }
}
