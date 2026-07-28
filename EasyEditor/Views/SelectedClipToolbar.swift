import SwiftUI

/// Which tool sheet is open for the selected clip.
enum ClipTool: String, Identifiable {
    case speed, volume, filters, adjust, opacity, more
    var id: String { rawValue }
}

/// TikTok-style contextual bottom bar: when a clip is selected the main tool
/// row is replaced by a horizontally scrollable strip of clip actions.
struct SelectedClipToolbar: View {
    @EnvironmentObject private var editor: EditorState
    @Binding var activeTool: ClipTool?
    @Binding var transitionAfterClipID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                editor.selectedClipID = nil
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 58)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.leading, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let clip = editor.selectedClip {
                        tiles(for: clip)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
    }

    @ViewBuilder
    private func tiles(for clip: TimelineClip) -> some View {
        tile("Split", "square.split.2x1") { editor.splitClip(clip.id) }

        if clip.kind == .video {
            tile("Speed", "gauge.with.needle") { activeTool = .speed }
        }
        if clip.hasAudio {
            tile("Volume", "speaker.wave.2") { activeTool = .volume }
        }
        if clip.kind == .video {
            tile("Filters", "camera.filters") { activeTool = .filters }
            tile("Adjust", "slider.horizontal.3") { activeTool = .adjust }
            tile("Rotate", "rotate.right") {
                editor.mutate(clip.id) { $0.rotationQuarterTurns += 1 }
                editor.showToast("Rotated")
            }
            tile("Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                editor.mutate(clip.id) { $0.isFlippedH.toggle() }
                editor.showToast(clip.isFlippedH ? "Unflipped" : "Flipped")
            }
            tile("Opacity", "circle.righthalf.filled") { activeTool = .opacity }
            if clip.lane == .primary {
                tile("Transition", "square.on.square.dashed") {
                    transitionAfterClipID = clip.id
                }
            }
        }
        tile("Duplicate", "plus.square.on.square") {
            editor.duplicateClip(clip.id)
            editor.showToast("Duplicated")
        }
        tile("More", "ellipsis") { activeTool = .more }
        tile("Delete", "trash", tint: .red) { editor.deleteClip(clip.id) }
    }

    private func tile(_ label: String, _ systemImage: String,
                      tint: Color = .white,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(width: 62, height: 58)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
