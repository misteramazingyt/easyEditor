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
    var cutout: CutoutMode?
    var blend: BlendMode?
    /// Timeline stacking slot: 0 is the storyline, +n stacks above it.
    var zOrder: Int = 0
    /// Whether this layer's light spills into the backdrop.
    var castsCaustics: Bool = true
    /// Black media that exists only so the timeline has a surface to play —
    /// an empty placeholder slot, or the filler under a stills-only project.
    /// It is scaffolding, not picture.
    var isScaffold = false

    /// Free framing from the canvas box, and the keys animating it.
    var baseTransform = ClipTransform()
    var motionKeys: KeyframeTrack<ClipTransform>?
    var compositeKeys: KeyframeTrack<CompositeValue>?

    // Connected-clip motion (zero clipEnd = no motion evaluation).
    var clipStart: Double = 0
    var clipEnd: Double = 0
    var inOut: InOutSettings?
    var loop: LoopAnimationSettings?
    var compositing: CompositingSettings?

    // Main-track focus treatment, linear ramp across the instruction.
    var focusStyle: FocusStyle?
    var focusStart: Double = 0
    var focusEnd: Double = 0
}

/// A pre-rendered still (title text or image clip) composited on top.
struct CompositorOverlay {
    var image: CIImage
    var placement: OverlayPlacement
    var clipStart: Double = 0
    var clipEnd: Double = 0
    var inOut: InOutSettings?
    var loop: LoopAnimationSettings?
    var compositing: CompositingSettings?
    var blend: BlendMode?
    /// Timeline stacking slot, shared scale with CompositorLayer.
    var zOrder: Int = 0
    var castsCaustics: Bool = true

    /// Free framing from the canvas box, and the keys animating it. The
    /// placement above stays the baseline these are measured against.
    var baseTransform = ClipTransform()
    var motionKeys: KeyframeTrack<ClipTransform>?
    var compositeKeys: KeyframeTrack<CompositeValue>?
}

/// Resolve an animated value for this instant, falling back to the baseline
/// when a layer has no keys.
enum KeyframeResolver {
    static func transform(_ base: ClipTransform, _ keys: KeyframeTrack<ClipTransform>?,
                          at time: Double, clipStart: Double) -> ClipTransform {
        guard let keys, keys.isActive else { return base }
        return keys.transform(at: time - clipStart) ?? base
    }

    static func composite(_ base: CompositeValue, _ keys: KeyframeTrack<CompositeValue>?,
                          at time: Double, clipStart: Double) -> CompositeValue {
        guard let keys, keys.isActive else { return base }
        return keys.value(at: time - clipStart) ?? base
    }
}

final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]?

    let layers: [CompositorLayer]
    let overlays: [CompositorOverlay]
    let aesthetic: AestheticFrameConfig?

    init(timeRange: CMTimeRange, layers: [CompositorLayer], overlays: [CompositorOverlay],
         aesthetic: AestheticFrameConfig? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.overlays = overlays
        self.aesthetic = aesthetic
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

        // Video frames and stills are prepared separately but must composite
        // in one order — the timeline's — or an image would always cover a
        // video no matter which slot each sits in.
        struct Pending {
            let z: Int
            let seq: Int
            let image: CIImage
            let blend: BlendMode?
            let castsCaustics: Bool
        }
        var pending: [Pending] = []

        // 0…1 progress through this instruction, for ramps.
        let range = instruction.timeRange
        let elapsed = CMTimeSubtract(request.compositionTime, range.start).seconds
        let total = max(0.0001, range.duration.seconds)
        let progress = min(1, max(0, elapsed / total))

        for layer in instruction.layers {
            // Scaffolding is opaque black across the whole canvas, so drawing
            // it would bury the treated backdrop under exactly the black the
            // backdrop replaces.
            if layer.isScaffold, instruction.aesthetic != nil { continue }
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            var image = CIImage(cvPixelBuffer: buffer)

            // 0. Background removal, on the raw buffer so masks stay aligned.
            if let cutout = layer.cutout {
                switch cutout {
                case .person, .subject:
                    image = CutoutService.personMasked(image, buffer: buffer)
                case .whiteKey:
                    image = CutoutService.colorKeyed(image, removeWhite: true)
                case .blackKey:
                    image = CutoutService.colorKeyed(image, removeWhite: false)
                }
            }

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

            // 3b. Free framing from the canvas box, animated if it has keys.
            //     Applied about the fitted picture's own centre, so scale 1 at
            //     centre (0.5, 0.5) is exactly the fit above and an untouched
            //     clip goes through here unchanged.
            let now = request.compositionTime.seconds
            let placed = KeyframeResolver.transform(layer.baseTransform, layer.motionKeys,
                                                    at: now, clipStart: layer.clipStart)
            if !placed.isIdentity {
                let box = image.extent
                var t = CGAffineTransform(translationX: -box.midX, y: -box.midY)
                t = t.concatenating(CGAffineTransform(scaleX: CGFloat(placed.scale),
                                                      y: CGFloat(placed.heightScale)))
                t = t.concatenating(CGAffineTransform(
                    rotationAngle: -CGFloat(placed.rotation) * .pi / 180))
                t = t.concatenating(CGAffineTransform(
                    translationX: size.width * CGFloat(placed.centerX),
                    y: size.height * (1 - CGFloat(placed.centerY))))
                image = image.transformed(by: t)
            }

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

            // Main-track focus (blur/darken/pixelate under connected clips).
            if let style = layer.focusStyle {
                let amount = layer.focusStart + (layer.focusEnd - layer.focusStart) * progress
                image = Self.applyFocus(style, amount: amount, to: image, canvas: canvas)
            }

            // Connected-clip entrance/exit + looping motion.
            if layer.clipEnd > layer.clipStart {
                let time = request.compositionTime.seconds
                let motion = MotionEvaluator.state(at: time,
                                                  clipStart: layer.clipStart,
                                                  clipEnd: layer.clipEnd,
                                                  inOut: layer.inOut,
                                                  loop: layer.loop,
                                                  canvas: size)
                image = Self.applyMotion(motion, to: image, canvas: canvas)
                if let compositing = layer.compositing, compositing.effect != .none {
                    image = Self.applyCompositing(compositing, to: image, canvas: canvas)
                }
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

            // 6. Opacity ramp (premultiplied fade), times whatever the
            //    compositing track is asking for at this instant.
            let mixed = KeyframeResolver.composite(
                CompositeValue(opacity: 1, blend: layer.blend ?? .normal),
                layer.compositeKeys, at: now, clipStart: layer.clipStart)
            let opacity = (layer.startOpacity
                           + (layer.endOpacity - layer.startOpacity) * progress) * mixed.opacity
            if opacity < 0.999 {
                let a = CGFloat(max(0, opacity))
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                ])
            }

            pending.append(Pending(z: layer.zOrder, seq: pending.count,
                                   image: image, blend: mixed.blend,
                                   castsCaustics: layer.castsCaustics))
        }

        // 7. Title / image overlays (Core Image y-axis points up, placements
        //    use UIKit-style y-down unit coordinates), with per-frame motion.
        for overlay in instruction.overlays {
            var image = overlay.image
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { continue }

            var motion = MotionEvaluator.MotionState()
            if overlay.clipEnd > overlay.clipStart {
                motion = MotionEvaluator.state(at: request.compositionTime.seconds,
                                               clipStart: overlay.clipStart,
                                               clipEnd: overlay.clipEnd,
                                               inOut: overlay.inOut,
                                               loop: overlay.loop,
                                               canvas: size)
            }

            // Where the box put it, animated if it has keys — the entrance,
            // exit and loop motion above then rides on top of that.
            let now = request.compositionTime.seconds
            let placed = KeyframeResolver.transform(overlay.baseTransform, overlay.motionKeys,
                                                    at: now, clipStart: overlay.clipStart)
            let targetWidth = size.width * CGFloat(placed.scale)
            let scale = targetWidth / extent.width
            let centerX = size.width * CGFloat(placed.centerX) + motion.offset.x
            let centerY = size.height * (1 - CGFloat(placed.centerY)) - motion.offset.y
            var t = CGAffineTransform(translationX: centerX, y: centerY)
            t = t.rotated(by: -motion.rotation - CGFloat(placed.rotation) * .pi / 180)
            let stretch = CGFloat(placed.heightScale / max(0.0001, placed.scale))
            t = t.scaledBy(x: scale * motion.scaleX, y: scale * stretch * motion.scaleY)
            t = t.translatedBy(x: -extent.midX, y: -extent.midY)
            image = image.transformed(by: t)

            if motion.pixellate > 0.5 {
                image = image.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputCenterKey: CIVector(x: image.extent.midX, y: image.extent.midY),
                        kCIInputScaleKey: max(1, motion.pixellate),
                    ])
                    .cropped(to: image.extent)
            }
            if motion.glitchSeed != 0 {
                image = Self.applyGlitch(to: image, shift: motion.glitchShift)
            }
            if let compositing = overlay.compositing, compositing.effect != .none {
                image = Self.applyCompositing(compositing, to: image, canvas: canvas)
            }
            let mixed = KeyframeResolver.composite(
                CompositeValue(opacity: overlay.placement.opacity,
                               blend: overlay.blend ?? .normal),
                overlay.compositeKeys, at: now, clipStart: overlay.clipStart)
            if mixed.opacity < 0.999 {
                let a = CGFloat(max(0, mixed.opacity))
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                ])
            }
            pending.append(Pending(z: overlay.zOrder, seq: pending.count,
                                   image: image, blend: mixed.blend,
                                   castsCaustics: overlay.castsCaustics))
        }

        let ordered = pending.sorted(by: { ($0.z, $0.seq) < ($1.z, $1.seq) })
        let time = request.compositionTime.seconds

        if let aesthetic = instruction.aesthetic {
            // What the picture throws off, minus anything opted out (camera
            // takes, by default) — used for both the ghost and the spill.
            var spillSource: CIImage?
            for item in ordered where item.castsCaustics {
                spillSource = spillSource.map {
                    item.image.cropped(to: canvas).composited(over: $0)
                } ?? item.image.cropped(to: canvas)
            }
            result = AestheticRenderer.backdrop(aesthetic, canvas: canvas,
                                                time: time, ghost: spillSource)
            if let spillSource,
               let spill = AestheticRenderer.caustics(from: spillSource, canvas: canvas,
                                                      amount: aesthetic.caustics * aesthetic.strength) {
                result = spill.applyingFilter("CIScreenBlendMode", parameters: [
                    kCIInputBackgroundImageKey: result,
                ]).cropped(to: canvas)
            }
        }

        // Lowest slot first; ties keep their build order (an outgoing clip
        // stays under the incoming one through a transition).
        for item in ordered {
            result = Self.composite(item.image, over: result,
                                    blend: item.blend, canvas: canvas)
        }

        // The whole frame wears the treatment at the strength that was asked
        // for — at 100% that is precisely the look on the gallery tile.
        if let aesthetic = instruction.aesthetic {
            result = AestheticRenderer.treat(result, aesthetic, canvas: canvas,
                                             time: time, weight: 1)
        }

        ciContext.render(result, to: output, bounds: canvas,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    /// Lay one image over another, honouring its blend mode. Core Image's
    /// blend filters work in RGB, so screening can't tint the frame the way a
    /// YUV path would.
    private static func composite(_ image: CIImage, over background: CIImage,
                                  blend: BlendMode?, canvas: CGRect) -> CIImage {
        let cropped = image.cropped(to: canvas)
        guard let filterName = (blend ?? .normal).ciFilterName else {
            return cropped.composited(over: background)
        }
        return cropped
            .applyingFilter(filterName, parameters: [kCIInputBackgroundImageKey: background])
            .cropped(to: canvas)
    }

    // MARK: - Motion, focus & compositing

    /// Apply an evaluated motion state about the canvas center (video layers).
    private static func applyMotion(_ motion: MotionEvaluator.MotionState,
                                    to input: CIImage, canvas: CGRect) -> CIImage {
        var image = input
        if motion.pixellate > 0.5 {
            image = image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputScaleKey: max(1, motion.pixellate),
                ])
                .cropped(to: image.extent)
        }
        if !(motion.scaleX == 1 && motion.scaleY == 1 && motion.rotation == 0 && motion.offset == .zero) {
            var t = CGAffineTransform(translationX: canvas.midX + motion.offset.x,
                                      y: canvas.midY - motion.offset.y)
            t = t.rotated(by: -motion.rotation)
            t = t.scaledBy(x: max(0.0001, motion.scaleX), y: max(0.0001, motion.scaleY))
            t = t.translatedBy(x: -canvas.midX, y: -canvas.midY)
            image = image.transformed(by: t)
        }
        if motion.glitchSeed != 0 {
            image = applyGlitch(to: image, shift: motion.glitchShift)
        }
        return image
    }

    /// Cheap RGB-split glitch: a red-channel copy shifted sideways.
    private static func applyGlitch(to image: CIImage, shift: CGFloat) -> CIImage {
        guard shift != 0 else { return image }
        let red = image
            .transformed(by: CGAffineTransform(translationX: shift, y: 0))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6),
            ])
        return red.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image,
        ])
    }

    /// Focus treatment on the main track: blur / darken / pixelate ramps.
    private static func applyFocus(_ style: FocusStyle, amount: Double,
                                   to input: CIImage, canvas: CGRect) -> CIImage {
        let a = min(1, max(0, amount))
        guard a > 0.001 else { return input }
        var image = input
        let unit = min(canvas.width, canvas.height) / 1080
        if style.blurs {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 30 * unit * a,
                ])
                .cropped(to: input.extent)
        }
        if style.pixelates {
            image = image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputScaleKey: 1 + 40 * unit * a,
                ])
                .cropped(to: input.extent)
        }
        if style.darkens {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                               alpha: 0.85 * a)).cropped(to: input.extent)
            image = black.composited(over: image)
        }
        return image
    }

    /// Drop shadow / glow / outline / blur behind or on a positioned image.
    private static func applyCompositing(_ cfg: CompositingSettings,
                                         to image: CIImage, canvas: CGRect) -> CIImage {
        let unit = min(canvas.width, canvas.height) / 1080
        switch cfg.effect {
        case .none:
            return image
        case .blur:
            return image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: cfg.blur * unit,
            ])
        case .dropShadow, .glow, .outline:
            let color = ciColor(hex: cfg.colorHex, alpha: cfg.opacity)
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: canvas)
            var silhouette = CIImage(color: color).cropped(to: canvas)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: clear,
                    kCIInputMaskImageKey: image.cropped(to: canvas),
                ])
            switch cfg.effect {
            case .outline:
                silhouette = silhouette.applyingFilter("CIMorphologyMaximum", parameters: [
                    kCIInputRadiusKey: max(1, (cfg.spread + 3) * unit),
                ]).cropped(to: canvas)
            case .glow:
                silhouette = silhouette.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(1, cfg.blur * unit),
                ]).cropped(to: canvas)
            default: // drop shadow
                if cfg.spread > 0 {
                    silhouette = silhouette.applyingFilter("CIMorphologyMaximum", parameters: [
                        kCIInputRadiusKey: cfg.spread * unit,
                    ]).cropped(to: canvas)
                }
                silhouette = silhouette
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: max(0.5, cfg.blur * unit),
                    ])
                    .transformed(by: CGAffineTransform(translationX: cfg.offsetX * unit,
                                                       y: -cfg.offsetY * unit))
                    .cropped(to: canvas)
            }
            return image.composited(over: silhouette)
        }
    }

    private static func ciColor(hex: String, alpha: Double) -> CIColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else {
            return CIColor(red: 0, green: 0, blue: 0, alpha: alpha)
        }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        return CIColor(red: r, green: g, blue: b, alpha: alpha)
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
