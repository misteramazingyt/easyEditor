import SwiftUI

/// Direct manipulation on the canvas: tap a layer to select it, then drag the
/// body to move, a corner to scale, or the handle above it to rotate.
///
/// The box is drawn from the same numbers the compositor renders with, mapped
/// through the letterboxed canvas rect, so what you grab is where the picture
/// actually is rather than where the view happens to put a thumbnail.
struct CanvasTransformOverlay: View {
    @EnvironmentObject private var editor: EditorState

    /// Set while a handle is being dragged, so the timeline can leave the
    /// selection alone and the gesture owns undo.
    @State private var gesture: Gesture?
    @State private var didPushUndo = false

    private enum Gesture: Equatable {
        case move(startCenter: CGPoint)
        case scale(corner: Corner, startScale: Double, startCenter: CGPoint)
        case rotate(startRotation: Double, startAngle: Double)
    }

    private enum Corner: CaseIterable, Equatable {
        case topLeft, topRight, bottomLeft, bottomRight

        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: -1, y: -1)
            case .topRight: return CGPoint(x: 1, y: -1)
            case .bottomLeft: return CGPoint(x: -1, y: 1)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            }
        }
    }

    private let handle: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let canvas = canvasRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Taps anywhere pick a layer, or drop the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        select(at: point, canvas: canvas)
                    }

                if let clip = editor.selectedClip, clip.isVisual,
                   let box = screenFrame(of: clip, canvas: canvas) {
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

    private func screenFrame(of clip: TimelineClip, canvas: CGRect) -> CGRect? {
        guard let frame = editor.canvasFrame(of: clip) else { return nil }
        let render = editor.project.aspect.renderSize
        let scale = canvas.width / max(1, render.width)
        return CGRect(x: canvas.minX + frame.minX * scale,
                      y: canvas.minY + frame.minY * scale,
                      width: frame.width * scale, height: frame.height * scale)
    }

    private func select(at point: CGPoint, canvas: CGRect) {
        guard canvas.contains(point) else {
            editor.selectedClipID = nil
            return
        }
        let unit = CGPoint(x: (point.x - canvas.minX) / canvas.width,
                           y: (point.y - canvas.minY) / canvas.height)
        if let hit = editor.layer(atCanvasPoint: unit) {
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
        let rotation = Angle(degrees: editor.liveTransform(of: clip).rotation)
        return ZStack {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .gesture(moveGesture(clip: clip, canvas: canvas))

            ForEach(Corner.allCases, id: \.self) { corner in
                Rectangle()
                    .fill(.white)
                    .frame(width: handle, height: handle)
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .position(x: box.width / 2 + corner.unit.x * box.width / 2,
                              y: box.height / 2 + corner.unit.y * box.height / 2)
                    .gesture(scaleGesture(clip: clip, corner: corner, canvas: canvas))
            }

            // Rotation handle, on a stalk above the top edge.
            Path { path in
                path.move(to: CGPoint(x: box.width / 2, y: 0))
                path.addLine(to: CGPoint(x: box.width / 2, y: -26))
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
            Circle()
                .fill(.white)
                .frame(width: handle + 1, height: handle + 1)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .position(x: box.width / 2, y: -26)
                .gesture(rotateGesture(clip: clip, box: box, canvas: canvas))
        }
        .frame(width: box.width, height: box.height)
        .rotationEffect(rotation)
        .position(x: box.midX, y: box.midY)
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
                    let t = editor.liveTransform(of: clip)
                    start = CGPoint(x: t.centerX, y: t.centerY)
                    gesture = .move(startCenter: start)
                }
                editor.updateTransform(clip.id, live: true) { t in
                    t.centerX = min(1.5, max(-0.5, start.x + value.translation.width / canvas.width))
                    t.centerY = min(1.5, max(-0.5, start.y + value.translation.height / canvas.height))
                }
            }
            .onEnded { _ in finish() }
    }

    private func scaleGesture(clip: TimelineClip, corner: Corner,
                              canvas: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin()
                let startScale: Double
                let startCenter: CGPoint
                if case .scale(_, let s, let c) = gesture {
                    startScale = s
                    startCenter = c
                } else {
                    let t = editor.liveTransform(of: clip)
                    startScale = t.scale
                    startCenter = CGPoint(x: t.centerX, y: t.centerY)
                    gesture = .scale(corner: corner, startScale: startScale, startCenter: startCenter)
                }
                guard let box = screenFrame(of: clip, canvas: canvas), box.width > 1 else { return }
                // Corner drags read as "how much further from the centre",
                // which keeps the opposite corner where the finger expects.
                let outward = value.translation.width * corner.unit.x
                    + value.translation.height * corner.unit.y
                let diagonal = max(1, hypot(box.width, box.height))
                let factor = 1 + outward * 2 / diagonal
                editor.updateTransform(clip.id, live: true) { t in
                    t.scale = min(6, max(0.02, startScale * factor))
                    t.centerX = startCenter.x
                    t.centerY = startCenter.y
                }
            }
            .onEnded { _ in finish() }
    }

    private func rotateGesture(clip: TimelineClip, box: CGRect,
                               canvas: CGRect) -> some SwiftUI.Gesture {
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
                    let origin = atan2(value.startLocation.y - centre.y,
                                       value.startLocation.x - centre.x)
                    startAngle = origin
                    gesture = .rotate(startRotation: startRotation, startAngle: origin)
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
