import SwiftUI
import MetalKit
import CoreImage

/// Draws the latest keyed camera frame over the editor preview, so you see
/// yourself composited on top of the timeline exactly as it will record.
/// Transparent where the person isn't — the layers below show through.
struct CameraCutoutPreview: UIViewRepresentable {
    let frames: LiveFrameBuffer

    func makeCoordinator() -> Renderer { Renderer(frames: frames) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false          // required to render CIImages into it
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Renderer) {
        uiView.isPaused = true
        uiView.delegate = nil
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private let context: CIContext?
        private let frames: LiveFrameBuffer

        init(frames: LiveFrameBuffer) {
            self.frames = frames
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.queue = device?.makeCommandQueue()
            self.context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let queue, let context,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer() else { return }
            let bounds = CGRect(x: 0, y: 0,
                                width: drawable.texture.width,
                                height: drawable.texture.height)
            // Always render over a transparent ground so the whole drawable is
            // written each frame (no stale pixels, no manual clear pass).
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: bounds)
            var image = clear
            if let latest = frames.latest(), latest.extent.width > 0, latest.extent.height > 0 {
                let scale = min(bounds.width / latest.extent.width,
                                bounds.height / latest.extent.height)
                let scaled = latest.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let centered = scaled.transformed(by: CGAffineTransform(
                    translationX: bounds.midX - scaled.extent.midX,
                    y: bounds.midY - scaled.extent.midY))
                image = centered.composited(over: clear).cropped(to: bounds)
            }
            context.render(image, to: drawable.texture, commandBuffer: commandBuffer,
                           bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
