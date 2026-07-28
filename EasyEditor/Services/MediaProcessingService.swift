import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Frame-level media generation: reversed clips and freeze-frame stills.
/// Both write new movie files into the project's media directory.
enum MediaProcessingService {

    enum ProcessingError: LocalizedError {
        case noVideoTrack
        case readerFailed
        case writerFailed(String)
        case frameGrabFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "That clip has no video track."
            case .readerFailed: return "Couldn't read the clip's frames."
            case .writerFailed(let reason): return "Couldn't write the new clip: \(reason)"
            case .frameGrabFailed: return "Couldn't grab a frame at the playhead."
            }
        }
    }

    // MARK: - Reverse

    /// Write a reversed copy of `source`'s video to `destination` (.mov).
    /// Audio is dropped — reversed speech is rarely wanted and this keeps the
    /// pipeline memory-safe. Frames are processed in small chunks from the
    /// end so long clips never hold more than ~80 MB of frames at once.
    static func reverseVideo(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let duration = (try await asset.load(.duration)).seconds
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = max(10, try await track.load(.nominalFrameRate))

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
        ])
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: nil)
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "start")
        }
        writer.startSession(atSourceTime: .zero)

        // Chunk length sized so a chunk of NV12 frames stays under ~80 MB.
        let bytesPerFrame = Double(naturalSize.width * naturalSize.height) * 1.5
        let maxFrames = max(4, Int(80_000_000 / max(1, bytesPerFrame)))
        let chunkSeconds = min(0.5, Double(maxFrames) / Double(fps))

        var chunkEnd = duration
        while chunkEnd > 0.0001 {
            let chunkStart = max(0, chunkEnd - chunkSeconds)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: chunkStart, preferredTimescale: 600),
                end: CMTime(seconds: chunkEnd, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ProcessingError.readerFailed }
            reader.add(output)
            guard reader.startReading() else { throw ProcessingError.readerFailed }

            var frames: [(buffer: CVPixelBuffer, seconds: Double)] = []
            while let sample = output.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frames.append((buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds))
                }
            }
            reader.cancelReading()

            for frame in frames.reversed() {
                while !writerInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                // A frame at source time t lands at (duration - t) from the end.
                let newSeconds = max(0, duration - frame.seconds - (1.0 / Double(fps)))
                adaptor.append(frame.buffer,
                               withPresentationTime: CMTime(seconds: newSeconds,
                                                            preferredTimescale: 600))
            }
            chunkEnd = chunkStart
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
    }

    // MARK: - Freeze frame

    /// Grab the frame of `source` at `sourceTime` and write it out as a
    /// silent `length`-second video (.mov) — TikTok's Freeze.
    static func writeStillVideo(source: URL, at sourceTime: Double,
                                length: Double, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(
                at: CMTime(seconds: sourceTime, preferredTimescale: 600), actualTime: nil)
        } catch {
            throw ProcessingError.frameGrabFailed
        }

        // Even dimensions for H.264.
        let width = cgImage.width - (cgImage.width % 2)
        let height = cgImage.height - (cgImage.height % 2)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "start")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw ProcessingError.writerFailed("no pixel buffer pool")
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else {
            throw ProcessingError.writerFailed("no pixel buffer")
        }
        let context = CIContext()
        context.render(CIImage(cgImage: cgImage), to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        let fps = 30
        let total = Int(length * Double(fps))
        for i in 0..<total {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProcessingError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
    }
}
