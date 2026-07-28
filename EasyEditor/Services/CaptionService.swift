import Foundation
import Speech

/// On-device auto captions (TikTok "Captions" parity): transcribes a clip's
/// audio and groups the words into short timed caption chunks.
enum CaptionService {

    struct Chunk {
        var text: String
        var start: Double     // seconds in *source media* time
        var duration: Double
    }

    enum CaptionError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available for your language right now." }
    }

    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe `url` and return caption chunks inside the trim window.
    static func captions(for url: URL, trimStart: Double, trimEnd: Double) async throws -> [Chunk] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw CaptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished { finished = true; continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                if !finished {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments)
                }
            }
        }

        let inWindow = segments.filter {
            $0.timestamp + $0.duration > trimStart && $0.timestamp < trimEnd
        }
        return chunk(inWindow)
    }

    /// Group word segments into short readable captions (≤4 words / ≤2.2s).
    private static func chunk(_ segments: [SFTranscriptionSegment]) -> [Chunk] {
        var chunks: [Chunk] = []
        var words: [String] = []
        var chunkStart: Double = 0
        var chunkEnd: Double = 0

        func flush() {
            guard !words.isEmpty else { return }
            chunks.append(Chunk(text: words.joined(separator: " "),
                                start: chunkStart,
                                duration: max(0.6, chunkEnd - chunkStart)))
            words = []
        }

        for segment in segments {
            if words.isEmpty {
                chunkStart = segment.timestamp
            }
            words.append(segment.substring)
            chunkEnd = segment.timestamp + segment.duration
            let tooLong = chunkEnd - chunkStart > 2.2 || words.count >= 4
            if tooLong { flush() }
        }
        flush()
        return chunks
    }
}
