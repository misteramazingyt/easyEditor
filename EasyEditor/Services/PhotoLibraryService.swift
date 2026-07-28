import Foundation
import Photos

/// Saves exported videos to the Photos library (add-only permission).
struct PhotoLibraryService {

    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Photos permission was denied. Enable it in Settings to save exports."
            case .saveFailed(let reason):
                return "Saving to Photos failed: \(reason)"
            }
        }
    }

    func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            throw SaveError.saveFailed(error.localizedDescription)
        }
    }
}
