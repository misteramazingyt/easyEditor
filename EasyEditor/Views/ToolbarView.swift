import SwiftUI
import PhotosUI

/// Bottom tool row, styled after the reference: blue tiles labeled
/// Media · Music · Title · SFX · Voice · Text.
struct ToolbarView: View {
    @Binding var pickedMedia: [PhotosPickerItem]
    let onMusic: () -> Void
    let onTitle: () -> Void
    let onSFX: () -> Void
    let onVoice: () -> Void
    let onText: () -> Void

    private let tileColor = Color(red: 0.2, green: 0.65, blue: 0.93)

    var body: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickedMedia,
                         maxSelectionCount: 20,
                         matching: .any(of: [.videos, .images])) {
                tile("Media", systemImage: "play.rectangle")
            }
            button("Music", systemImage: "music.note", action: onMusic)
            button("Title", systemImage: "textformat.alt", action: onTitle)
            button("SFX", systemImage: "waveform", action: onSFX)
            button("Voice", systemImage: "mic", action: onVoice)
            button("Text", systemImage: "textformat", action: onText)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tile(label, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ label: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tileColor)
                .frame(width: 46, height: 34)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 15)
                .background(tileColor, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
