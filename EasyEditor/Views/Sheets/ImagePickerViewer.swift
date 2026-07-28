import SwiftUI

/// Shared pieces for image-source sheets (web search, desktop library):
/// a masonry results grid and a fullscreen viewer with a thumbnail carousel.
/// Tap the fullscreen image to import it at the playhead.

// MARK: - Masonry grid

struct MasonryGrid: View {
    let results: [WebImage]
    var columnCount = 3
    let onTap: (Int) -> Void

    /// Distribute results across columns, shortest-column-first.
    private var columns: [[(index: Int, image: WebImage)]] {
        var cols: [[(Int, WebImage)]] = Array(repeating: [], count: columnCount)
        var heights = Array(repeating: 0.0, count: columnCount)
        for (index, image) in results.enumerated() {
            let target = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            cols[target].append((index, image))
            heights[target] += 1 / max(0.3, min(3, image.aspect))
        }
        return cols
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    LazyVStack(spacing: 6) {
                        ForEach(column, id: \.image.id) { entry in
                            cell(entry.image, index: entry.index)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func cell(_ image: WebImage, index: Int) -> some View {
        Button {
            onTap(index)
        } label: {
            AsyncImage(url: image.thumbURL) { phase in
                switch phase {
                case .success(let loaded):
                    loaded.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color.white.opacity(0.06)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Color.white.opacity(0.06)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .aspectRatio(max(0.4, min(2.5, image.aspect)), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fullscreen viewer with carousel

struct ImagePickerViewer: View {
    let results: [WebImage]
    @Binding var viewerIndex: Int?
    /// Downloads and imports; returns true on success.
    let onPick: (WebImage) async -> Bool
    /// Called after a successful import (dismiss the hosting sheet).
    let onImported: () -> Void

    @State private var isImporting = false

    var body: some View {
        if let index = viewerIndex, results.indices.contains(index) {
            viewer(index: index)
        }
    }

    private func viewer(index: Int) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        viewerIndex = nil
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                    }
                    Spacer()
                    Text("Tap image to add at playhead")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Spacer().frame(width: 44)
                }

                TabView(selection: Binding(
                    get: { viewerIndex ?? index },
                    set: { viewerIndex = $0 }
                )) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, image in
                        AsyncImage(url: image.fullURL) { phase in
                            switch phase {
                            case .success(let loaded):
                                loaded.resizable().aspectRatio(contentMode: .fit)
                            case .failure:
                                AsyncImage(url: image.thumbURL) { thumbPhase in
                                    if case .success(let thumb) = thumbPhase {
                                        thumb.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "photo").font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            default:
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { importImage(image) }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                carousel(current: index)
            }

            if isImporting {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Adding image…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .foregroundStyle(.white)
    }

    /// Thumbnail strip: tap to jump, drag to fast-scroll through results.
    private func carousel(current: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, image in
                        Button {
                            viewerIndex = i
                        } label: {
                            AsyncImage(url: image.thumbURL) { phase in
                                if case .success(let loaded) = phase {
                                    loaded.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.white.opacity(0.08)
                                }
                            }
                            .frame(width: i == current ? 46 : 34, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(i == current ? Color.white : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: current) { _, newValue in
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(current, anchor: .center)
            }
        }
        .frame(height: 68)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09))
    }

    private func importImage(_ image: WebImage) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            let success = await onPick(image)
            isImporting = false
            if success {
                Haptics.success()
                onImported()
            }
        }
    }
}
