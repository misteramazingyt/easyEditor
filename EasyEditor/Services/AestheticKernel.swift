import Foundation
import CoreImage

/// Wraps the Metal Core Image kernel that does the analogue per-pixel work in
/// a single GPU pass — curvature, per-line wobble, tear, chroma separation,
/// scanlines, phosphor mask, grain.
///
/// Core Image filter chains can't do any of the per-line geometry: they warp
/// whole images, not scanlines. This can, and it costs one pass instead of
/// eight. If the kernel can't be loaded for any reason the renderer falls back
/// to the filter chain, so the look degrades rather than disappearing.
final class AestheticKernel {
    static let shared = AestheticKernel()

    private let kernel: CIKernel?
    private let crtKernel: CIKernel?
    private let thresholdKernel: CIColorKernel?
    private let mergeKernel: CIColorKernel?

    var isAvailable: Bool { kernel != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            Log.engine.error("Aesthetic kernel: no metallib in the bundle")
            kernel = nil
            crtKernel = nil
            thresholdKernel = nil
            mergeKernel = nil
            return
        }
        kernel = try? CIKernel(functionName: "aestheticPass", fromMetalLibraryData: data)
        crtKernel = try? CIKernel(functionName: "crtEmuPass", fromMetalLibraryData: data)
        thresholdKernel = try? CIColorKernel(functionName: "phosphorThreshold",
                                             fromMetalLibraryData: data)
        mergeKernel = try? CIColorKernel(functionName: "phosphorMerge",
                                         fromMetalLibraryData: data)
        if kernel == nil || crtKernel == nil || thresholdKernel == nil || mergeKernel == nil {
            Log.engine.error("Aesthetic kernels missing from the metallib")
        }
    }

    // MARK: - Phosphor bloom

    /// Radii and gains fitted against the reference artwork at 1920 on the long
    /// edge; everything scales off that so a phone canvas gets the same halo in
    /// proportion rather than the same halo in pixels.
    private static let referenceEdge: CGFloat = 1920
    private static let threshold: Float = 0.18
    private static let tightRadius: CGFloat = 20
    private static let tightGain: Float = 0.50
    private static let wideRadius: CGFloat = 160
    private static let wideGain: Float = 0.60

    /// The light a lit phosphor throws into the black around it. Two scales: a
    /// tight halo that hugs the picture and a broad shallow one that carries
    /// most of the sense that the screen is lit rather than printed.
    ///
    /// Returns the image untouched if the kernels are missing or the amount is
    /// nil, so a CRT with no halo is still a CRT.
    func phosphorGlow(_ image: CIImage, canvas: CGRect, amount: Double) -> CIImage {
        guard amount > 0.01, let thresholdKernel, let mergeKernel,
              !image.extent.isEmpty else { return image }
        let scale = max(canvas.width, canvas.height) / Self.referenceEdge
        guard let bright = thresholdKernel.apply(
            extent: canvas, arguments: [image.cropped(to: canvas), Self.threshold]
        ), !bright.extent.isEmpty else { return image }

        func blur(_ radius: CGFloat, downsample: CGFloat) -> CIImage? {
            let small = downsample < 0.999
                ? bright.transformed(by: CGAffineTransform(scaleX: downsample, y: downsample))
                : bright
            let blurred = small
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: max(1, radius * downsample)])
            let restored = downsample < 0.999
                ? blurred.transformed(by: CGAffineTransform(scaleX: 1 / downsample,
                                                            y: 1 / downsample))
                : blurred
            let cropped = restored.cropped(to: canvas)
            return cropped.extent.isEmpty ? nil : cropped
        }

        // The wide pass is a broad, shallow falloff — nothing in it survives a
        // quarter-scale round trip, and at full size a 160px gaussian is the
        // most expensive thing in the frame.
        guard let tight = blur(Self.tightRadius * scale, downsample: 1),
              let wide = blur(Self.wideRadius * scale, downsample: 0.25) else { return image }

        let dose = Float(max(0, min(1.5, amount)))
        guard let merged = mergeKernel.apply(extent: canvas, arguments: [
            image.cropped(to: canvas), tight, wide,
            Self.tightGain * dose, Self.wideGain * dose,
        ]), !merged.extent.isEmpty else { return image }
        return merged
    }

    /// crtemu's tube: needs a blurred copy of the frame alongside the sharp
    /// one, which is where its phosphor ghosting comes from.
    func applyCRT(to image: CIImage, canvas: CGRect, strength: Double,
                  time: Double) -> CIImage? {
        guard let crtKernel else { return nil }
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
            .cropped(to: canvas)
        return crtKernel.apply(extent: canvas,
                               roiCallback: { _, _ in canvas },
                               arguments: [image, blurred,
                                           Float(canvas.width), Float(canvas.height),
                                           Float(time), Float(strength)])
    }

    /// mode: 0 = CRT, 1 = VHS, 2 = NTSC.
    func apply(to image: CIImage, canvas: CGRect, mode: Int, strength: Double,
               time: Double, params: AestheticParams) -> CIImage? {
        guard let kernel else { return nil }
        let arguments: [Any] = [
            image,
            Float(canvas.width), Float(canvas.height),
            Float(mode), Float(strength), Float(time),
            Float(params.scanline), Float(params.chromaBleed), Float(params.wobble),
            Float(params.grain * 0.6 + params.snow), Float(params.tear),
            Float(mode == 0 ? 0.85 : 0),
        ]
        // Curvature and wobble sample outside the pixel, so the region of
        // interest is the whole canvas rather than a neighbourhood.
        return kernel.apply(extent: canvas,
                            roiCallback: { _, _ in canvas },
                            arguments: arguments)
    }
}
