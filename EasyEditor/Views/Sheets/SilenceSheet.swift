import SwiftUI

/// Cut the quiet out, leaving the cuts on the timeline.
///
/// The clip is replaced by one piece per stretch worth keeping, each trimmed
/// to its own part of the same file — so the result is an edit you can keep
/// editing, not a flattened render of one.
struct SilenceSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("silenceThreshold") private var threshold = -35.0
    @AppStorage("silenceMinimum") private var minimum = 0.5
    @AppStorage("silencePadding") private var padding = 0.12
    @AppStorage("silenceTrimEdges") private var trimEdges = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("Quieter than", value: $threshold, range: -60 ... -20,
                           format: { String(format: "%.0f dB", $0) })
                    slider("For longer than", value: $minimum, range: 0.15...2,
                           format: { String(format: "%.2f s", $0) })
                    slider("Keep either side", value: $padding, range: 0...0.4,
                           format: { String(format: "%.2f s", $0) })
                } header: {
                    Text("What counts as silence")
                } footer: {
                    Text("A gap has to be quieter than the threshold for longer "
                         + "than the minimum. The padding stays in, so words aren't clipped.")
                }

                Section {
                    Toggle("Trim the ends too", isOn: $trimEdges)
                } footer: {
                    Text("Off, quiet at the very start and end of the clip is left alone.")
                }

                Section {
                    Button {
                        guard let id = editor.selectedClipID else { return }
                        editor.removeSilence(id, settings: SilenceDetector.Settings(
                            minSilence: minimum, thresholdDB: threshold,
                            padding: padding, trimEdges: trimEdges))
                        dismiss()
                    } label: {
                        Label("Cut the silence", systemImage: "waveform.badge.minus")
                    }
                    .disabled(editor.selectedClip?.hasAudio != true || editor.isProcessing)
                } footer: {
                    Text("The clip becomes one piece per stretch of speech. "
                         + "Nothing is re-encoded — trim or move the pieces afterwards.")
                }
            }
            .navigationTitle("Remove silence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
