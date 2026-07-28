import SwiftUI

/// Web image search: Google-Images-style masonry results, tap to open the
/// shared fullscreen viewer, tap the big image again to drop it on the
/// timeline at the playhead.
struct WebImageSearchSheet: View {
    /// Downloads and imports the image; returns true on success.
    let onPick: (WebImage) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [WebImage] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var viewerIndex: Int?
    @FocusState private var searchFocused: Bool

    private let service = WebImageSearchService()

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
                        MasonryGrid(results: results) { index in
                            searchFocused = false
                            viewerIndex = index
                        }
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
                ImagePickerViewer(results: results,
                                  viewerIndex: $viewerIndex,
                                  onPick: onPick,
                                  onImported: { dismiss() })
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
    }

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
}
