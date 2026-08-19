import SwiftUI

/// The keyed camera on the preview, with a tap-to-reveal bounding box for
/// moving and resizing yourself on the canvas — before recording as well as
/// during it. The framing is baked into the recorded file, so what you set up
/// here is what gets written.
struct CameraFramingView: View {
    @ObservedObject var recorder: LiveRecordingService
    @Binding var isFraming: Bool

    @State private var gestureStart: CameraFraming?
    @State private var pinchStart: Double?

    private let minScale = 0.15
    private let maxScale = 3.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraCutoutPreview(frames: recorder.frames)
                if isFraming {
                    boundingBox(in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFraming.toggle()
                Haptics.selection()
            }
            .gesture(isFraming ? moveGesture(in: geo.size) : nil)
            .simultaneousGesture(isFraming ? scaleGesture : nil)
        }
    }

    // MARK: Box

    private func boxRect(in size: CGSize) -> CGRect {
        let framing = recorder.framing
        let width = size.width * framing.scale
        let height = size.height * framing.scale
        return CGRect(x: size.width * framing.centerX - width / 2,
                      y: size.height * framing.centerY - height / 2,
                      width: width, height: height)
    }

    private func boundingBox(in size: CGSize) -> some View {
        let rect = boxRect(in: size)
        return ZStack {
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            ForEach(corners(of: rect), id: \.id) { corner in
                Rectangle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .overlay(Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .position(corner.point)
                    .gesture(cornerScaleGesture(in: size))
            }

            Text("\(Int(recorder.framing.scale * 100))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .position(x: rect.midX, y: max(12, rect.minY - 12))
        }
        .allowsHitTesting(true)
    }

    private struct Corner: Identifiable { let id: Int; let point: CGPoint }

    private func corners(of rect: CGRect) -> [Corner] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .enumerated().map { Corner(id: $0.offset, point: $0.element) }
    }

    // MARK: Gestures

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = gestureStart ?? recorder.framing
                if gestureStart == nil { gestureStart = start }
                var framing = start
                framing.centerX = clampUnit(start.centerX + value.translation.width / size.width)
                framing.centerY = clampUnit(start.centerY + value.translation.height / size.height)
                recorder.framing = framing
            }
            .onEnded { _ in
                gestureStart = nil
                Haptics.snap()
            }
    }

    private var scaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = pinchStart ?? recorder.framing.scale
                if pinchStart == nil { pinchStart = start }
                recorder.framing.scale = min(maxScale, max(minScale, start * value))
            }
            .onEnded { _ in
                pinchStart = nil
                Haptics.snap()
            }
    }

    /// Dragging a corner scales about the centre.
    private func cornerScaleGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = gestureStart ?? recorder.framing
                if gestureStart == nil { gestureStart = start }
                let center = CGPoint(x: size.width * start.centerX,
                                     y: size.height * start.centerY)
                let from = hypot(value.startLocation.x - center.x,
                                 value.startLocation.y - center.y)
                let to = hypot(value.location.x - center.x,
                               value.location.y - center.y)
                guard from > 4 else { return }
                recorder.framing.scale = min(maxScale, max(minScale, start.scale * to / from))
            }
            .onEnded { _ in
                gestureStart = nil
                Haptics.snap()
            }
    }

    private func clampUnit(_ value: Double) -> Double {
        // A little travel past the edge is useful for half-in-frame looks.
        min(1.4, max(-0.4, value))
    }
}
