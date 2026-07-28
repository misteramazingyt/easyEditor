import Foundation
import AVFoundation

/// A small built-in sound-effect library. Effects are synthesized to WAV on
/// first use (no bundled binary assets), then copied into projects on demand.
struct SFXLibrary {

    struct Effect: Identifiable {
        let id: String
        let name: String
        let systemImage: String
        let duration: Double
        /// amplitude(-1…1) as a function of time and normalized progress.
        let sample: (_ t: Double, _ progress: Double) -> Double
    }

    static let effects: [Effect] = [
        Effect(id: "pop", name: "Pop", systemImage: "bubble.left.fill", duration: 0.18) { t, p in
            sin(2 * .pi * (900 - 500 * p) * t) * exp(-18 * p)
        },
        Effect(id: "whoosh", name: "Whoosh", systemImage: "wind", duration: 0.6) { t, p in
            // Filtered-noise feel: dense detuned sines swept downward.
            let f = 1400.0 - 1000.0 * p
            let env = sin(.pi * p)
            return (sin(2 * .pi * f * t) + 0.5 * sin(2 * .pi * f * 1.31 * t)
                    + 0.25 * sin(2 * .pi * f * 1.77 * t)) / 1.75 * env
        },
        Effect(id: "ding", name: "Ding", systemImage: "bell.fill", duration: 1.0) { t, p in
            (sin(2 * .pi * 1320 * t) + 0.4 * sin(2 * .pi * 2640 * t)) / 1.4 * exp(-4 * p)
        },
        Effect(id: "click", name: "Click", systemImage: "cursorarrow.click", duration: 0.06) { t, p in
            sin(2 * .pi * 2200 * t) * exp(-40 * p)
        },
        Effect(id: "riser", name: "Riser", systemImage: "chart.line.uptrend.xyaxis", duration: 1.5) { t, p in
            sin(2 * .pi * (220 + 660 * p * p) * t) * p * (1 - pow(max(0, p - 0.9) * 10, 2))
        },
        Effect(id: "thud", name: "Thud", systemImage: "hammer.fill", duration: 0.35) { t, p in
            sin(2 * .pi * (140 - 60 * p) * t) * exp(-8 * p)
        },
    ]

    /// Synthesize (once) and return the shared WAV URL for an effect.
    static func url(for effect: Effect) -> URL? {
        let url = FilePaths.sfxDirectory.appendingPathComponent("\(effect.id).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data = renderWAV(effect: effect)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.audio.error("SFX synth failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 16-bit mono PCM WAV at 44.1 kHz.
    private static func renderWAV(effect: Effect) -> Data {
        let sampleRate = 44_100
        let count = Int(Double(sampleRate) * effect.duration)
        var samples = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let p = Double(i) / Double(max(1, count - 1))
            let v = max(-1, min(1, effect.sample(t, p) * 0.8))
            var s = Int16(v * Double(Int16.max))
            withUnsafeBytes(of: &s) { samples.append(contentsOf: $0) }
        }

        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + samples.count))
        append("WAVE")
        append("fmt ")
        append32(16)                    // PCM chunk size
        append16(1)                     // PCM format
        append16(1)                     // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2)) // byte rate
        append16(2)                     // block align
        append16(16)                    // bits per sample
        append("data")
        append32(UInt32(samples.count))
        data.append(samples)
        return data
    }

    /// Copy an effect into a project's media folder; returns (fileName, duration).
    static func copyIntoProject(_ effect: Effect, projectID: UUID) -> (String, Double)? {
        guard let source = url(for: effect) else { return nil }
        let fileName = "sfx-\(effect.id)-\(UUID().uuidString.prefix(8)).wav"
        let dest = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return (fileName, effect.duration)
        } catch {
            return nil
        }
    }
}
