import UIKit
import AVFoundation
import CoreImage

/// A still of one layer on its own, for the view to drag around.
///
/// The picture cannot follow a finger through AVPlayer: every re-render is a
/// seek and a decode, tens of milliseconds each. So while a handle is held the
/// layer is lifted out of the composition and drawn here instead, in SwiftUI,
/// at the refresh rate of the screen. What it needs is the layer by itself —
/// a still or title as it was rendered, or a single frame of the footage.
@MainActor
final class LayerPreviewCache {
    static let shared = LayerPreviewCache()

    private var images: [UUID: UIImage] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init() {}

    func cached(_ id: UUID) -> UIImage? { images[id] }

    func clear() { images.removeAll() }

    /// Stills and titles are already rendered for the compositor; this just
    /// keeps a UIImage of each so the view can reach one without a round trip.
    func store(_ image: CIImage, for id: UUID) {
        guard images[id] == nil, !image.extent.isEmpty,
              let cgImage = context.createCGImage(image, from: image.extent) else { return }
        images[id] = UIImage(cgImage: cgImage)
    }

    /// One frame of footage, at the point of the clip the playhead is on.
    /// Cheap enough to do at the moment a drag starts, and kept afterwards.
    func frame(for clip: TimelineClip, projectID: UUID, at localTime: Double) async -> UIImage? {
        if let hit = images[clip.id] { return hit }
        guard clip.kind == .video, let fileName = clip.fileName else { return nil }
        let url = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let source = clip.trimStart + max(0, localTime) * max(0.1, clip.speed)
        let time = CMTime(seconds: min(source, max(0, clip.assetDuration - 0.05)),
                          preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        let image = UIImage(cgImage: cgImage)
        images[clip.id] = image
        return image
    }
}
