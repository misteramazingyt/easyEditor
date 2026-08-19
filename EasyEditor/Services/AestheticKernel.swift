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

    var isAvailable: Bool { kernel != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            Log.engine.error("Aesthetic kernel: no metallib in the bundle")
            kernel = nil
            crtKernel = nil
            return
        }
        kernel = try? CIKernel(functionName: "aestheticPass", fromMetalLibraryData: data)
        crtKernel = try? CIKernel(functionName: "crtEmuPass", fromMetalLibraryData: data)
        if kernel == nil || crtKernel == nil {
            Log.engine.error("Aesthetic kernels missing from the metallib")
        }
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
