import Foundation
import CoreImage
import CoreVideo
import Vision

/// Background removal: Vision person segmentation for video frames,
/// Vision subject lifting for stills, and white/black color keying.
enum CutoutService {

    // MARK: - Person segmentation (per video frame, preview + export)

    /// Reusable request — creating one per frame is wasteful.
    private static let personRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private static let personLock = NSLock()

    /// Mask the person in `image` (which came from `buffer`); everything else
    /// becomes transparent. Returns the input unchanged on failure.
    static func personMasked(_ image: CIImage, buffer: CVPixelBuffer) -> CIImage {
        personLock.lock()
        defer { personLock.unlock() }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([personRequest])
        } catch {
            return image
        }
        guard let maskBuffer = personRequest.results?.first?.pixelBuffer else {
            return image
        }
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let scaleX = image.extent.width / mask.extent.width
        let scaleY = image.extent.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return blend(image, mask: mask)
    }

    // MARK: - Subject lifting (stills, iOS 17+)

    /// Isolate the salient subject of a still image (object on any background).
    static func subjectCutout(cgImage: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let maskedBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false)
            return CIImage(cvPixelBuffer: maskedBuffer)
        } catch {
            Log.engine.error("Subject cutout failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - White / black keying (plain-background stills or video)

    /// Remove near-white (or near-black) pixels via a color cube.
    static func colorKeyed(_ image: CIImage, removeWhite: Bool) -> CIImage {
        let cube = removeWhite ? whiteCube : blackCube
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": cube,
            "inputColorSpace": CGColorSpaceCreateDeviceRGB(),
        ])
    }

    private static let cubeDimension = 32

    private static let whiteCube: Data = makeCube { r, g, b in
        // Luma high and channels close together = white-ish background.
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        let spread = max(r, g, b) - min(r, g, b)
        if luma > 0.98 && spread < 0.1 { return 0 }
        if luma > 0.9 && spread < 0.08 {
            return Float((0.98 - luma) / 0.08) // soft edge
        }
        return 1
    }

    private static let blackCube: Data = makeCube { r, g, b in
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        let spread = max(r, g, b) - min(r, g, b)
        if luma < 0.04 && spread < 0.1 { return 0 }
        if luma < 0.12 && spread < 0.08 {
            return Float((luma - 0.04) / 0.08)
        }
        return 1
    }

    private static func makeCube(alpha: (Double, Double, Double) -> Float) -> Data {
        let dim = cubeDimension
        var cube = [Float](repeating: 0, count: dim * dim * dim * 4)
        var offset = 0
        for b in 0..<dim {
            for g in 0..<dim {
                for r in 0..<dim {
                    let rf = Double(r) / Double(dim - 1)
                    let gf = Double(g) / Double(dim - 1)
                    let bf = Double(b) / Double(dim - 1)
                    let a = max(0, min(1, alpha(rf, gf, bf)))
                    // Premultiplied RGBA.
                    cube[offset] = Float(rf) * a
                    cube[offset + 1] = Float(gf) * a
                    cube[offset + 2] = Float(bf) * a
                    cube[offset + 3] = a
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Shared

    private static func blend(_ image: CIImage, mask: CIImage) -> CIImage {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }
}
