import Foundation

/// A whole editable project. Value type on purpose: undo is a snapshot stack.
struct VideoProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "Untitled"
    var createdAt = Date()
    var modifiedAt = Date()
    var aspect: AspectPreset = .portrait916
    var clips: [TimelineClip] = []

    // MARK: Storyline

    /// Primary-storyline clips in playback order.
    var primaryClips: [TimelineClip] {
        clips.filter { $0.lane == .primary }.sorted { $0.order < $1.order }
    }

    var connectedClips: [TimelineClip] {
        clips.filter { $0.lane != .primary }
    }

    func clips(in lane: Lane) -> [TimelineClip] {
        if lane == .primary { return primaryClips }
        return clips.filter { $0.lane == lane }.sorted { $0.offset < $1.offset }
    }

    /// Magnetic start time of every primary clip, accounting for transition
    /// overlaps (a transition pulls the next clip back so both have media
    /// during the blend).
    var primaryStartTimes: [UUID: Double] {
        var result: [UUID: Double] = [:]
        var cursor = 0.0
        let ordered = primaryClips
        for (i, clip) in ordered.enumerated() {
            result[clip.id] = cursor
            var advance = clip.effectiveDuration
            if i < ordered.count - 1, let t = clip.transitionToNext {
                let maxOverlap = min(clip.effectiveDuration, ordered[i + 1].effectiveDuration) * 0.45
                advance -= min(t.overlap, maxOverlap)
            }
            cursor += advance
        }
        return result
    }

    func start(of clip: TimelineClip) -> Double {
        if clip.lane == .primary {
            return primaryStartTimes[clip.id] ?? 0
        }
        return clip.offset
    }

    var storylineDuration: Double {
        let starts = primaryStartTimes
        return primaryClips.map { (starts[$0.id] ?? 0) + $0.effectiveDuration }.max() ?? 0
    }

    /// Total timeline length (storyline plus any connected clip that runs longer).
    var duration: Double {
        let connectedEnd = connectedClips.map { $0.offset + $0.effectiveDuration }.max() ?? 0
        return max(storylineDuration, connectedEnd)
    }

    // MARK: Mutation helpers

    func clip(_ id: UUID) -> TimelineClip? {
        clips.first { $0.id == id }
    }

    mutating func update(_ clip: TimelineClip) {
        if let i = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[i] = clip
            modifiedAt = Date()
        }
    }

    mutating func remove(_ id: UUID) {
        clips.removeAll { $0.id == id }
        renumberPrimary()
        modifiedAt = Date()
    }

    mutating func append(_ clip: TimelineClip) {
        clips.append(clip)
        renumberPrimary()
        modifiedAt = Date()
    }

    /// Keep primary `order` values dense (0,1,2,…) after any structural change.
    mutating func renumberPrimary() {
        let ordered = primaryClips
        for (i, c) in ordered.enumerated() where c.order != i {
            if let idx = clips.firstIndex(where: { $0.id == c.id }) {
                clips[idx].order = i
            }
        }
    }

    var nextPrimaryOrder: Int {
        (primaryClips.map(\.order).max() ?? -1) + 1
    }
}
