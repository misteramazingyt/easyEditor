import SwiftUI

/// Direct manipulation on the canvas, laid out the way Final Cut does it: a
/// thin outline with eight blue handles, a crosshair at the centre to drag the
/// layer by, and a stalk out to the right to turn it.
///
/// Everything is drawn from the numbers the compositor renders with, mapped
/// through the letterboxed canvas rect, so what you grab is where the picture
/// actually is rather than where the view happens to put a thumbnail.
///
/// While a handle is held the framing goes to the live store rather than the
/// project: the compositor reads it ahead of its instructions and the player
/// re-renders the frame it is on, so nothing rebuilds until the finger lifts.
struct CanvasTransformOverlay: View {
    @EnvironmentObject private var editor: EditorState

    @State private var gesture: Gesture?
    @State private var didPushUndo = false
    /// The framing being dragged. Held here rather than written to the project
    /// on every event, so the box and the picture come off the same number.
    @State private var dragging: (id: UUID, value: ClipTransform)?

    private enum Gesture: Equatable {
        case move(startCenter: CGPoint)
        case scale(handle: Handle, startScale: Double, startHeight: Double)
        case rotate(startRotation: Double, startAngle: Double)
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

    var body: some View {
        GeometryReader { geo in
            let canvas = canvasRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in select(at: point, canvas: canvas) }

                if let clip = editor.selectedClip, clip.isVisual,
                   let box = screenFrame(of: clip, canvas: canvas) {
                    // While a handle is held the layer is lifted out of the
                    // composition and drawn here instead, so it moves with the
                    // screen rather than with the player.
                    if dragging?.id == clip.id, let ghost = editor.dragPreview(for: clip.id) {
                        Image(uiImage: ghost)
                            .resizable()
                            .frame(width: box.width, height: box.height)
                            .rotationEffect(Angle(degrees: framing(of: clip).rotation))
                            .position(x: box.midX, y: box.midY)
                            .allowsHitTesting(false)
                    }
                    boxView(clip: clip, box: box, canvas: canvas)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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

    /// What this clip is framed at right now: the drag in progress if there is
    /// one, otherwise whatever the project says.
    private func framing(of clip: TimelineClip) -> ClipTransform {
        if let dragging, dragging.id == clip.id { return dragging.value }
        return editor.liveTransform(of: clip)
    }

    private func screenFrame(of clip: TimelineClip, canvas: CGRect) -> CGRect? {
        guard let frame = editor.canvasFrame(of: clip, using: framing(of: clip)) else { return nil }
        let render = editor.project.aspect.renderSize
        let scale = canvas.width / max(1, render.width)
        return CGRect(x: canvas.minX + frame.minX * scale,
                      y: canvas.minY + frame.minY * scale,
                      width: frame.width * scale, height: frame.height * scale)
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

    // MARK: - The box

    private func boxView(clip: TimelineClip, box: CGRect, canvas: CGRect) -> some View {
        let rotation = Angle(degrees: framing(of: clip).rotation)
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

    private func begin(_ clip: TimelineClip) {
        guard !didPushUndo else { return }
        editor.markUndoPoint()
        didPushUndo = true
        dragging = (clip.id, editor.liveTransform(of: clip))
        editor.beginTransformDrag(clip)
    }

    /// Push the in-flight framing at the compositor without touching the
    /// project, and keep the box drawn from the same number.
    private func drag(_ clip: TimelineClip, _ change: (inout ClipTransform) -> Void) {
        guard var value = dragging?.value, dragging?.id == clip.id else { return }
        change(&value)
        dragging = (clip.id, value)
        editor.dragTransform(clip.id, to: value)
    }

    private func finish(_ clip: TimelineClip) {
        if let dragging, dragging.id == clip.id {
            editor.commitTransform(clip.id, to: dragging.value)
        }
        dragging = nil
        gesture = nil
        didPushUndo = false
        Haptics.selection()
    }

    private func moveGesture(clip: TimelineClip, canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin(clip)
                let start: CGPoint
                if case .move(let existing) = gesture {
                    start = existing
                } else {
                    start = dragging?.value.center ?? editor.liveTransform(of: clip).center
                    gesture = .move(startCenter: start)
                }
                drag(clip) { t in
                    t.centerX = min(1.5, max(-0.5, start.x + value.translation.width / canvas.width))
                    t.centerY = min(1.5, max(-0.5, start.y + value.translation.height / canvas.height))
                }
            }
            .onEnded { _ in finish(clip) }
    }

    private func scaleGesture(clip: TimelineClip, handle: Handle,
                              canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin(clip)
                let startScale: Double
                let startHeight: Double
                if case .scale(_, let s, let h) = gesture {
                    startScale = s
                    startHeight = h
                } else {
                    let t = dragging?.value ?? editor.liveTransform(of: clip)
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
                drag(clip) { t in
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
            .onEnded { _ in finish(clip) }
    }

    private func rotateGesture(clip: TimelineClip, box: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin(clip)
                let centre = CGPoint(x: box.midX, y: box.midY)
                let current = atan2(value.location.y - centre.y, value.location.x - centre.x)
                let startRotation: Double
                let startAngle: Double
                if case .rotate(let r, let a) = gesture {
                    startRotation = r
                    startAngle = a
                } else {
                    startRotation = dragging?.value.rotation
                        ?? editor.liveTransform(of: clip).rotation
                    startAngle = atan2(value.startLocation.y - centre.y,
                                       value.startLocation.x - centre.x)
                    gesture = .rotate(startRotation: startRotation, startAngle: startAngle)
                }
                var degrees = startRotation + (current - startAngle) * 180 / .pi
                // Snap to the eighths, so square is easy to find again.
                let nearest = (degrees / 45).rounded() * 45
                if abs(degrees - nearest) < 3 { degrees = nearest }
                drag(clip) { $0.rotation = degrees }
            }
            .onEnded { _ in finish(clip) }
    }
}
