import SwiftUI

/// Web image search: Google-Images-style masonry results, tap to open a
/// fullscreen viewer with a thumbnail carousel, tap the big image again to
/// drop it on the timeline at the playhead.
struct WebImageSearchSheet: View {
    /// Downloads and imports the image; returns true on success.
    let onPick: (WebImage) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [WebImage] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var viewerIndex: Int?
    @State private var isImporting = false
    @FocusState private var searchFocused: Bool

    private let service = WebImageSearchService()
    private let columnCount = 3

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea()
                VStack(spacing: 10) {
                    searchBar
                    if isSearching {
                        Spacer()
                        ProgressView("Searching…")
                        Spacer()
                    } else if let searchError {
                        Spacer()
                        Text(searchError).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Spacer()
                    } else if results.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("Search the web for images")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else {
                        masonry
                    }
                }
            }
            .navigationTitle("Web Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if let index = viewerIndex, results.indices.contains(index) {
                    viewer(index: index)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search images", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        viewerIndex = nil
        Task {
            do {
                results = try await service.search(trimmed)
                searchError = results.isEmpty ? "No images found." : nil
            } catch {
                results = []
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    // MARK: - Masonry grid (variable heights, Google Images style)

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

    private var masonry: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    LazyVStack(spacing: 6) {
                        ForEach(column, id: \.image.id) { entry in
                            masonryCell(entry.image, index: entry.index)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func masonryCell(_ image: WebImage, index: Int) -> some View {
        Button {
            searchFocused = false
            viewerIndex = index
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

    // MARK: - Fullscreen viewer with carousel

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

                // Swipeable full-size pages; tapping the page imports it.
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
                dismiss()
            }
        }
    }
}
