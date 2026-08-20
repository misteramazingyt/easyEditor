import Foundation

/// Framing that is being dragged right now, read by the compositor ahead of
/// anything baked into its instructions.
///
/// A layer's transform normally lives in the project and reaches the
/// compositor through the instruction list, which is built once per change.
/// That is fine for a slider and hopeless for a drag: rebuilding the
/// composition re-cuts every track and swaps the player item, so the box moves
/// with your finger and the picture arrives a beat later, jerking as each
/// rebuild lands.
///
/// While a handle is held, the value goes here instead. The compositor checks
/// this first, the player is asked to re-render the frame it is already on,
/// and nothing is rebuilt. On release the value is written to the project once
/// — one undo step, one rebuild.
final class LiveTransformStore {
    static let shared = LiveTransformStore()

    private let lock = NSLock()
    private var values: [UUID: ClipTransform] = [:]
    private var dragging = false

    private init() {}

    /// True while a handle is held. The compositor uses it to leave the
    /// aesthetic treatment out of the frame: a CRT pass or a run of real ntsc
    /// signal processing on every re-render is the difference between the
    /// picture following your finger and trailing it, and the look comes
    /// straight back the moment you let go.
    var isDragging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dragging
    }

    func setDragging(_ value: Bool) {
        lock.lock()
        dragging = value
        lock.unlock()
    }

    func set(_ transform: ClipTransform?, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let transform {
            values[id] = transform
        } else {
            values.removeValue(forKey: id)
        }
    }

    func value(for id: UUID) -> ClipTransform? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values[id]
    }

    func clear() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}
