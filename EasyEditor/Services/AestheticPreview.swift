import UIKit
import CoreImage

/// Preview stills for the aesthetics gallery.
///
/// The ntsc-rs looks ship with their previews already rendered — the desktop
/// renderer produced them from the same preset JSON the app runs, so a tile is
/// honest about what you'll get. CRT and VHS have no such source: they are
/// shaders that only exist on the device, so their tiles are rendered here,
/// once, over the same dummy frame.
enum AestheticPreview {

    /// The untreated frame every tile is a variation of.
    static let dummy: UIImage? = {
        guard let url = Bundle.main.url(forResource: "aesthetic-dummy", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else {
            Log.engine.error("Aesthetic dummy frame missing from the bundle")
            return nil
        }
        return UIImage(data: data)
    }()

    /// Decoded stills, so scrolling the gallery doesn't re-read the bundle.
    private static let bundledCache = NSCache<NSString, UIImage>()

    /// A pre-rendered ntsc-rs preview, by preset slug.
    static func bundled(_ slug: String) -> UIImage? {
        let key = slug as NSString
        if let hit = bundledCache.object(forKey: key) { return hit }
        guard let url = Bundle.main.url(forResource: "preview-\(slug)", withExtension: "jpg"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        bundledCache.setObject(image, forKey: key)
        return image
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let cache = Cache()

    private actor Cache {
        private var images: [AestheticMode: UIImage] = [:]
        func stored(_ mode: AestheticMode) -> UIImage? { images[mode] }
        func store(_ image: UIImage, for mode: AestheticMode) { images[mode] = image }
    }

    /// Runs the real treatment over the dummy frame. Kept off the main actor:
    /// the tube shader is a real frame of work, and the gallery shouldn't wait
    /// on it before drawing.
    static func rendered(mode: AestheticMode) async -> UIImage? {
        guard mode == .crt || mode == .vhs else { return dummy }
        if let hit = await cache.stored(mode) { return hit }
        let made = await Task.detached(priority: .userInitiated) {
            render(mode)
        }.value
        if let made { await cache.store(made, for: mode) }
        return made
    }

    private static func render(_ mode: AestheticMode) -> UIImage? {
        guard let dummy, let source = CIImage(image: dummy) else { return nil }
        let canvas = source.extent
        let config = AestheticFrameConfig(mode: mode,
                                          params: mode == .crt ? .crt : .vhs,
                                          strength: 0.85, caustics: 0, presetID: nil)
        // A settled moment rather than frame zero: both looks animate, and at
        // t = 0 the wobble and the tear sit at rest.
        let treated = AestheticRenderer.treat(source, config, canvas: canvas,
                                              time: 0.37, weight: 1)
        guard let cgImage = context.createCGImage(treated, from: canvas) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
