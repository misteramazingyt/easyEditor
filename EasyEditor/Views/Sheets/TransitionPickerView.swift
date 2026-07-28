import SwiftUI

/// Picks the transition between a storyline clip and the next one.
struct TransitionPickerView: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss
    let clipID: UUID

    @State private var style: TransitionStyle = .none
    @State private var duration: Double = 0.5

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 8)
            Text("Transition").font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TransitionStyle.allCases) { candidate in
                        Button {
                            style = candidate
                            apply()
                            Haptics.selection()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: candidate.systemImage)
                                    .font(.title3)
                                    .frame(width: 52, height: 40)
                                    .background(style == candidate ? Color.orange.opacity(0.3) : .white.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(style == candidate ? Color.orange : .clear, lineWidth: 2))
                                Text(candidate.displayName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            if style != .none {
                VStack(spacing: 4) {
                    HStack {
                        Text("Duration").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fs", duration))
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: $duration, in: 0.2...2, step: 0.1) { editing in
                        if !editing { apply() }
                    }
                }
                .padding(.horizontal, 20)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .presentationDragIndicator(.hidden)
        .foregroundStyle(.white)
        .onAppear {
            if let t = editor.project.clip(clipID)?.transitionToNext {
                style = t.style
                duration = t.duration
            }
        }
    }

    private func apply() {
        let transition = style == .none ? nil : Transition(style: style, duration: duration)
        editor.setTransition(afterClipID: clipID, transition)
    }
}
