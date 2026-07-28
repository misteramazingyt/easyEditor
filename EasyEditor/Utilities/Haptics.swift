import UIKit

/// Central haptic vocabulary for the timeline. Generators are kept alive and
/// re-prepared so feedback lands with minimal latency during drags.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notify = UINotificationFeedbackGenerator()

    static func prepare() {
        light.prepare(); medium.prepare(); rigid.prepare(); selectionGen.prepare()
    }

    /// A clip crossed from one timeline layer into another while dragging.
    static func laneChange() { medium.impactOccurred(); medium.prepare() }

    /// Magnetic snap: reorder index changed / snapped to playhead or an edge.
    static func snap() { light.impactOccurred(intensity: 0.7); light.prepare() }

    /// Clip dropped into its new home.
    static func drop() { rigid.impactOccurred(); rigid.prepare() }

    static func selection() { selectionGen.selectionChanged(); selectionGen.prepare() }

    static func success() { notify.notificationOccurred(.success) }
    static func warning() { notify.notificationOccurred(.warning) }
}
