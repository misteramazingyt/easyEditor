import SwiftUI

/// FCP-style magnetic timeline on a pure black canvas — no fixed lane bands.
/// The storyline (slot 0) is magnetic; any number of connected clips stack
/// above it (+1, +2, …) and audio stacks below (-1, -2, …). Drag the
/// background horizontally to scrub and vertically to scroll the stack;
/// pinch to zoom. Clip heights follow their kind: titles are 1/5 the
/// storyline height, images 1/3, connected video 1/2.
///
/// Long-press-drag a clip vertically to move it between slots — a medium
/// haptic fires at every slot crossing, a rigid tap on drop. Dropping onto
/// occupied time bumps outward to the nearest free slot.
struct TimelineView: View {
    @EnvironmentObject private var editor: EditorState
    @Binding var transitionAfterClipID: UUID?
    @Binding var showInspector: Bool
    var onAddMedia: () -> Void = {}
    var onAddSound: () -> Void = {}

    // MARK: Metrics

    private let primaryHeight: CGFloat = 56
    private let rowGap: CGFloat = 3
    private let rulerHeight: CGFloat = 18
    /// Fixed rows-viewport height: stacks taller than this scroll vertically.
    private let viewportRowsHeight: CGFloat = 172

    private struct Row: Identifiable {
        let index: Int      // stacking slot; 0 = storyline
        let height: CGFloat
        let y: CGFloat      // top, in rows-content coordinates
        var id: Int { index }
        var centerY: CGFloat { y + height / 2 }
    }

    private func chipHeight(for clip: TimelineClip) -> CGFloat {
        switch clip.kind {
        case .video: return clip.lane == .primary ? primaryHeight : primaryHeight / 2
        case .image: return primaryHeight / 3
        case .title: return primaryHeight / 5
        case .voiceover, .sfx: return 20
        case .music: return 24
        }
    }

    /// Dynamic rows, top to bottom, with one empty slot beyond each extreme
    /// so a drag can always create a new layer.
    private var rows: [Row] {
        let top = editor.project.maxStackAbove + 1
        let bottom = editor.project.minStackBelow - 1
        var indices: [Int] = Array((1...max(1, top)).reversed())
        indices.append(0)
        indices.append(contentsOf: stride(from: -1, through: min(-1, bottom), by: -1))

        var result: [Row] = []
        var y: CGFloat = 2
        for index in indices {
            let height = rowHeight(index)
            result.append(Row(index: index, height: height, y: y))
            y += height + rowGap
        }
        return result
    }

    private func rowHeight(_ index: Int) -> CGFloat {
        if index == 0 { return primaryHeight }
        let occupants = editor.project.clips(stackedAt: index)
        let emptyTarget: CGFloat = index > 0 ? primaryHeight / 3 : 22
        return max(occupants.map(chipHeight).max() ?? 0, emptyTarget)
    }

    private func rowsHeight(_ rows: [Row]) -> CGFloat {
        (rows.last.map { $0.y + $0.height } ?? 0) + 4
    }

    private func row(at contentY: CGFloat, in rows: [Row]) -> Row? {
        rows.first { contentY >= $0.y - rowGap / 2 && contentY < $0.y + $0.height + rowGap / 2 }
    }

    private func row(_ index: Int, in rows: [Row]) -> Row? {
        rows.first { $0.index == index }
    }

    /// Slots a clip of this kind may occupy.
    private func allowedRow(_ index: Int, for kind: ClipKind) -> Bool {
        switch kind {
        case .video: return index >= 0
        case .image, .title: return index >= 1
        case .music, .voiceover, .sfx: return index <= -1
        }
    }

    // MARK: Gesture state

    @State private var panStart: (time: Double, anchor: CGFloat)?
    @State private var zoomStartScale: CGFloat?
    /// Distance from the viewport top to the storyline row's top — keeps the
    /// storyline visually stable as stacks grow. Negative = scrolled up.
    @State private var anchorFromTop: CGFloat = 40

    @State private var dragClipID: UUID?
    @State private var dragGroupID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var proposedRow: Int?
    @State private var proposedIndex: Int?

    @State private var trimOriginal: TimelineClip?

    var body: some View {
        let rows = rows
        let rowsContentHeight = rowsHeight(rows)
        let viewportRows = viewportRowsHeight
        let totalHeight = rulerHeight + viewportRows

        return GeometryReader { geo in
            let pps = editor.pixelsPerSecond
            let centerX = geo.size.width / 2
            let time = editor.playback.currentTime
            let duration = max(editor.project.duration, 1)
            let contentWidth = CGFloat(duration) * pps + geo.size.width
            let xOffset = centerX - CGFloat(time) * pps
            let primaryTop = row(0, in: rows)?.y ?? 0
            let maxScroll = max(0, rowsContentHeight - viewportRows)
            let scrollY = min(max(0, primaryTop - anchorFromTop), maxScroll)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        RulerView(duration: duration, pixelsPerSecond: pps, height: rulerHeight)
                            .frame(width: contentWidth, height: rulerHeight, alignment: .topLeading)
                            .offset(x: xOffset)
                    }
                    .frame(width: geo.size.width, height: rulerHeight, alignment: .topLeading)
                    .clipped()

                    ZStack(alignment: .topLeading) {
                        rowsContent(rows: rows, pps: pps, contentWidth: contentWidth)
                            .offset(x: xOffset, y: -scrollY)
                    }
                    .frame(width: geo.size.width, height: viewportRows, alignment: .topLeading)
                    .clipped()
                }

                // Fixed playhead over ruler + rows.
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: totalHeight - 2)
                    .position(x: centerX, y: totalHeight / 2)
                    .allowsHitTesting(false)

                // "Add sound" pill pinned to the bottom while there's no audio.
                if !editor.project.hasAudioClips {
                    Button(action: onAddSound) {
                        Label("Add sound", systemImage: "music.note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .position(x: centerX, y: totalHeight - 16)
                }
            }
            .frame(width: geo.size.width, height: totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(panGesture(pps: pps, maxScroll: maxScroll, primaryTop: primaryTop, viewportRows: viewportRows))
            .simultaneousGesture(zoomGesture)
        }
        .frame(height: totalHeight)
        .background(Color.black)
    }

    // MARK: - Rows content (one flat black canvas)

    private func rowsContent(rows: [Row], pps: CGFloat, contentWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .frame(width: contentWidth, height: rowsHeight(rows))

            // Faint target highlight for the slot a drag is hovering.
            if let proposedRow, let target = row(proposedRow, in: rows) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: contentWidth, height: target.height)
                    .offset(y: target.y)
            }

            // Taller rows first, shortest last: ZStack hit-testing prefers
            // later views, so tiny title/image chips win over the storyline
            // when their (expanded) tap targets overlap.
            ForEach(rows.sorted { $0.height > $1.height }) { rowEntry in
                let clips = rowEntry.index == 0
                    ? editor.project.primaryClips
                    : editor.project.clips(stackedAt: rowEntry.index)
                ForEach(clips) { clip in
                    clipView(clip, row: rowEntry, rows: rows, pps: pps)
                }
            }

            transitionButtons(rows: rows, pps: pps)
            addMediaButton(rows: rows, pps: pps)
        }
        .frame(width: contentWidth, height: rowsHeight(rows), alignment: .topLeading)
    }

    @ViewBuilder
    private func clipView(_ clip: TimelineClip, row: Row, rows: [Row], pps: CGFloat) -> some View {
        let start = editor.project.start(of: clip)
        let width = CGFloat(clip.effectiveDuration) * pps
        let height = chipHeight(for: clip)
        let isDragging = dragClipID == clip.id
        // Members of a dragged group travel with it, horizontally only.
        let isGroupMember = !isDragging && dragGroupID != nil && clip.groupID == dragGroupID
        let restingY = row.y + (row.height - height) / 2

        ClipChipView(clip: clip,
                     projectID: editor.project.id,
                     width: width,
                     height: height,
                     isSelected: editor.selectedClipIDs.contains(clip.id),
                     showsTrimHandles: editor.selectedClipID == clip.id,
                     onTrim: { edge, delta, ended in
                         handleTrim(clip: clip, edge: edge, deltaPoints: delta, pps: pps, ended: ended)
                     })
            .contentShape(Rectangle().inset(by: height < 26 ? -9 : 0))
            .offset(x: CGFloat(start) * pps, y: restingY)
            .offset(x: isDragging ? dragTranslation.width
                       : (isGroupMember ? dragTranslation.width : 0),
                    y: isDragging ? dragTranslation.height : 0)
            .scaleEffect(isDragging ? 1.04 : 1)
            .shadow(color: isDragging ? .black.opacity(0.8) : .clear, radius: 8, y: 3)
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
            .gesture(moveGesture(clip: clip, rows: rows, pps: pps))
            .animation(.snappy(duration: 0.2), value: editor.project.clips)
    }

    // MARK: - Storyline decorations

    @ViewBuilder
    private func transitionButtons(rows: [Row], pps: CGFloat) -> some View {
        let ordered = editor.project.primaryClips
        let starts = editor.project.primaryStartTimes
        let primaryTop = row(0, in: rows)?.y ?? 0
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
                    .background(hasTransition ? Color.orange : Color(white: 0.22),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
            .position(x: CGFloat(boundary) * pps,
                      y: primaryTop + primaryHeight / 2)
            .zIndex(20)
        }
    }

    private func addMediaButton(rows: [Row], pps: CGFloat) -> some View {
        let end = editor.project.storylineDuration
        let primaryTop = row(0, in: rows)?.y ?? 0
        return Button(action: onAddMedia) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
        .offset(x: CGFloat(end) * pps + 8,
                y: primaryTop + (primaryHeight - 30) / 2)
    }

    // MARK: - Pan (scrub + vertical scroll) & zoom

    private func panGesture(pps: CGFloat, maxScroll: CGFloat,
                            primaryTop: CGFloat, viewportRows: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if panStart == nil {
                    panStart = (editor.playback.currentTime, anchorFromTop)
                }
                guard let panStart else { return }
                let deltaTime = Double(-value.translation.width / pps)
                editor.scrub(to: panStart.time + deltaTime)
                // Finger down = content down = show higher stack rows.
                // Clamp so scrollY = primaryTop - anchor stays in [0, maxScroll].
                let proposedAnchor = panStart.anchor + value.translation.height
                anchorFromTop = min(max(proposedAnchor, primaryTop - maxScroll), primaryTop)
            }
            .onEnded { _ in
                panStart = nil
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

    // MARK: - Clip move (magnetic, unlimited stacking, lane-crossing haptics)

    private func moveGesture(clip: TimelineClip, rows: [Row], pps: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else {
                    if case .second(true, nil) = value, dragClipID == nil {
                        dragClipID = clip.id
                        dragGroupID = clip.groupID
                        editor.selectedClipID = clip.id
                        editor.playback.pause()
                        Haptics.selection()
                    }
                    return
                }
                dragClipID = clip.id
                dragGroupID = clip.groupID
                dragTranslation = drag.translation

                // A group's stagger depends on its lane assignment, so grouped
                // clips slide in time only — no cross-lane moves.
                if clip.groupID != nil {
                    dragTranslation.height = 0
                    return
                }

                // Which slot is the clip's center hovering?
                guard let homeRow = row(clip.stackIndex, in: rows) else { return }
                let centerY = homeRow.centerY + drag.translation.height
                var target = row(at: centerY, in: rows)?.index ?? clip.stackIndex
                if !allowedRow(target, for: clip.kind) {
                    // Snap to the nearest allowed slot instead.
                    target = rows
                        .filter { allowedRow($0.index, for: clip.kind) }
                        .min { abs($0.centerY - centerY) < abs($1.centerY - centerY) }?
                        .index ?? clip.stackIndex
                }
                if target != (proposedRow ?? clip.stackIndex) {
                    // Crossed into another layer.
                    Haptics.laneChange()
                }
                proposedRow = target

                // Magnetic insertion point while hovering the storyline.
                if target == 0 {
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
                    dragGroupID = nil
                    dragTranslation = .zero
                    proposedRow = nil
                    proposedIndex = nil
                }
                guard case .second(true, let drag?) = value,
                      let dragged = editor.project.clip(clip.id) else { return }
                let pps = editor.pixelsPerSecond
                let delta = Double(drag.translation.width / pps)
                let newStart = editor.project.start(of: dragged) + delta

                // Grouped: move every member together, keeping the stagger.
                if let groupID = dragged.groupID {
                    guard abs(drag.translation.width) > 2 else { return }
                    var index: Int?
                    if let primary = editor.project.clips.first(where: {
                        $0.groupID == groupID && $0.lane == .primary
                    }) {
                        let primaryStart = editor.project.start(of: primary) + delta
                        index = primaryInsertionIndex(
                            excluding: primary.id,
                            forTime: primaryStart + primary.effectiveDuration / 2)
                    }
                    editor.moveGroup(dragged.id, deltaSeconds: delta, primaryIndex: index)
                    Haptics.drop()
                    return
                }

                let target = proposedRow ?? dragged.stackIndex

                if target != dragged.stackIndex {
                    editor.beginGesture()
                    editor.moveToStack(dragged.id, rowIndex: target,
                                       timelineTime: max(0, newStart))
                    Haptics.drop()
                } else if target == 0 {
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
