import Foundation
import NaturalLanguage
import Speech

/// Auto B-Roll: transcribe the storyline, detect visually-representable
/// mentions (proper names, places, books, historical events/periods,
/// concrete objects), fetch matching media, and report placements.
enum AutoBRollService {

    // MARK: - Settings

    enum MediaKind: String, CaseIterable { case images = "Images", video = "Video", both = "Both" }
    enum InsertStyle: String, CaseIterable { case cutaway = "Cutaway", overlay = "Overlay", fullFrame = "Full Frame" }
    enum MediaSource: String, CaseIterable { case desktop = "Desktop", web = "Web", both = "Desktop + Web" }

    struct Settings {
        var people = true
        var places = true
        var books = true
        var events = true
        var periods = true
        var objects = false
        var media: MediaKind = .both
        var insertStyle: InsertStyle = .cutaway
        var source: MediaSource = .both
        var confidence: Double = 0.8
        var maxAssetsPerMention = 1
        var minDurationFrames = 24
        var firstMentionOnly = true
        var avoidRepeats = true
        var fallbackToStills = true
    }

    enum Category: String {
        case person, place, book, event, period, object
    }

    struct Mention {
        var text: String
        var category: Category
        var timelineTime: Double
        var confidence: Double
    }

    // MARK: - Detection

    /// Terms whose visual identity is stable enough to cut away to.
    private static let periodGazetteer: [String] = [
        "middle ages", "renaissance", "enlightenment", "reformation",
        "antiquity", "bronze age", "iron age", "stone age", "belle epoque",
        "gilded age", "roaring twenties", "great depression", "baroque",
        "romantic era", "victorian era", "industrial revolution",
    ]
    private static let eventGazetteer: [String] = [
        "world war", "civil war", "cold war", "space race", "moon landing",
        "french revolution", "american revolution", "crusades",
        "black death", "great fire", "fall of rome", "d-day",
        "manhattan project", "wall street crash",
    ]
    /// Abstract-noun suffixes excluded from "concrete object" detection.
    private static let abstractSuffixes = ["tion", "ness", "ity", "ment", "ance", "ence", "ship", "hood", "logy"]
    private static let bookContext: Set<String> = ["book", "books", "novel", "wrote", "reading", "read",
                                                  "published", "treatise", "essay", "text", "author"]

    /// Detect mentions across the storyline's speech. Times are timeline
    /// seconds, mapped through each clip's trim and speed.
    static func detectMentions(project: VideoProject, settings: Settings) async throws -> [Mention] {
        var mentions: [Mention] = []
        let starts = project.primaryStartTimes
        for clip in project.primaryClips where clip.kind == .video && clip.fileName != nil {
            let url = FilePaths.mediaURL(projectID: project.id, fileName: clip.fileName!)
            let segments: [SFTranscriptionSegment]
            do {
                segments = try await CaptionService.wordSegments(for: url)
            } catch {
                continue
            }
            let inWindow = segments.filter {
                $0.timestamp + $0.duration > clip.trimStart && $0.timestamp < clip.trimEnd
            }
            guard !inWindow.isEmpty else { continue }
            let clipStart = starts[clip.id] ?? 0

            // Joined transcript with char-offset → timeline-time mapping.
            var text = ""
            var wordSpans: [(range: Range<String.Index>, time: Double)] = []
            for segment in inWindow {
                if !text.isEmpty { text += " " }
                let start = text.endIndex
                text += segment.substring
                let timeline = clipStart + (segment.timestamp - clip.trimStart) / clip.speed
                wordSpans.append((start..<text.endIndex, max(0, timeline)))
            }

            func time(at range: Range<String.Index>) -> Double {
                wordSpans.first { $0.range.overlaps(range) }?.time
                    ?? wordSpans.first?.time ?? clipStart
            }

            mentions.append(contentsOf: detect(in: text, settings: settings, time: time))
        }

        // Threshold, repeats, ordering.
        var seen = Set<String>()
        var result: [Mention] = []
        for mention in mentions.sorted(by: { $0.timelineTime < $1.timelineTime }) {
            guard mention.confidence >= settings.confidence - 0.0001 else { continue }
            let key = mention.text.lowercased()
            if settings.firstMentionOnly || settings.avoidRepeats {
                if seen.contains(key) { continue }
            }
            seen.insert(key)
            result.append(mention)
        }
        return Array(result.prefix(25))
    }

    private static func detect(in text: String, settings: Settings,
                               time: (Range<String.Index>) -> Double) -> [Mention] {
        var mentions: [Mention] = []
        let lower = text.lowercased()

        // 1. Named entities (people, places, organizations) via NLTagger.
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        let full = text.startIndex..<text.endIndex
        var claimed: [Range<String.Index>] = []
        tagger.enumerateTags(in: full, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag else { return true }
            let phrase = String(text[range])
            guard phrase.count > 2 else { return true }
            switch tag {
            case .personalName where settings.people:
                mentions.append(Mention(text: phrase, category: .person,
                                        timelineTime: time(range), confidence: 0.9))
                claimed.append(range)
            case .placeName where settings.places:
                mentions.append(Mention(text: phrase, category: .place,
                                        timelineTime: time(range), confidence: 0.9))
                claimed.append(range)
            case .organizationName where settings.places || settings.events:
                mentions.append(Mention(text: phrase, category: .place,
                                        timelineTime: time(range), confidence: 0.8))
                claimed.append(range)
            default:
                break
            }
            return true
        }

        // 2. Historical events / periods: gazetteers, decades, centuries, -isms.
        func scanTerms(_ terms: [String], category: Category, confidence: Double) {
            for term in terms {
                var searchFrom = lower.startIndex
                while let found = lower.range(of: term, range: searchFrom..<lower.endIndex) {
                    // Map the lowercase range back to `text` (same offsets).
                    let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: found.lowerBound))
                    let end = text.index(start, offsetBy: lower.distance(from: found.lowerBound, to: found.upperBound))
                    mentions.append(Mention(text: String(text[start..<end]),
                                            category: category,
                                            timelineTime: time(start..<end),
                                            confidence: confidence))
                    searchFrom = found.upperBound
                }
            }
        }
        if settings.periods { scanTerms(periodGazetteer, category: .period, confidence: 0.85) }
        if settings.events { scanTerms(eventGazetteer, category: .event, confidence: 0.85) }

        if settings.periods {
            for pattern in ["\\b(?:the\\s+)?[12][0-9]{3}s\\b", "\\b[0-9]{1,2}(?:st|nd|rd|th)\\s+century\\b",
                            "\\b\\w{4,}ism\\b"] {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let ns = text as NSString
                    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        if let range = Range(match.range, in: text) {
                            mentions.append(Mention(text: String(text[range]),
                                                    category: .period,
                                                    timelineTime: time(range),
                                                    confidence: 0.82))
                        }
                    }
                }
            }
        }

        // 3. Books: capitalized spans near book-ish context words.
        if settings.books {
            let words = text.split(separator: " ")
            for (index, word) in words.enumerated() where bookContext.contains(word.lowercased()) {
                for neighbor in [index - 2, index - 1, index + 1, index + 2] {
                    guard words.indices.contains(neighbor) else { continue }
                    let candidate = String(words[neighbor])
                    guard let first = candidate.first, first.isUppercase,
                          candidate.count > 3, neighbor != 0 else { continue }
                    if let range = text.range(of: candidate) {
                        mentions.append(Mention(text: candidate, category: .book,
                                                timelineTime: time(range), confidence: 0.75))
                    }
                    break
                }
            }
        }

        // 4. Concrete objects: plain nouns, filtered for abstract suffixes.
        if settings.objects {
            tagger.enumerateTags(in: full, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                guard tag == .noun else { return true }
                guard !claimed.contains(where: { $0.overlaps(range) }) else { return true }
                let word = String(text[range]).lowercased()
                guard word.count >= 4,
                      !abstractSuffixes.contains(where: { word.hasSuffix($0) }) else { return true }
                mentions.append(Mention(text: word, category: .object,
                                        timelineTime: time(range), confidence: 0.55))
                return true
            }
        }
        return mentions
    }
}

// MARK: - Pexels (stock video, optional API key)

/// Free stock video via Pexels — the only piece needing a key, because
/// keyless video sources serve WebM/OGV that AVFoundation can't play.
struct PexelsService {
    static let apiKeyStorageKey = "pexelsApiKey"
    let apiKey: String

    struct VideoHit {
        let downloadURL: URL
        let duration: Double
    }

    func searchVideo(_ query: String) async throws -> VideoHit? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var request = URLRequest(url: URL(string:
            "https://api.pexels.com/videos/search?query=\(encoded)&per_page=3&orientation=landscape")!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Video: Decodable {
                struct File: Decodable {
                    let link: String
                    let width: Int?
                    let file_type: String?
                }
                let duration: Double?
                let video_files: [File]
            }
            let videos: [Video]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        for video in decoded.videos {
            let mp4s = video.video_files
                .filter { ($0.file_type ?? "").contains("mp4") }
                .sorted { abs(($0.width ?? 0) - 1280) < abs(($1.width ?? 0) - 1280) }
            if let best = mp4s.first, let url = URL(string: best.link) {
                return VideoHit(downloadURL: url, duration: video.duration ?? 5)
            }
        }
        return nil
    }
}
