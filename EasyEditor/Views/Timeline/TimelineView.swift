import SwiftUI

/// FCP-style magnetic timeline. The playhead is fixed at the horizontal
/// center; the content scrolls under it. Lanes, top to bottom:
/// titles (1/5 primary height) · images (1/3) · b-roll (1/2) ·
/// primary storyline · voice/SFX · music.
///
/// Dragging a clip vertically across lane bands fires a medium haptic each
/// time it crosses into a new layer; magnetic reorder inside the storyline
/// fires light snap ticks.
struct TimelineView: View {
    @EnvironmentObject private var editor: EditorState
    @Binding var transitionAfterClipID: UUID?
    @Binding var showInspector: Bool
    var onAddMedia: () -> Void = {}
    var onAddSound: () -> Void = {}

    // MARK: Metrics

    private let primaryHeight: CGFloat = 56
    private let laneGap: CGFloat = 4
    private let rulerHeight: CGFloat = 18

    private var laneHeights: [(lane: Lane, height: CGFloat)] {
        [
            (.titles, primaryHeight / 5),
            (.images, primaryHeight / 3),
            (.broll, primaryHeight / 2),
            (.primary, primaryHeight),
            (.voice, 20),
            (.music, 24),
        ]
    }

    private func laneTop(_ lane: Lane) -> CGFloat {
        var y = rulerHeight + laneGap
        for entry in laneHeights {
            if entry.lane == lane { return y }
            y += entry.height + laneGap
        }
        return y
    }

    private func laneHeight(_ lane: Lane) -> CGFloat {
        laneHeights.first { $0.lane == lane }?.height ?? primaryHeight
    }

    private func laneCenterY(_ lane: Lane) -> CGFloat {
        laneTop(lane) + laneHeight(lane) / 2
    }

    private func laneAt(y: CGFloat) -> Lane? {
        for entry in laneHeights {
            let top = laneTop(entry.lane)
            if y >= top - laneGap / 2 && y < top + entry.height + laneGap / 2 {
                return entry.lane
            }
        }
        return nil
    }

    private var totalHeight: CGFloat {
        rulerHeight + laneGap + laneHeights.reduce(0) { $0 + $1.height + laneGap } + 6
    }

    // MARK: Gesture state

    @State private var scrubStartTime: Double?
    @State private var zoomStartScale: CGFloat?

    @State private var dragClipID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var proposedLane: Lane?
    @State private var proposedIndex: Int?

    @State private var trimOriginal: TimelineClip?

    var body: some View {
        GeometryReader { geo in
            let pps = editor.pixelsPerSecond
            let centerX = geo.size.width / 2
            let time = editor.playback.currentTime

            ZStack(alignment: .topLeading) {
                content(pps: pps, viewportWidth: geo.size.width)
                    .offset(x: centerX - CGFloat(time) * pps)

                // Fixed playhead.
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: totalHeight - 4)
                    .position(x: centerX, y: (totalHeight - 4) / 2 + 2)
                    .allowsHitTesting(false)

                // TikTok-style "Add sound" pill, pinned while the music lane is empty.
                if editor.project.clips(in: .music).isEmpty && editor.project.clips(in: .voice).isEmpty {
                    Button(action: onAddSound) {
                        Label("Add sound", systemImage: "music.note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .position(x: geo.size.width / 2, y: laneCenterY(.music))
                }
            }
            .frame(width: geo.size.width, height: totalHeight, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(scrubGesture(pps: pps))
            .simultaneousGesture(zoomGesture)
        }
        .frame(height: totalHeight)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    // MARK: - Content

    private func content(pps: CGFloat, viewportWidth: CGFloat) -> some View {
        let duration = max(editor.project.duration, 1)
        let contentWidth = CGFloat(duration) * pps + viewportWidth

        return ZStack(alignment: .topLeading) {
            RulerView(duration: duration, pixelsPerSecond: pps, height: rulerHeight)
                .frame(width: contentWidth, height: rulerHeight, alignment: .topLeading)

            ForEach(laneHeights, id: \.lane) { entry in
                laneView(entry.lane, height: entry.height, pps: pps, width: contentWidth)
                    .offset(y: laneTop(entry.lane))
            }

            transitionButtons(pps: pps)

            addMediaButton(pps: pps)
        }
        .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
    }

    private func laneView(_ lane: Lane, height: CGFloat, pps: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(lane == .primary ? 0.05 : 0.025))
                .frame(width: width, height: height)

            ForEach(editor.project.clips(in: lane)) { clip in
                clipView(clip, laneHeight: height, pps: pps)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    @ViewBuilder
    private func clipView(_ clip: TimelineClip, laneHeight: CGFloat, pps: CGFloat) -> some View {
        let start = editor.project.start(of: clip)
        let width = CGFloat(clip.effectiveDuration) * pps
        let isDragging = dragClipID == clip.id

        ClipChipView(clip: clip,
                     projectID: editor.project.id,
                     width: width,
                     height: laneHeight,
                     isSelected: editor.selectedClipID == clip.id,
                     onTrim: { edge, delta, ended in
                         handleTrim(clip: clip, edge: edge, deltaPoints: delta, pps: pps, ended: ended)
                     })
            .offset(x: CGFloat(start) * pps)
            .offset(isDragging ? dragTranslation : .zero)
            .offset(y: isDragging ? laneOffsetForProposal(from: clip.lane) : 0)
            .scaleEffect(isDragging ? 1.04 : 1)
            .shadow(color: isDragging ? .black.opacity(0.6) : .clear, radius: 8, y: 3)
            .zIndex(isDragging ? 10 : (editor.selectedClipID == clip.id ? 5 : 0))
            .opacity(isDragging ? 0.9 : 1)
            .onTapGesture {
                if editor.selectedClipID == clip.id {
                    showInspector = true
                } else {
                    editor.selectedClipID = clip.id
                    Haptics.selection()
                }
            }
            .gesture(moveGesture(clip: clip, pps: pps))
            .animation(.snappy(duration: 0.2), value: editor.project.clips)
    }

    /// While dragging, visually pull the chip toward the proposed lane's band.
    private func laneOffsetForProposal(from original: Lane) -> CGFloat {
        guard let proposedLane, proposedLane != original else { return 0 }
        return laneCenterY(proposedLane) - laneCenterY(original) - dragTranslation.height
    }

    // MARK: - Transition buttons ("+" between storyline clips)

    @ViewBuilder
    private func transitionButtons(pps: CGFloat) -> some View {
        let ordered = editor.project.primaryClips
        let starts = editor.project.primaryStartTimes
        ForEach(Array(ordered.dropLast().enumerated()), id: \.element.id) { index, clip in
            let next = ordered[index + 1]
            let boundary = starts[next.id] ?? 0
            let hasTransition = (clip.transitionToNext?.style ?? .none) != .none
            Button {
                editor.playback.pause()
                transitionAfterClipID = clip.id
            } label: {
                Image(systemName: hasTransition
                      ? "square.filled.on.square"
                      : "square.on.square.dashed")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hasTransition ? .black : .white)
                    .frame(width: 20, height: 20)
                    .background(hasTransition ? Color.orange : Color(white: 0.25),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
            .position(x: CGFloat(boundary) * pps,
                      y: laneTop(.primary) - 12)
            .zIndex(20)
        }
    }

    private func addMediaButton(pps: CGFloat) -> some View {
        let end = editor.project.storylineDuration
        return Button(action: onAddMedia) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
        .offset(x: CGFloat(end) * pps + 8,
                y: laneTop(.primary) + (primaryHeight - 30) / 2)
    }

    // MARK: - Scrub & zoom

    private func scrubGesture(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if scrubStartTime == nil {
                    scrubStartTime = editor.playback.currentTime
                }
                let delta = Double(-value.translation.width / pps)
                editor.scrub(to: (scrubStartTime ?? 0) + delta)
            }
            .onEnded { _ in
                scrubStartTime = nil
                editor.endScrub()
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStartScale == nil { zoomStartScale = editor.pixelsPerSecond }
                editor.pixelsPerSecond = min(300, max(10, (zoomStartScale ?? 60) * value))
            }
            .onEnded { _ in zoomStartScale = nil }
    }

    // MARK: - Clip move (magnetic, with lane-crossing haptics)

    private func moveGesture(clip: TimelineClip, pps: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else {
                    if case .second(true, nil) = value, dragClipID == nil {
                        // Long press recognized; lift the clip.
                        dragClipID = clip.id
                        editor.selectedClipID = clip.id
                        editor.playback.pause()
                        Haptics.selection()
                    }
                    return
                }
                dragClipID = clip.id
                dragTranslation = drag.translation

                // Vertical: which lane band is the clip's center over?
                let centerY = laneCenterY(clip.lane) + drag.translation.height
                let allowed = Lane.allowed(for: clip.kind)
                var target = laneAt(y: centerY) ?? clip.lane
                if !allowed.contains(target) {
                    // Snap to the nearest allowed band instead.
                    target = allowed.min(by: {
                        abs(laneCenterY($0) - centerY) < abs(laneCenterY($1) - centerY)
                    }) ?? clip.lane
                }
                if target != (proposedLane ?? clip.lane) {
                    // Crossing into another layer — the moment you asked to feel.
                    Haptics.laneChange()
                }
                proposedLane = target

                // Horizontal: magnetic insertion point inside the storyline.
                if target == .primary {
                    let newStart = editor.project.start(of: clip) + Double(drag.translation.width / pps)
                    let index = primaryInsertionIndex(excluding: clip.id,
                                                     forTime: newStart + clip.effectiveDuration / 2)
                    if index != proposedIndex {
                        if proposedIndex != nil { Haptics.snap() }
                        proposedIndex = index
                    }
                }
            }
            .onEnded { value in
                defer {
                    dragClipID = nil
                    dragTranslation = .zero
                    proposedLane = nil
                    proposedIndex = nil
                }
                guard case .second(true, let drag?) = value, let dragged = editor.project.clip(clip.id) else { return }
                let pps = editor.pixelsPerSecond
                let newStart = editor.project.start(of: dragged) + Double(drag.translation.width / pps)
                let target = proposedLane ?? dragged.lane

                if target != dragged.lane {
                    editor.beginGesture()
                    editor.moveToLane(dragged.id, lane: target, timelineTime: max(0, newStart))
                    Haptics.drop()
                } else if target == .primary {
                    let index = proposedIndex ?? dragged.order
                    if index != dragged.order {
                        editor.beginGesture()
                        editor.reorderPrimary(dragged.id, to: index)
                        Haptics.drop()
                    }
                } else if abs(drag.translation.width) > 2 {
                    editor.beginGesture()
                    let snapped = snapOffset(max(0, newStart), pps: pps)
                    editor.mutateLive(dragged.id) { $0.offset = snapped }
                    Haptics.drop()
                }
            }
    }

    private func primaryInsertionIndex(excluding id: UUID, forTime time: Double) -> Int {
        let starts = editor.project.primaryStartTimes
        let ordered = editor.project.primaryClips.filter { $0.id != id }
        for (i, c) in ordered.enumerated() {
            let mid = (starts[c.id] ?? 0) + c.effectiveDuration / 2
            if time < mid { return i }
        }
        return ordered.count
    }

    /// Magnetic snap for connected clips: playhead, timeline start, storyline end.
    private func snapOffset(_ offset: Double, pps: CGFloat) -> Double {
        let candidates = [editor.playback.currentTime, 0, editor.project.storylineDuration]
        for c in candidates where abs(offset - c) * pps < 10 {
            return c
        }
        return offset
    }

    // MARK: - Trim

    private func handleTrim(clip: TimelineClip, edge: ClipChipView.TrimEdge,
                            deltaPoints: CGFloat, pps: CGFloat, ended: Bool) {
        if trimOriginal == nil {
            trimOriginal = clip
            editor.beginGesture()
        }
        guard let original = trimOriginal else { return }
        let deltaSeconds = Double(deltaPoints / pps)

        editor.mutateLive(clip.id) { c in
            switch (edge, original.kind) {
            case (.leading, .video), (.leading, .music), (.leading, .voiceover), (.leading, .sfx):
                let sourceDelta = deltaSeconds * original.speed
                let newStart = min(max(0, original.trimStart + sourceDelta),
                                   original.trimEnd - 0.1 * original.speed)
                c.trimStart = newStart
                if original.lane != .primary {
                    // Keep the right edge planted.
                    c.offset = original.offset + (newStart - original.trimStart) / original.speed
                }
            case (.trailing, .video), (.trailing, .music), (.trailing, .voiceover), (.trailing, .sfx):
                c.trimEnd = min(max(original.trimStart + 0.1 * original.speed,
                                    original.trimEnd + deltaSeconds * original.speed),
                                original.assetDuration)
            case (.leading, .image), (.leading, .title):
                let newLength = max(0.3, original.trimEnd - deltaSeconds)
                c.trimEnd = newLength
                c.offset = original.offset + (original.trimEnd - newLength)
            case (.trailing, .image), (.trailing, .title):
                c.trimEnd = max(0.3, original.trimEnd + deltaSeconds)
            }
        }
        if ended {
            trimOriginal = nil
            Haptics.snap()
        }
    }
}

// MARK: - Ruler

/// Seconds ruler across the top of the timeline ("3.5s · 4s · 4.5s…").
private struct RulerView: View {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            let step: Double = pixelsPerSecond > 90 ? 0.5 : (pixelsPerSecond > 30 ? 1 : 5)
            var t: Double = 0
            while t <= duration + step {
                let x = CGFloat(t) * pixelsPerSecond
                let isMajor = t.truncatingRemainder(dividingBy: max(step * 2, 1)) < 0.001
                let tickHeight: CGFloat = isMajor ? 6 : 3
                context.fill(
                    Path(CGRect(x: x, y: size.height - tickHeight, width: 1, height: tickHeight)),
                    with: .color(.white.opacity(0.35)))
                if isMajor {
                    context.draw(
                        Text(TimeFormat.ruler(t))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.5)),
                        at: CGPoint(x: x, y: size.height - 12),
                        anchor: .center)
                }
                t += step
            }
        }
        .frame(height: height)
    }
}
