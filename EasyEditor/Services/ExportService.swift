import Foundation
import AVFoundation

/// Renders a project to an MP4 in Documents/Exports via AVAssetExportSession,
/// reusing the exact composition + custom compositor the preview plays.
final class ExportService {

    enum ExportError: LocalizedError {
        case sessionCreationFailed
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed: return "Could not create the export session."
            case .exportFailed(let reason): return "Export failed: \(reason)"
            case .cancelled: return "Export was cancelled."
            }
        }
    }

    private var session: AVAssetExportSession?

    /// Returns the exported file URL. `progress` is polled on the main actor.
    func export(built: BuiltComposition,
                projectName: String,
                progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let safeName = projectName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_",
                                                        options: .regularExpression)
        let outURL = FilePaths.exportsDirectory
            .appendingPathComponent("\(safeName)-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let session = AVAssetExportSession(asset: built.composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionCreationFailed
        }
        self.session = session
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .timeDomain
        session.shouldOptimizeForNetworkUse = true

        let poller = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }

        await session.export()

        switch session.status {
        case .completed:
            await progress(1)
            Log.export.info("Exported \(outURL.lastPathComponent)")
            return outURL
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    func cancel() {
        session?.cancelExport()
    }
}
