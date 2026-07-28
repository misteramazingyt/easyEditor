import Foundation
import UIKit
import AVFoundation

/// Generates and caches filmstrip thumbnails for timeline clips.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [String: [UIImage]] = [:]
    private var singles: [String: UIImage] = [:]

    /// Evenly spaced frames across a video's trim window.
    func filmstrip(url: URL, clipID: UUID, trimStart: Double, trimEnd: Double,
                   count: Int, height: CGFloat) -> [UIImage] {
        let key = "\(clipID)-\(count)-\(Int(trimStart * 10))-\(Int(trimEnd * 10))"
        if let hit = cache[key] { return hit }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 8,
                                       height: height * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var images: [UIImage] = []
        let window = max(0.01, trimEnd - trimStart)
        for i in 0..<max(1, count) {
            let t = trimStart + window * (Double(i) + 0.5) / Double(max(1, count))
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                images.append(UIImage(cgImage: cg))
            }
        }
        if !images.isEmpty {
            if cache.count > 200 { cache.removeAll() }
            cache[key] = images
        }
        return images
    }

    /// Single thumbnail for an image clip.
    func imageThumb(url: URL, clipID: UUID, height: CGFloat) -> UIImage? {
        let key = clipID.uuidString
        if let hit = singles[key] { return hit }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let thumb = image.scaledDown(maxDimension: height * 8)
        if singles.count > 200 { singles.removeAll() }
        singles[key] = thumb
        return thumb
    }

    func invalidate(clipID: UUID) {
        cache = cache.filter { !$0.key.hasPrefix(clipID.uuidString) }
        singles[clipID.uuidString] = nil
    }
}
