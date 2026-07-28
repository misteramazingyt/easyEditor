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
    var effect: EffectPreset?
    var mask: MaskSettings?
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

            // 1. Orientation from the source track. preferredTransform is in
            //    video space (y down); Core Image's y points up, so the same
            //    matrix rotates the wrong way — apply the *negated* rotation
            //    angle instead (and preserve any mirroring). Translation is
            //    irrelevant because we re-origin afterwards.
            let t = layer.orientation
            let angle = atan2(t.b, t.a)
            let mirrored = (t.a * t.d - t.b * t.c) < 0
            if angle != 0 || mirrored {
                var orient = CGAffineTransform(rotationAngle: -angle)
                if mirrored { orient = orient.scaledBy(x: -1, y: 1) }
                image = image.transformed(by: orient)
            }
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
                let adj = layer.adjustments
                if adj.brightness != 0 || adj.contrast != 1 || adj.saturation != 1 {
                    image = image.applyingFilter("CIColorControls", parameters: [
                        kCIInputBrightnessKey: adj.brightness,
                        kCIInputContrastKey: adj.contrast,
                        kCIInputSaturationKey: adj.saturation,
                    ])
                }
                let temp = adj.temp ?? 0, tint = adj.tint ?? 0
                if temp != 0 || tint != 0 {
                    image = image.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: 6500, y: 0),
                        "inputTargetNeutral": CIVector(x: 6500 + CGFloat(temp) * 1500,
                                                       y: CGFloat(tint) * 50),
                    ])
                }
                if let hue = adj.hue, hue != 0 {
                    image = image.applyingFilter("CIHueAdjust", parameters: [
                        kCIInputAngleKey: hue * .pi,
                    ])
                }
                if let vignette = adj.vignette, vignette > 0 {
                    image = image.applyingFilter("CIVignette", parameters: [
                        kCIInputIntensityKey: vignette * 2,
                        kCIInputRadiusKey: 2,
                    ]).cropped(to: image.extent)
                }
                if let retouch = adj.retouch, retouch > 0 {
                    // Soft-focus "beauty" pass: blend a blur back over the
                    // original, weighted by strength.
                    let extent = image.extent
                    let softened = image.clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [
                            kCIInputRadiusKey: 4 + retouch * 8,
                        ])
                        .cropped(to: extent)
                    let a = CGFloat(min(0.75, retouch * 0.75))
                    let faded = softened.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                    ])
                    image = faded.composited(over: image)
                }
            }
            if let effect = layer.effect {
                image = Self.applyEffect(effect, to: image, canvas: canvas)
            }
            if let mask = layer.mask {
                image = Self.applyMask(mask, to: image, canvas: canvas)
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

    // MARK: - Effects

    private static func applyEffect(_ effect: EffectPreset, to input: CIImage,
                                    canvas: CGRect) -> CIImage {
        let extent = input.extent
        let center = CIVector(x: canvas.midX, y: canvas.midY)
        let minDim = min(canvas.width, canvas.height)
        let image = input.clampedToExtent()
        let result: CIImage
        switch effect {
        case .blur:
            result = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
        case .pixelate:
            result = image.applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: center, kCIInputScaleKey: minDim / 45,
            ])
        case .bloom:
            result = image.applyingFilter("CIBloom", parameters: [
                kCIInputIntensityKey: 1.0, kCIInputRadiusKey: 10,
            ])
        case .sharpen:
            result = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.8,
            ])
        case .comic:
            result = image.applyingFilter("CIComicEffect")
        case .dotScreen:
            result = image.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: center, kCIInputWidthKey: minDim / 90,
            ])
        case .crystallize:
            result = image.applyingFilter("CICrystallize", parameters: [
                kCIInputCenterKey: center, kCIInputRadiusKey: minDim / 40,
            ])
        case .thermal:
            result = image.applyingFilter("CIThermal")
        case .xray:
            result = image.applyingFilter("CIXRay")
        case .noirEdges:
            result = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
        case .kaleidoscope:
            result = image.applyingFilter("CIKaleidoscope", parameters: [
                "inputCenter": center, "inputCount": 6, "inputAngle": 0,
            ])
        case .zoomBlur:
            result = image.applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: center, "inputAmount": 12,
            ])
        case .vortex:
            result = image.applyingFilter("CIVortexDistortion", parameters: [
                kCIInputCenterKey: center, kCIInputRadiusKey: minDim * 0.7,
                kCIInputAngleKey: Double.pi * 1.5,
            ])
        case .fisheye:
            result = image.applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: center, kCIInputRadiusKey: minDim * 0.7,
                kCIInputScaleKey: 0.55,
            ])
        case .mirror:
            // Left half mirrored onto the right.
            let half = CGRect(x: extent.minX, y: extent.minY,
                              width: extent.width / 2, height: extent.height)
            let left = input.cropped(to: half)
            // scaleX(-1) maps [minX, minX+w/2] to [-(minX+w/2), -minX];
            // shifting by 2*minX + w lands it exactly on the right half.
            let flipped = left
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: extent.minX * 2 + extent.width, y: 0))
            result = flipped.composited(over: input)
        }
        return result.cropped(to: extent)
    }

    // MARK: - Masks

    private static func applyMask(_ mask: MaskSettings, to image: CIImage,
                                  canvas: CGRect) -> CIImage {
        let cx = canvas.width * CGFloat(mask.centerX)
        let cy = canvas.height * (1 - CGFloat(mask.centerY)) // placements are y-down
        let minDim = min(canvas.width, canvas.height)
        let radius = minDim * CGFloat(mask.size) / 2
        let feather = max(1, minDim * CGFloat(mask.feather))
        let white = CIColor(red: 1, green: 1, blue: 1)
        let black = CIColor(red: 0, green: 0, blue: 0)

        var maskImage: CIImage
        switch mask.shape {
        case .circle:
            maskImage = CIImage.empty().applyingFilter("CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: cx, y: cy),
                "inputRadius0": max(0, radius - feather / 2),
                "inputRadius1": radius + feather / 2,
                "inputColor0": white,
                "inputColor1": black,
            ])
        case .rectangle:
            let rect = CGRect(x: cx - radius, y: cy - radius * 1.2,
                              width: radius * 2, height: radius * 2.4)
            maskImage = CIImage.empty().applyingFilter("CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect),
                kCIInputRadiusKey: 14,
                kCIInputColorKey: white,
            ])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / 2])
        case .linear:
            // White below the line, fading across the feather band.
            maskImage = CIImage.empty().applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy - feather / 2),
                "inputPoint1": CIVector(x: cx, y: cy + feather / 2),
                "inputColor0": white,
                "inputColor1": black,
            ])
        case .mirror:
            // A horizontal band: intersection of two opposing linear fades.
            let lower = CIImage.empty().applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy - radius - feather / 2),
                "inputPoint1": CIVector(x: cx, y: cy - radius + feather / 2),
                "inputColor0": black,
                "inputColor1": white,
            ])
            let upper = CIImage.empty().applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx, y: cy + radius - feather / 2),
                "inputPoint1": CIVector(x: cx, y: cy + radius + feather / 2),
                "inputColor0": white,
                "inputColor1": black,
            ])
            maskImage = lower.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: upper,
            ])
        }
        maskImage = maskImage.cropped(to: canvas)
        if mask.isInverted {
            maskImage = maskImage.applyingFilter("CIColorInvert").cropped(to: canvas)
        }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: maskImage,
        ]).cropped(to: canvas)
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
