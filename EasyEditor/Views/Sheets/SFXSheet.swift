import SwiftUI
import AVFoundation

/// Built-in synthesized sound effects: preview with a tap, add at the playhead.
struct SFXSheet: View {
    let onAdd: (SFXLibrary.Effect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            List(SFXLibrary.effects) { effect in
                HStack {
                    Button {
                        preview(effect)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: effect.systemImage)
                                .frame(width: 32, height: 32)
                                .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(effect.name).font(.subheadline.weight(.semibold))
                                Text(String(format: "%.1fs", effect.duration))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        onAdd(effect)
                        Haptics.success()
                        dismiss()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.07, green: 0.08, blue: 0.12))
            .navigationTitle("Sound Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func preview(_ effect: SFXLibrary.Effect) {
        guard let url = SFXLibrary.url(for: effect) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
