import Foundation
import CoreImage

/// Runs the **real ntsc-rs** over a frame: the Rust crate is cross-compiled to
/// a static library and linked into the app, so this is the same signal
/// processing the desktop tool does, driven by the same preset JSON — not an
/// emulation of it.
///
/// It is CPU work (YIQ conversion, field-by-field filtering, back to RGB), so
/// frames are processed at a reduced width and scaled back up. ntsc-rs is told
/// that scale, so artefact sizes stay true instead of growing with the
/// downsample.
final class NtscRSProcessor {

    /// Wide enough to keep the artefacts legible, small enough to stay
    /// interactive. Broadcast NTSC is 640 active samples anyway.
    private static let processingWidth: CGFloat = 640

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var loadedPresetID: String?

    static let shared = NtscRSProcessor()

    private init() {}

    deinit {
        if let handle { ntsc_bridge_destroy(handle) }
    }

    /// Point the processor at a bundled preset. Cheap to call repeatedly; the
    /// effect is only rebuilt when the preset actually changes.
    private func ensureEffect(presetID: String?) -> Bool {
        if handle != nil, loadedPresetID == presetID { return true }
        if let handle {
            ntsc_bridge_destroy(handle)
            self.handle = nil
        }
        var json: String?
        if let presetID,
           let url = Bundle.main.url(forResource: presetID, withExtension: "json") {
            json = try? String(contentsOf: url, encoding: .utf8)
        }
        handle = json.map { text in text.withCString { ntsc_bridge_create($0) } }
            ?? ntsc_bridge_create(nil)
        loadedPresetID = presetID
        if handle == nil {
            Log.engine.error("ntsc-rs effect could not be created")
            return false
        }
        return true
    }

    /// Returns nil if anything goes wrong, so the caller can fall back to the
    /// shader path rather than dropping the frame.
    func process(_ image: CIImage, canvas: CGRect, presetID: String?,
                 frame: Int) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard ensureEffect(presetID: presetID), let handle else { return nil }

        let scale = min(1, Self.processingWidth / max(1, canvas.width))
        let width = Int((canvas.width * scale).rounded())
        let height = Int((canvas.height * scale).rounded())
        guard width > 16, height > 16 else { return nil }

        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(small, toBitmap: base, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        // ntsc-rs works on a broadcast-sized raster; tell it how far off we are.
        let artefactScale = Float(CGFloat(width) / Self.processingWidth)
        let ok = pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return ntsc_bridge_process(handle, base, width, height, frame, artefactScale)
        }
        guard ok else { return nil }

        let data = Data(pixels)
        let processed = CIImage(bitmapData: data, bytesPerRow: rowBytes,
                                size: CGSize(width: width, height: height),
                                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        guard !processed.extent.isEmpty else { return nil }
        return processed
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: canvas)
    }
}
