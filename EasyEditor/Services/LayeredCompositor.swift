import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// One video layer inside an instruction interval, bottom-to-top.
/// Opacity/transform are linear ramps across the instruction's time range —
/// the engine splits intervals so every ramp is piecewise linear.
struct CompositorLayer {
    var trackID: CMPersistentTrackID
    /// Orientation fix from the source track (preferredTransform).
    var orientation: CGAffineTransform = .identity
    var startOpacity: Double = 1
    var endOpacity: Double = 1
    /// Canvas-space animation (slides/zooms), lerped across the interval.
    var startTranslationX: CGFloat = 0
    var endTranslationX: CGFloat = 0
    var startScale: CGFloat = 1
    var endScale: CGFloat = 1
    var filter: FilterPreset = .none
    var adjustments = Adjustments()
    var rotationQuarterTurns: Int = 0
    var isFlippedH = false
}

/// A pre-rendered still (title text or image clip) composited on top.
struct CompositorOverlay {
    var image: CIImage
    var placement: OverlayPlacement
}

final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]?

    let layers: [CompositorLayer]
    let overlays: [CompositorOverlay]

    init(timeRange: CMTimeRange, layers: [CompositorLayer], overlays: [CompositorOverlay]) {
        self.timeRange = timeRange
        self.layers = layers
        self.overlays = overlays
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// Custom compositor: aspect-fits each active layer into the canvas, applies
/// per-clip filters/adjustments/rotation, blends transition ramps, then stamps
/// title/image overlays. The same path renders preview *and* export.
final class LayeredCompositor: NSObject, AVVideoCompositing {

    private let queue = DispatchQueue(label: "com.easyeditor.compositor")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests are processed synchronously on `queue`; nothing to cancel.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.render(request)
            }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositorInstruction,
              let output = renderContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "com.easyeditor.compositor", code: -1))
            return
        }
        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        var result = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: canvas)

        // 0…1 progress through this instruction, for ramps.
        let range = instruction.timeRange
        let elapsed = CMTimeSubtract(request.compositionTime, range.start).seconds
        let total = max(0.0001, range.duration.seconds)
        let progress = min(1, max(0, elapsed / total))

        for layer in instruction.layers {
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            var image = CIImage(cvPixelBuffer: buffer)

            // 1. Orientation from the source track.
            image = image.transformed(by: layer.orientation)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX, y: -image.extent.minY))

            // 2. User rotation (quarter turns) and horizontal flip.
            let turns = ((layer.rotationQuarterTurns % 4) + 4) % 4
            if turns != 0 {
                image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
                image = image.transformed(by: CGAffineTransform(
                    translationX: -image.extent.minX, y: -image.extent.minY))
            }
            if layer.isFlippedH {
                image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                image = image.transformed(by: CGAffineTransform(
                    translationX: -image.extent.minX, y: -image.extent.minY))
            }

            // 3. Aspect-fit into the canvas.
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { continue }
            let scale = min(size.width / extent.width, size.height / extent.height)
            let fitted = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(
                    translationX: (size.width - extent.width * scale) / 2,
                    y: (size.height - extent.height * scale) / 2))
            image = image.transformed(by: fitted)

            // 4. Per-clip filter + adjustments.
            image = Self.applyFilter(layer.filter, to: image)
            if !layer.adjustments.isIdentity {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: layer.adjustments.brightness,
                    kCIInputContrastKey: layer.adjustments.contrast,
                    kCIInputSaturationKey: layer.adjustments.saturation,
                ])
            }

            // 5. Transition animation (slide/zoom) lerped across the interval.
            let tx = layer.startTranslationX + (layer.endTranslationX - layer.startTranslationX) * progress
            let animScale = layer.startScale + (layer.endScale - layer.startScale) * progress
            if tx != 0 || animScale != 1 {
                let cx = size.width / 2, cy = size.height / 2
                var t = CGAffineTransform(translationX: cx + tx * size.width, y: cy)
                t = t.scaledBy(x: animScale, y: animScale)
                t = t.translatedBy(x: -cx, y: -cy)
                image = image.transformed(by: t)
            }

            // 6. Opacity ramp (premultiplied fade).
            let opacity = layer.startOpacity + (layer.endOpacity - layer.startOpacity) * progress
            if opacity < 0.999 {
                let a = CGFloat(max(0, opacity))
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                ])
            }

            result = image.cropped(to: canvas).composited(over: result)
        }

        // 7. Title / image overlays (Core Image y-axis points up, placements
        //    use UIKit-style y-down unit coordinates).
        for overlay in instruction.overlays {
            var image = overlay.image
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { continue }
            let targetWidth = size.width * CGFloat(overlay.placement.widthFraction)
            let scale = targetWidth / extent.width
            let height = extent.height * scale
            let centerX = size.width * CGFloat(overlay.placement.centerX)
            let centerY = size.height * (1 - CGFloat(overlay.placement.centerY))
            var t = CGAffineTransform(translationX: centerX - targetWidth / 2,
                                      y: centerY - height / 2)
            t = t.scaledBy(x: scale, y: scale)
            t = t.translatedBy(x: -extent.minX, y: -extent.minY)
            image = image.transformed(by: t)
            if overlay.placement.opacity < 0.999 {
                let a = CGFloat(max(0, overlay.placement.opacity))
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                ])
            }
            result = image.cropped(to: canvas).composited(over: result)
        }

        ciContext.render(result, to: output, bounds: canvas,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    private static func applyFilter(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        switch preset {
        case .none:
            return image
        case .vivid:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.08,
            ])
        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 5500, y: 0),
                "inputTargetNeutral": CIVector(x: 7500, y: 0),
            ])
        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 7500, y: 0),
                "inputTargetNeutral": CIVector(x: 5500, y: 0),
            ])
        default:
            guard let name = preset.ciFilterName else { return image }
            return image.applyingFilter(name)
        }
    }
}
