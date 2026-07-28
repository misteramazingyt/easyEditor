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

    /// Import one Photos picker item (video or image). `supportedContentTypes`
    /// is not always populated, so try both representations before giving up.
    func importPickerItem(_ item: PhotosPickerItem, projectID: UUID) async -> ImportedMedia? {
        let types = item.supportedContentTypes
        let looksLikeMovie = types.isEmpty
            || types.contains { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }
        Log.importer.info("Importing picker item, types: \(types.map(\.identifier).joined(separator: ","))")

        if looksLikeMovie {
            do {
                if let movie = try await item.loadTransferable(type: MovieFile.self) {
                    return await importVideoFile(movie.url, projectID: projectID, deleteSource: true)
                }
            } catch {
                Log.importer.error("Movie load failed: \(error.localizedDescription)")
            }
        }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let fileName = saveImageData(data, projectID: projectID) {
                return .image(fileName: fileName)
            }
        } catch {
            Log.importer.error("Image load failed: \(error.localizedDescription)")
        }
        // Last resort: some items report image types but only deliver a movie.
        if !looksLikeMovie, let movie = try? await item.loadTransferable(type: MovieFile.self) {
            return await importVideoFile(movie.url, projectID: projectID, deleteSource: true)
        }
        Log.importer.error("No usable representation for picker item")
        return nil
    }

    /// Decode image data (Photos pick or web download), downscale, and store
    /// it in the project. Returns the stored file name.
    func saveImageData(_ data: Data, projectID: UUID) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let fileName = UUID().uuidString + ".jpg"
        let dest = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        let scaled = image.scaledDown(maxDimension: 2160)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try jpeg.write(to: dest, options: .atomic)
            return fileName
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
