import SwiftUI

/// Bottom tool row, TikTok style: each tool is a single dark rounded square
/// with the icon and its label inside it.
struct ToolbarView: View {
    let onMedia: () -> Void
    let onMusic: () -> Void
    let onTitle: () -> Void
    let onSFX: () -> Void
    let onVoice: () -> Void
    let onText: () -> Void
    let onCaptions: () -> Void
    let onAutoBRoll: () -> Void
    let onOutro: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tile("Media", systemImage: "play.rectangle", action: onMedia)
                tile("Music", systemImage: "music.note", action: onMusic)
                tile("Title", systemImage: "textformat.alt", action: onTitle)
                tile("SFX", systemImage: "waveform", action: onSFX)
                tile("Voice", systemImage: "mic", action: onVoice)
                tile("Text", systemImage: "textformat", action: onText)
                tile("Captions", systemImage: "captions.bubble", action: onCaptions)
                tile("B-Roll", systemImage: "wand.and.stars", action: onAutoBRoll)
                tile("Outro", systemImage: "flag.checkered", action: onOutro)
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
    }

    private func tile(_ label: String, systemImage: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 58)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
