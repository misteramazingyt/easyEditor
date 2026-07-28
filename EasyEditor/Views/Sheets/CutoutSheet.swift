import SwiftUI

/// Background removal for the selected clip. Video: per-frame person
/// segmentation or white/black keying. Images: subject lifting or keying.
struct CutoutSheet: View {
    @EnvironmentObject private var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    private var options: [CutoutMode] {
        switch editor.selectedClip?.kind {
        case .video: return [.person, .whiteKey, .blackKey]
        case .image: return [.subject, .whiteKey, .blackKey]
        default: return []
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 8)
            Text("Cut Out Background").font(.headline)
            Text(editor.selectedClip?.kind == .video
                 ? "Person tracks you frame-by-frame; keys remove plain backdrops."
                 : "Auto Subject lifts the object; keys remove plain backdrops.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)

            HStack(spacing: 10) {
                cell(nil, name: "None", icon: "circle.slash")
                ForEach(options) { mode in
                    cell(mode, name: mode.rawValue, icon: mode.systemImage)
                }
            }
            .padding(.horizontal, 16)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .presentationDetents([.height(260)])
        .presentationBackground(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func cell(_ mode: CutoutMode?, name: String, icon: String) -> some View {
        let isOn = editor.selectedClip?.cutout == mode
        return Button {
            if let id = editor.selectedClipID {
                editor.mutate(id) { $0.cutout = mode }
                Haptics.selection()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isOn ? Color.blue : .clear, lineWidth: 2))
                Text(name)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
