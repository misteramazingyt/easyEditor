import Foundation
import CoreGraphics

/// Where a layer sits on the canvas, in terms every clip kind can share.
///
/// `scale` means what the clip's own baseline means: for a still or a title it
/// is the width as a fraction of the canvas, which is what its placement has
/// always been; for video it is a multiple of the aspect-fit the compositor
/// already does, so 1 is exactly the framing you get without touching anything.
/// Either way the transform box reports it as a percentage of that baseline,
/// so it reads the same wherever you grab it.
struct ClipTransform: Codable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var scale: Double = 1
    var rotation: Double = 0        // degrees, clockwise on screen

    static let identity = ClipTransform()

    var isIdentity: Bool { self == .identity }
}

/// Opacity and blend, animated together — they are the two things that decide
/// how a layer meets what is under it, and the user reads them as one track.
struct CompositeValue: Codable, Equatable {
    var opacity: Double = 1
    var blend: BlendMode = .normal
}

protocol KeyframeValue: Codable, Equatable {
    static func interpolate(_ from: Self, _ to: Self, _ t: Double) -> Self
}

extension ClipTransform: KeyframeValue {
    static func interpolate(_ from: ClipTransform, _ to: ClipTransform, _ t: Double) -> ClipTransform {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return ClipTransform(centerX: mix(from.centerX, to.centerX),
                             centerY: mix(from.centerY, to.centerY),
                             scale: mix(from.scale, to.scale),
                             rotation: mix(from.rotation, to.rotation))
    }
}

extension CompositeValue: KeyframeValue {
    static func interpolate(_ from: CompositeValue, _ to: CompositeValue, _ t: Double) -> CompositeValue {
        // A blend mode has no midpoint: it holds until the next key takes over.
        CompositeValue(opacity: from.opacity + (to.opacity - from.opacity) * t,
                       blend: from.blend)
    }
}

/// One key, timed from the clip's own start so trimming or sliding a clip
/// carries its animation along rather than leaving it behind on the timeline.
struct Keyframe<Value: KeyframeValue>: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Value
    /// Shapes the segment *leaving* this key. The last key's easing is unused.
    var easing: EasingCurve = .sine
}

/// A sorted run of keys, and the reading of them the UI needs.
struct KeyframeTrack<Value: KeyframeValue>: Codable, Equatable {
    var keys: [Keyframe<Value>] = []

    var isEmpty: Bool { keys.isEmpty }
    var isActive: Bool { !keys.isEmpty }

    /// How close to a key the playhead counts as being *on* it. A frame at 30fps
    /// is 33ms; half that is tight enough not to swallow a neighbour and loose
    /// enough that scrubbing back to a key lands on it.
    static var snap: Double { 1.0 / 60.0 }

    // MARK: Reading

    func value(at time: Double) -> Value? {
        guard let first = keys.first else { return nil }
        if keys.count == 1 || time <= first.time { return first.value }
        guard let last = keys.last else { return nil }
        if time >= last.time { return last.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            guard time >= a.time, time <= b.time else { continue }
            let span = b.time - a.time
            guard span > 0.0001 else { return b.value }
            let p = MotionEvaluator.eased(a.easing, (time - a.time) / span)
            return Value.interpolate(a.value, b.value, p)
        }
        return last.value
    }

    func index(at time: Double) -> Int? {
        keys.firstIndex { abs($0.time - time) <= Self.snap }
    }

    func key(at time: Double) -> Keyframe<Value>? {
        index(at: time).map { keys[$0] }
    }

    /// The key that governs the segment the playhead is inside — the one it is
    /// sitting on, or the last one behind it.
    func governingIndex(at time: Double) -> Int? {
        if let exact = index(at: time) { return exact }
        return keys.lastIndex { $0.time < time }
    }

    /// What the lozenge should say about this moment.
    enum Marker: Equatable {
        case off        // no keys at all
        case onKey      // the playhead is sitting on one
        case between    // the playhead is inside an animated span
        case outside    // there are keys, but not around here
    }

    func marker(at time: Double) -> Marker {
        guard let first = keys.first, let last = keys.last else { return .off }
        if index(at: time) != nil { return .onKey }
        if time > first.time && time < last.time { return .between }
        return .outside
    }

    // MARK: Writing

    /// Put a value at this time: replace the key already there, or insert one.
    /// Returns whether a key was newly created.
    @discardableResult
    mutating func set(_ value: Value, at time: Double,
                      easing: EasingCurve = .sine) -> Bool {
        if let existing = index(at: time) {
            keys[existing].value = value
            return false
        }
        keys.append(Keyframe(time: max(0, time), value: value, easing: easing))
        keys.sort { $0.time < $1.time }
        return true
    }

    mutating func removeKey(at time: Double) {
        guard let existing = index(at: time) else { return }
        keys.remove(at: existing)
    }

    mutating func setEasing(_ easing: EasingCurve, at time: Double) {
        guard let existing = governingIndex(at: time) else { return }
        keys[existing].easing = easing
    }
}
