import Foundation

/// One clip anywhere on the timeline. Primary-storyline clips are ordered and
/// magnetic (their start times are derived); connected clips carry an explicit
/// `offset` on the timeline, FCP style.
struct TimelineClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var lane: Lane

    /// Media file inside the project's Media directory (nil for titles).
    var fileName: String?

    /// Duration of the source media in seconds (0 for images/titles).
    var assetDuration: Double = 0

    /// Trim window into the source media (seconds). For images/titles the
    /// window is simply 0..<display length.
    var trimStart: Double = 0
    var trimEnd: Double = 0

    /// Timeline start in seconds — used for connected clips only.
    var offset: Double = 0

    /// Sort key within the primary storyline — used for primary clips only.
    var order: Int = 0

    var speed: Double = 1          // 0.3 ... 3, video/audio only
    var volume: Double = 1
    var isMuted = false

    var filter: FilterPreset = .none
    var adjustments = Adjustments()
    var rotationQuarterTurns: Int = 0
    var isFlippedH = false

    /// Whole-clip opacity for video layers (optional for old saved projects).
    var opacity: Double?
    var effectiveOpacity: Double { opacity ?? 1 }

    /// Structural effect and shape mask (optional for old saved projects).
    var effect: EffectPreset?
    var mask: MaskSettings?

    /// Transition into the *next* primary clip (primary storyline only).
    var transitionToNext: Transition?

    var text: TextPayload?
    var placement: OverlayPlacement?

    // MARK: Derived

    /// Length the clip occupies on the timeline, after trim + speed.
    var effectiveDuration: Double {
        let window = max(0.05, trimEnd - trimStart)
        switch kind {
        case .video, .music, .voiceover, .sfx:
            return window / max(0.1, speed)
        case .image, .title:
            return window
        }
    }

    var canAdjustSpeed: Bool { kind == .video }
    var hasAudio: Bool { kind != .image && kind != .title }
    var isVisual: Bool { kind == .video || kind == .image || kind == .title }

    // MARK: Factories

    static func video(fileName: String, duration: Double, order: Int) -> TimelineClip {
        TimelineClip(kind: .video, lane: .primary, fileName: fileName,
                     assetDuration: duration, trimStart: 0, trimEnd: duration, order: order)
    }

    static func image(fileName: String, at offset: Double) -> TimelineClip {
        TimelineClip(kind: .image, lane: .images, fileName: fileName,
                     assetDuration: 0, trimStart: 0, trimEnd: 4, offset: offset,
                     placement: .image)
    }

    static func title(_ payload: TextPayload, placement: OverlayPlacement, at offset: Double) -> TimelineClip {
        TimelineClip(kind: .title, lane: .titles, fileName: nil,
                     assetDuration: 0, trimStart: 0, trimEnd: 3, offset: offset,
                     text: payload, placement: placement)
    }

    static func audio(kind: ClipKind, fileName: String, duration: Double, at offset: Double) -> TimelineClip {
        TimelineClip(kind: kind, lane: kind == .music ? .music : .voice, fileName: fileName,
                     assetDuration: duration, trimStart: 0, trimEnd: duration, offset: offset)
    }
}
