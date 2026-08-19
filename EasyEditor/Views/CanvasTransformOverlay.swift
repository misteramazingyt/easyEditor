import SwiftUI

/// Direct manipulation on the canvas, laid out the way Final Cut does it: a
/// thin outline with eight blue handles, a crosshair at the centre to drag the
/// layer by, and a stalk out to the right to turn it.
///
/// When the layer is animating, its path is drawn through the keyframes in
/// red — a chevron at the first, a triangle at the last, diamonds between.
/// Tap a keyframe to work on it: drag the diamond to move where the layer is
/// at that moment, or its handles to bend the curve either side.
///
/// Everything is drawn from the numbers the compositor renders with, mapped
/// through the letterboxed canvas rect, so what you grab is where the picture
/// actually is.
struct CanvasTransformOverlay: View {
    @EnvironmentObject private var editor: EditorState

    @State private var gesture: Gesture?
    @State private var didPushUndo = false
    /// The keyframe whose spline handles are showing.
    @State private var activeKey: UUID?

    private enum Gesture: Equatable {
        case move(startCenter: CGPoint)
        case scale(handle: Handle, startScale: Double, startHeight: Double)
        case rotate(startRotation: Double, startAngle: Double)
        case key(id: UUID)
        case tangent(id: UUID, outgoing: Bool)
    }

    /// The eight box handles, by where they sit.
    private enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        /// Position in the box, -1…1 on each axis.
        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: -1, y: -1)
            case .top: return CGPoint(x: 0, y: -1)
            case .topRight: return CGPoint(x: 1, y: -1)
            case .left: return CGPoint(x: -1, y: 0)
            case .right: return CGPoint(x: 1, y: 0)
            case .bottomLeft: return CGPoint(x: -1, y: 1)
            case .bottom: return CGPoint(x: 0, y: 1)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            }
        }

        /// Corners keep the aspect; edges stretch the one axis they sit on.
        var affectsWidth: Bool { unit.x != 0 }
        var affectsHeight: Bool { unit.y != 0 }
        var isCorner: Bool { affectsWidth && affectsHeight }
    }

    private let handleSize: CGFloat = 11
    private let fcpBlue = Color(red: 0.16, green: 0.55, blue: 1.0)
    private let pathRed = Color(red: 0.94, green: 0.25, blue: 0.22)

    var body: some View {
        GeometryReader { geo in
            let canvas = canvasRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in select(at: point, canvas: canvas) }

                if let clip = editor.selectedClip, clip.isVisual {
                    if let box = screenFrame(of: clip, canvas: canvas) {
                        boxView(clip: clip, box: box, canvas: canvas)
                    }
                    // Over the box, not under it: a keyframe sitting inside the
                    // layer has to stay grabbable, and the box takes the whole
                    // of its own area.
                    if let keys = clip.motionKeys, keys.keys.count > 1 {
                        motionPath(clip: clip, keys: keys, canvas: canvas)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: editor.selectedClipID) { _, _ in activeKey = nil }
        }
    }

    // MARK: - Geometry

    /// The letterboxed picture area inside the view.
    private func canvasRect(in size: CGSize) -> CGRect {
        let render = editor.project.aspect.renderSize
        guard render.width > 0, render.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / render.width, size.height / render.height)
        let width = render.width * scale
        let height = render.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func screenFrame(of clip: TimelineClip, canvas: CGRect) -> CGRect? {
        guard let frame = editor.canvasFrame(of: clip) else { return nil }
        let render = editor.project.aspect.renderSize
        let scale = canvas.width / max(1, render.width)
        return CGRect(x: canvas.minX + frame.minX * scale,
                      y: canvas.minY + frame.minY * scale,
                      width: frame.width * scale, height: frame.height * scale)
    }

    /// Unit canvas point → view point, and back.
    private func toScreen(_ unit: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX + unit.x * canvas.width,
                y: canvas.minY + unit.y * canvas.height)
    }

    private func toUnit(_ point: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: (point.x - canvas.minX) / max(1, canvas.width),
                y: (point.y - canvas.minY) / max(1, canvas.height))
    }

    private func select(at point: CGPoint, canvas: CGRect) {
        guard canvas.contains(point) else {
            editor.selectedClipID = nil
            return
        }
        if let hit = editor.layer(atCanvasPoint: toUnit(point, canvas: canvas)) {
            if editor.selectedClipID != hit.id {
                editor.selectedClipID = hit.id
                Haptics.selection()
            }
        } else {
            editor.selectedClipID = nil
        }
    }

    // MARK: - The motion path

    @ViewBuilder
    private func motionPath(clip: TimelineClip, keys: KeyframeTrack<ClipTransform>,
                            canvas: CGRect) -> some View {
        let points = keys.pathPoints(project: { toScreen($0, canvas: canvas) })
        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(pathRed, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)

            ForEach(Array(keys.keys.enumerated()), id: \.element.id) { index, key in
                keyMarker(clip: clip, keys: keys, key: key, index: index, canvas: canvas)
            }

            if let activeKey, let index = keys.keys.firstIndex(where: { $0.id == activeKey }) {
                tangentHandles(clip: clip, keys: keys, index: index, canvas: canvas)
            }
        }
    }

    @ViewBuilder
    private func keyMarker(clip: TimelineClip, keys: KeyframeTrack<ClipTransform>,
                           key: Keyframe<ClipTransform>, index: Int,
                           canvas: CGRect) -> some View {
        let at = toScreen(key.value.center, canvas: canvas)
        let isFirst = index == 0
        let isLast = index == keys.keys.count - 1
        let onPlayhead = abs(key.time - editor.localTime(of: clip)) <= KeyframeTrack<ClipTransform>.snap
        let tint: Color = onPlayhead ? Color(red: 0.20, green: 0.85, blue: 0.80) : .white
        Group {
            if isFirst {
                // Where the move begins: Final Cut's chevron.
                Chevron().fill(tint).frame(width: 11, height: 13)
            } else if isLast {
                Triangle().fill(tint).frame(width: 12, height: 12)
            } else {
                Diamond().fill(tint).frame(width: 11, height: 11)
            }
        }
        .overlay {
            if activeKey == key.id {
                Circle().strokeBorder(pathRed, lineWidth: 1.5).frame(width: 20, height: 20)
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 1)
        .contentShape(Rectangle().inset(by: -12))
        .position(at)
        .gesture(keyGesture(clip: clip, key: key, canvas: canvas))
    }

    /// Two round handles either side of the key, joined by a thin line —
    /// dragging one bends the curve and mirrors the other.
    @ViewBuilder
    private func tangentHandles(clip: TimelineClip, keys: KeyframeTrack<ClipTransform>,
                                index: Int, canvas: CGRect) -> some View {
        let key = keys.keys[index]
        let centre = toScreen(key.value.center, canvas: canvas)
        let outAt = toScreen(keys.outControl(index), canvas: canvas)
        let inAt = toScreen(keys.inControl(index), canvas: canvas)
        Path { path in
            path.move(to: inAt)
            path.addLine(to: centre)
            path.addLine(to: outAt)
        }
        .stroke(.white.opacity(0.8), lineWidth: 1)
        .allowsHitTesting(false)

        tangentHandle(at: inAt, clip: clip, key: key.id, outgoing: false, canvas: canvas)
        tangentHandle(at: outAt, clip: clip, key: key.id, outgoing: true, canvas: canvas)
    }

    private func tangentHandle(at point: CGPoint, clip: TimelineClip, key: UUID,
                               outgoing: Bool, canvas: CGRect) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(pathRed, lineWidth: 1.2))
            .contentShape(Rectangle().inset(by: -14))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        begin()
                        gesture = .tangent(id: key, outgoing: outgoing)
                        editor.setMotionTangent(clip.id, key: key, outgoing: outgoing,
                                                to: toUnit(value.location, canvas: canvas))
                    }
                    .onEnded { _ in finish() }
            )
    }

    private func keyGesture(clip: TimelineClip, key: Keyframe<ClipTransform>,
                            canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if value.translation == .zero { return }
                begin()
                gesture = .key(id: key.id)
                editor.moveMotionKey(clip.id, key: key.id,
                                     to: toUnit(value.location, canvas: canvas))
            }
            .onEnded { value in
                // A tap rather than a drag: take up this keyframe, and put the
                // playhead on it so the viewer shows the frame it belongs to.
                if abs(value.translation.width) < 4 && abs(value.translation.height) < 4 {
                    activeKey = activeKey == key.id ? nil : key.id
                    editor.scrubToKey(clip, time: key.time)
                    Haptics.selection()
                }
                finish()
            }
    }

    // MARK: - The box

    private func boxView(clip: TimelineClip, box: CGRect, canvas: CGRect) -> some View {
        let rotation = Angle(degrees: editor.liveTransform(of: clip).rotation)
        let stalk = max(34, box.width / 2 + 22)
        return ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .gesture(moveGesture(clip: clip, canvas: canvas))

            // The turn handle: a line out to the right of centre with a bead
            // on the end, the way Final Cut does it.
            Path { path in
                path.move(to: CGPoint(x: box.width / 2, y: box.height / 2))
                path.addLine(to: CGPoint(x: box.width / 2 + stalk, y: box.height / 2))
            }
            .stroke(.white.opacity(0.85), lineWidth: 1)
            bead
                .position(x: box.width / 2 + stalk, y: box.height / 2)
                .gesture(rotateGesture(clip: clip, box: box))

            // Centre crosshair: drag the layer by it.
            ZStack {
                Circle().fill(.black.opacity(0.35)).frame(width: 21, height: 21)
                Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 21, height: 21)
                Path { path in
                    path.move(to: CGPoint(x: 10.5, y: 3)); path.addLine(to: CGPoint(x: 10.5, y: 18))
                    path.move(to: CGPoint(x: 3, y: 10.5)); path.addLine(to: CGPoint(x: 18, y: 10.5))
                }
                .stroke(.white, lineWidth: 1.5)
                .frame(width: 21, height: 21)
            }
            .contentShape(Rectangle().inset(by: -10))
            .position(x: box.width / 2, y: box.height / 2)
            .gesture(moveGesture(clip: clip, canvas: canvas))

            ForEach(Handle.allCases, id: \.self) { handle in
                bead
                    .position(x: box.width / 2 + handle.unit.x * box.width / 2,
                              y: box.height / 2 + handle.unit.y * box.height / 2)
                    .gesture(scaleGesture(clip: clip, handle: handle, canvas: canvas))
            }
        }
        .frame(width: box.width, height: box.height)
        .rotationEffect(rotation)
        .position(x: box.midX, y: box.midY)
    }

    private var bead: some View {
        Circle()
            .fill(fcpBlue)
            .frame(width: handleSize, height: handleSize)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.2))
            .shadow(color: .black.opacity(0.5), radius: 1)
            .contentShape(Rectangle().inset(by: -12))
    }

    // MARK: - Gestures

    private func begin() {
        guard !didPushUndo else { return }
        editor.markUndoPoint()
        didPushUndo = true
    }

    private func finish() {
        gesture = nil
        didPushUndo = false
        Haptics.selection()
    }

    private func moveGesture(clip: TimelineClip, canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin()
                let start: CGPoint
                if case .move(let existing) = gesture {
                    start = existing
                } else {
                    start = editor.liveTransform(of: clip).center
                    gesture = .move(startCenter: start)
                }
                editor.updateTransform(clip.id, live: true) { t in
                    t.centerX = min(1.5, max(-0.5, start.x + value.translation.width / canvas.width))
                    t.centerY = min(1.5, max(-0.5, start.y + value.translation.height / canvas.height))
                }
            }
            .onEnded { _ in finish() }
    }

    private func scaleGesture(clip: TimelineClip, handle: Handle,
                              canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin()
                let startScale: Double
                let startHeight: Double
                if case .scale(_, let s, let h) = gesture {
                    startScale = s
                    startHeight = h
                } else {
                    let t = editor.liveTransform(of: clip)
                    startScale = t.scale
                    startHeight = t.heightScale
                    gesture = .scale(handle: handle, startScale: startScale, startHeight: startHeight)
                }
                guard let box = screenFrame(of: clip, canvas: canvas),
                      box.width > 1, box.height > 1 else { return }
                // Each handle reads as "how much further out from the centre",
                // so the opposite side stays where the finger expects it.
                let outX = value.translation.width * handle.unit.x
                let outY = value.translation.height * handle.unit.y
                let widthFactor = 1 + outX * 2 / box.width
                let heightFactor = 1 + outY * 2 / box.height
                editor.updateTransform(clip.id, live: true) { t in
                    if handle.isCorner {
                        // Corners keep the aspect: one factor drives both.
                        let factor = 1 + (outX + outY) / max(1, hypot(box.width, box.height))
                        let ratio = startHeight / max(0.0001, startScale)
                        t.scale = min(8, max(0.02, startScale * factor))
                        t.scaleY = startHeight == startScale ? nil : t.scale * ratio
                    } else if handle.affectsWidth {
                        t.scale = min(8, max(0.02, startScale * widthFactor))
                        t.scaleY = startHeight
                    } else {
                        t.scaleY = min(8, max(0.02, startHeight * heightFactor))
                    }
                }
            }
            .onEnded { _ in finish() }
    }

    private func rotateGesture(clip: TimelineClip, box: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin()
                let centre = CGPoint(x: box.midX, y: box.midY)
                let current = atan2(value.location.y - centre.y, value.location.x - centre.x)
                let startRotation: Double
                let startAngle: Double
                if case .rotate(let r, let a) = gesture {
                    startRotation = r
                    startAngle = a
                } else {
                    startRotation = editor.liveTransform(of: clip).rotation
                    startAngle = atan2(value.startLocation.y - centre.y,
                                       value.startLocation.x - centre.x)
                    gesture = .rotate(startRotation: startRotation, startAngle: startAngle)
                }
                var degrees = startRotation + (current - startAngle) * 180 / .pi
                // Snap to the eighths, so square is easy to find again.
                let nearest = (degrees / 45).rounded() * 45
                if abs(degrees - nearest) < 3 { degrees = nearest }
                editor.updateTransform(clip.id, live: true) { $0.rotation = degrees }
            }
            .onEnded { _ in finish() }
    }
}

// MARK: - Path markers

/// Where a move begins.
struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// Where it ends.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
