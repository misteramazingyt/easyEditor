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

    /// What the last preset load and the last frame actually did. Read by the
    /// aesthetics sheet: when ntsc-rs falls back, every preset renders the
    /// same default look, and nothing on screen says so.
    enum Status: Equatable {
        case idle
        case running(preset: String)
        /// The JSON loaded but ntsc-rs wouldn't take it — the default effect
        /// is running instead, so every preset looks alike.
        case presetRejected(preset: String)
        case missingPreset(String)
        case unavailable

        var blurb: String {
            switch self {
            case .idle: return "ntsc-rs idle"
            case .running(let preset): return "ntsc-rs running \(preset)"
            case .presetRejected(let preset):
                return "ntsc-rs rejected \(preset) — showing its default look"
            case .missingPreset(let preset): return "preset \(preset) missing from the bundle"
            case .unavailable: return "ntsc-rs unavailable — falling back to the shader"
            }
        }

        var isHealthy: Bool { if case .running = self { return true } else { return false } }
    }

    private var statusLock = NSLock()
    private var _status: Status = .idle
    private(set) var status: Status {
        get { statusLock.lock(); defer { statusLock.unlock() }; return _status }
        set { statusLock.lock(); _status = newValue; statusLock.unlock() }
    }

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
        if let presetID {
            if let url = Bundle.main.url(forResource: presetID, withExtension: "json") {
                json = try? String(contentsOf: url, encoding: .utf8)
            }
            if json == nil {
                Log.engine.error("ntsc-rs preset \(presetID) is not in the bundle")
                status = .missingPreset(presetID)
            }
        }
        var parsed = false
        handle = json.map { text in
            text.withCString { ntsc_bridge_create($0, &parsed) }
        } ?? ntsc_bridge_create(nil, &parsed)
        loadedPresetID = presetID
        if handle == nil {
            Log.engine.error("ntsc-rs effect could not be created")
            status = .unavailable
            return false
        }
        if let presetID, json != nil {
            status = parsed ? .running(preset: presetID) : .presetRejected(preset: presetID)
            if !parsed {
                Log.engine.error("ntsc-rs would not take preset \(presetID); using its defaults")
            }
        }
        return true
    }

    /// Returns nil if anything goes wrong, so the caller can fall back to the
    /// shader path rather than dropping the frame.
    func process(_ image: CIImage, canvas: CGRect, presetID: String?,
                 frame: Int) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard ensureEffect(presetID: presetID), let handle else {
            status = .unavailable
            return nil
        }

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
        guard ok else {
            status = .unavailable
            return nil
        }

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
