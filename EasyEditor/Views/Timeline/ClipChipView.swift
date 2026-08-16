import SwiftUI

/// One clip rendered in the timeline: filmstrip for video, thumb for images,
/// purple bar for titles, waveform bars for audio. FCP-style yellow border
/// when selected, with trim handles supplied by the timeline.
struct ClipChipView: View {
    let clip: TimelineClip
    let projectID: UUID
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    /// Only the tapped clip trims — resizing one member of a staggered group
    /// must not resize the others.
    var showsTrimHandles: Bool = true
    let onTrim: (_ edge: TrimEdge, _ deltaPoints: CGFloat, _ ended: Bool) -> Void

    enum TrimEdge { case leading, trailing }

    @State private var filmstrip: [UIImage] = []
    @State private var imageThumb: UIImage?

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: max(10, width), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.15),
                              lineWidth: isSelected ? 2.5 : 1)
        )
        .overlay(alignment: .leading) {
            if isSelected && showsTrimHandles { handle(.leading) }
        }
        .overlay(alignment: .trailing) {
            if isSelected && showsTrimHandles { handle(.trailing) }
        }
        .overlay(alignment: .bottomLeading) { badges }
    }

    // MARK: Pieces

    private var background: some View {
        Group {
            if clip.isLiveRecording == true {
                Color(red: 0.45, green: 0.09, blue: 0.12)
            } else {
                switch clip.kind {
                case .video:
                    Color(red: 0.16, green: 0.2, blue: 0.28)
            case .image:
                Color(red: 0.2, green: 0.24, blue: 0.3)
            case .title:
                Color(red: 0.48, green: 0.3, blue: 0.75) // FCP title purple
            case .music:
                Color(red: 0.12, green: 0.45, blue: 0.25) // FCP music green
            case .voiceover:
                Color(red: 0.13, green: 0.4, blue: 0.5)
                case .sfx:
                    Color(red: 0.35, green: 0.3, blue: 0.5)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if clip.isLiveRecording == true {
            // The file is still being written — draw the take growing instead
            // of asking AVFoundation for thumbnails of an unfinished movie.
            recordingBars
        } else {
            switch clip.kind {
            case .video:
                filmstripView
            case .image:
                if let imageThumb {
                    Image(uiImage: imageThumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(10, width), height: height)
                } else {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .task { await loadImageThumb() }
                }
            case .title:
                Text(clip.text?.string ?? "Title")
                    .font(.system(size: max(7, min(11, height * 0.8))).weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .music, .voiceover, .sfx:
                waveform
            }
        }
    }

    /// Growing take: one bar per ~6pt of recorded time, brightest at the head.
    private var recordingBars: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5
            let gap: CGFloat = 3.5
            var x: CGFloat = 3
            while x < size.width - 2 {
                let headroom = min(1, (size.width - x) / 40)
                let h = size.height * (0.35 + 0.5 * (1 - headroom))
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(.white.opacity(0.85)))
                x += barWidth + gap
            }
        }
    }

    private var filmstripView: some View {
        HStack(spacing: 0) {
            if filmstrip.isEmpty {
                Rectangle().fill(.white.opacity(0.05))
            } else {
                ForEach(Array(filmstrip.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(1, width / CGFloat(max(1, filmstrip.count))),
                               height: height)
                        .clipped()
                }
            }
        }
        .frame(width: max(10, width), height: height)
        .task(id: thumbTaskKey) { await loadFilmstrip() }
    }

    private var waveform: some View {
        Canvas { context, size in
            var seed = UInt64(truncatingIfNeeded: clip.id.hashValue)
            let barWidth: CGFloat = 3
            let gap: CGFloat = 1.5
            var x: CGFloat = 2
            while x < size.width - 2 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r = CGFloat((seed >> 33) % 1000) / 1000
                let h = size.height * (0.25 + 0.65 * r)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(.white.opacity(0.55)))
                x += barWidth + gap
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 3) {
            if clip.speed != 1 {
                Text(TimeFormat.speed(clip.speed))
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            if clip.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 8))
                    .padding(2)
                    .background(.black.opacity(0.6), in: Circle())
            }
            if clip.filter != .none {
                Image(systemName: "camera.filters")
                    .font(.system(size: 8))
                    .padding(2)
                    .background(.black.opacity(0.6), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(2)
        .opacity(height > 24 ? 1 : 0)
    }

    private func handle(_ edge: TrimEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 11, height: max(14, height * 0.85))
            .overlay(
                Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.black)
            )
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onTrim(edge, value.translation.width, false) }
                    .onEnded { value in onTrim(edge, value.translation.width, true) }
            )
    }

    // MARK: Thumbs

    private var thumbTaskKey: String {
        "\(clip.id)-\(Int(width / 40))-\(Int(clip.trimStart * 10))-\(Int(clip.trimEnd * 10))"
    }

    private func loadFilmstrip() async {
        guard let fileName = clip.fileName else { return }
        let url = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        let count = max(1, min(20, Int(width / (height * 0.9))))
        let images = await ThumbnailService.shared.filmstrip(
            url: url, clipID: clip.id,
            trimStart: clip.trimStart, trimEnd: clip.trimEnd,
            count: count, height: height)
        filmstrip = images
    }

    private func loadImageThumb() async {
        guard let fileName = clip.fileName else { return }
        let url = FilePaths.mediaURL(projectID: projectID, fileName: fileName)
        imageThumb = await ThumbnailService.shared.imageThumb(url: url, clipID: clip.id, height: height)
    }
}
