import Foundation
import AVFoundation

/// Find the quiet parts of a clip.
///
/// The thresholds and the shaping are carried over from vex's `trim_silence`,
/// which drives ffmpeg's `silencedetect` and then tidies up what comes back.
/// There is no ffmpeg here, so the detection is done directly off the samples
/// — an RMS window against a dBFS floor is what `silencedetect` is doing
/// anyway — and the tidying is the same: pad back toward the speech, merge
/// removals that nearly touch, and never leave a sliver of a take behind.
enum SilenceDetector {

    struct Settings: Codable, Equatable {
        /// Quiet has to last this long to count as silence.
        var minSilence: Double = 0.5
        /// Below this is quiet.
        var thresholdDB: Double = -35
        /// Leave this much of the quiet either side of speech, so words don't
        /// start clipped.
        var padding: Double = 0.12
        /// Removals closer together than this become one.
        var mergeGap: Double = 0.18
        /// Never leave a kept piece shorter than this.
        var minKeep: Double = 0.28
        /// Whether quiet at the very start and end may go too.
        var trimEdges = false

        static let `default` = Settings()
    }

    /// Windows of 20ms, which is fine enough to catch the edge of a word and
    /// coarse enough not to trip over a single quiet sample.
    private static let window = 0.02

    /// The parts worth keeping, in the asset's own time.
    static func keepRanges(url: URL, from start: Double, to end: Double,
                           settings: Settings) async throws -> [ClosedRange<Double>] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return [start...end]
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [start...end] }
        reader.add(output)
        guard reader.startReading() else { return [start...end] }

        let rate = try await track.load(.naturalTimeScale)
        let sampleRate = Double(rate > 0 ? rate : 44_100)
        var loudness: [Bool] = []              // one flag per window: is it loud?
        var carry: [Float] = []
        let perWindow = max(1, Int(window * sampleRate))
        let floor = pow(10, settings.thresholdDB / 20)

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                carry.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }
            while carry.count >= perWindow {
                let slice = carry[0..<perWindow]
                var sum: Double = 0
                for value in slice { sum += Double(value) * Double(value) }
                loudness.append(sqrt(sum / Double(perWindow)) >= floor)
                carry.removeFirst(perWindow)
            }
        }
        reader.cancelReading()
        if !carry.isEmpty {
            var sum: Double = 0
            for value in carry { sum += Double(value) * Double(value) }
            loudness.append(sqrt(sum / Double(carry.count)) >= floor)
        }
        guard !loudness.isEmpty else { return [start...end] }

        return shape(loudness: loudness, start: start, end: end, settings: settings)
    }

    /// Turn per-window flags into keep ranges, doing what vex does afterwards.
    private static func shape(loudness: [Bool], start: Double, end: Double,
                              settings: Settings) -> [ClosedRange<Double>] {
        let duration = end - start

        // Runs of quiet, in seconds from the clip's start.
        var silences: [(Double, Double)] = []
        var runStart: Int?
        for (index, loud) in loudness.enumerated() {
            if loud {
                if let from = runStart {
                    silences.append((Double(from) * window, Double(index) * window))
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = index
            }
        }
        if let from = runStart { silences.append((Double(from) * window, duration)) }

        // Only long enough ones, padded back toward the speech, and only from
        // the middle unless the edges were asked for.
        var removals: [(Double, Double)] = []
        for (from, to) in silences {
            guard to - from >= settings.minSilence else { continue }
            if !settings.trimEdges, from <= max(settings.padding, 0.06) { continue }
            if !settings.trimEdges, to >= duration - max(settings.padding, 0.06) { continue }
            var a = settings.trimEdges && from <= settings.padding ? 0 : from + settings.padding
            var b = settings.trimEdges && to >= duration - settings.padding
                ? duration : to - settings.padding
            a = max(0, min(a, duration))
            b = max(0, min(b, duration))
            guard b - a >= 0.08 else { continue }
            removals.append((a, b))
        }

        // Merge the ones that all but touch.
        removals.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for range in removals {
            if let last = merged.last, range.0 - last.1 <= settings.mergeGap {
                merged[merged.count - 1] = (last.0, max(last.1, range.1))
            } else {
                merged.append(range)
            }
        }
        guard !merged.isEmpty else { return [start...end] }

        // What's left, minus anything too short to be a take.
        var keeps: [(Double, Double)] = []
        var cursor = 0.0
        for (from, to) in merged {
            if from - cursor > 0.001 { keeps.append((cursor, from)) }
            cursor = to
        }
        if duration - cursor > 0.001 { keeps.append((cursor, duration)) }
        keeps.removeAll { $0.1 - $0.0 < settings.minKeep }
        guard !keeps.isEmpty else { return [start...end] }

        return keeps.map { (start + $0.0)...(start + $0.1) }
    }
}
