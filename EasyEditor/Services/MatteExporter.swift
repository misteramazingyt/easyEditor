import Foundation
import AVFoundation
import CoreImage

/// Write a clip's alpha out as a picture of its own.
///
/// Recordings are HEVC with alpha, which keeps them small and which nothing
/// outside Apple's decoders will read: the alpha lives in a separate auxiliary
/// picture layer, and Resolve on Windows — and ffmpeg 7, checked — decodes the
/// base layer alone. Because the alpha is premultiplied, the base layer's
/// transparent pixels are black, so ignoring the alpha does not merely lose
/// the key, it fills it in with black.
///
/// The alternative that carries alpha everywhere is ProRes 4444, at roughly
/// 40 MB a second. So instead the colour goes over as it was recorded and the
/// alpha goes beside it as an ordinary greyscale movie — white where the
/// subject is, black where it is not. A soft silhouette compresses to almost
/// nothing, and Resolve reads it as an external matte.
enum MatteExporter {

    static func matteName(for fileName: String) -> String {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return "\(base).matte.mov"
    }

    /// True if this file actually carries an alpha channel worth extracting.
    static func hasAlpha(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions) else { return false }
        for description in descriptions {
            let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any]
            if extensions?[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool == true {
                return true
            }
            let codec = CMFormatDescriptionGetMediaSubType(description)
            // 'muxa' is HEVC with alpha; ProRes 4444 carries one too.
            if codec == kCMVideoCodecType_HEVCWithAlpha || codec == kCMVideoCodecType_AppleProRes4444 {
                return true
            }
        }
        return false
    }

    /// Render the alpha of `source` to a greyscale movie at `destination`.
    static func write(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "com.easyeditor.matte", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "That recording has no picture in it.",
            ])
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let turned = abs(transform.b) == 1 && abs(transform.c) == 1
        let size = turned
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                // A matte is a silhouette: flat white, flat black, a soft edge.
                // It needs almost no bitrate and it must not be blurred away,
                // so the profile is high and the rate is modest.
                AVVideoAverageBitRateKey: Int(size.width * size.height * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(naturalSize.width),
                kCVPixelBufferHeightKey as String: Int(naturalSize.height),
            ])
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? NSError(
                domain: "com.easyeditor.matte", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "The matte writer wouldn't start.",
                ])
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let queue = DispatchQueue(label: "com.easyeditor.matte")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sample = output.copyNextSampleBuffer(),
                          let buffer = CMSampleBufferGetImageBuffer(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    let image = CIImage(cvPixelBuffer: buffer)
                    // Alpha into all three colour channels: the matte reads as
                    // a greyscale picture rather than as a transparent one,
                    // because the point is that it survives a decoder that
                    // throws transparency away.
                    let grey = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    ])
                    var out: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                    }
                    guard let out else { continue }
                    context.render(grey, to: out)
                    adaptor.append(out, withPresentationTime: time)
                }
            }
        }
        reader.cancelReading()
        await writer.finishWriting()
        _ = frameRate
    }
}
