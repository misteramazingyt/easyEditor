import SwiftUI

/// The keyframe control. Tap to set or clear a key at the playhead; hold to
/// pick the easing for the key you are sitting in.
///
/// Colour is the whole readout: teal means there is a key right here, light
/// orange means you are between two and something is being interpolated, and
/// plain white means this track isn't animating at all.
struct KeyframeLozenge: View {
    let marker: KeyframeMarker
    var easing: EasingCurve = .sine
    var compact = false
    let onTap: () -> Void
    let onEasing: (EasingCurve) -> Void

    @State private var showEasing = false

    private var tint: Color {
        switch marker {
        case .off: return .white.opacity(0.55)
        case .onKey: return Color(red: 0.20, green: 0.85, blue: 0.80)      // teal
        case .between: return Color(red: 1.0, green: 0.72, blue: 0.42)     // light orange
        case .outside: return .white.opacity(0.8)
        }
    }

    private var filled: Bool {
        marker == .onKey || marker == .between
    }

    var body: some View {
        // Not a Button: a button's own tap would race the long press, and the
        // hold is the only way to reach the easing.
        Capsule()
            .fill(filled ? tint : .clear)
            .frame(width: compact ? 18 : 22, height: compact ? 11 : 13)
            .overlay(Capsule().strokeBorder(tint, lineWidth: filled ? 0 : 1.4))
            .contentShape(Capsule().inset(by: -10))
            .onTapGesture { onTap() }
            .onLongPressGesture(minimumDuration: 0.4) {
                guard marker != .off else { return }
                Haptics.selection()
                showEasing = true
            }
        .confirmationDialog("Easing", isPresented: $showEasing, titleVisibility: .visible) {
            ForEach(EasingCurve.allCases) { curve in
                Button {
                    onEasing(curve)
                } label: {
                    Text(curve == easing ? "\(curve.displayName) ✓" : curve.displayName)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How this keyframe leaves for the next one.")
        }
        .animation(.easeInOut(duration: 0.15), value: marker)
    }
}

/// A labelled row with its own lozenge — the shape every animatable control
/// takes in the sheets.
struct KeyedRow<Content: View>: View {
    let title: String
    let marker: KeyframeMarker
    var easing: EasingCurve = .sine
    let onTap: () -> Void
    let onEasing: (EasingCurve) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold)).kerning(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                KeyframeLozenge(marker: marker, easing: easing, compact: true,
                                onTap: onTap, onEasing: onEasing)
            }
            content
        }
    }
}
