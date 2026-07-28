import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Receives a movie from the Photos picker as a file on disk.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FilePaths.tempDirectory
                .appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

enum ImportedMedia {
    case video(fileName: String, duration: Double)
    case image(fileName: String)
    case audio(fileName: String, duration: Double)
}

/// Copies picked media into a project's Media directory and probes durations.
struct MediaImportService {

    /// Import one Photos picker item (video or image).
    func importPickerItem(_ item: PhotosPickerItem, projectID: UUID) async -> ImportedMedia? {
        let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if isMovie {
            guard let movie = try? await item.loadTransferable(type: MovieFile.self) else {
                Log.importer.error("Movie load failed")
                return nil
            }
            return await importVideoFile(movie.url, projectID: projectID, deleteSource: true)
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            Log.importer.error("Image load failed")
            return nil
        }
        let fileName = UUID().uuidString + ".jpg"
        let dest = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        let scaled = image.scaledDown(maxDimension: 2160)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try jpeg.write(to: dest, options: .atomic)
            return .image(fileName: fileName)
        } catch {
            Log.importer.error("Image write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Copy a video file (already on disk) into the project and probe it.
    func importVideoFile(_ url: URL, projectID: UUID, deleteSource: Bool) async -> ImportedMedia? {
        let fileName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let dest = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            if deleteSource { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: dest)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > 0 else {
                try? FileManager.default.removeItem(at: dest)
                return nil
            }
            return .video(fileName: fileName, duration: duration)
        } catch {
            Log.importer.error("Video copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Import an audio file picked via the Files importer (security scoped).
    func importAudioFile(_ url: URL, projectID: UUID) async -> ImportedMedia? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        let dest = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let asset = AVURLAsset(url: dest)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > 0 else {
                try? FileManager.default.removeItem(at: dest)
                return nil
            }
            return .audio(fileName: fileName, duration: duration)
        } catch {
            Log.importer.error("Audio copy failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension UIImage {
    func scaledDown(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
