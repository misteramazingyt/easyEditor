import SwiftUI

/// Your desktop picture library over Tailscale: semantic Search tab (CLIP,
/// via the ported semanticSearch backend) and a Browse tab walking the real
/// folder tree. Same viewer/import flow as web search.
struct DesktopLibrarySheet: View {
    let onPick: (WebImage) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DesktopLibrarySettings.urlKey) private var serverURL = ""
    @AppStorage(DesktopLibrarySettings.tokenKey) private var serverToken = ""

    private enum Tab: String, CaseIterable { case search = "Search", browse = "Browse" }
    @State private var tab: Tab = .search

    // Search state
    @State private var query = ""
    @State private var searchResults: [WebImage] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool

    // Browse state
    @State private var pathStack: [String] = []   // absolute server paths; empty = root
    @State private var folders: [String] = []
    @State private var browseResults: [WebImage] = []
    @State private var isBrowsing = false
    @State private var browseError: String?

    @State private var viewerIndex: Int?
    @State private var showSettings = false

    private var service: DesktopLibraryService? {
        DesktopLibraryService(urlString: serverURL, token: serverToken)
    }

    private var activeResults: [WebImage] {
        tab == .search ? searchResults : browseResults
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea()
                if service == nil {
                    unconfigured
                } else {
                    content
                }
            }
            .navigationTitle("Desktop Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .overlay {
                ImagePickerViewer(results: activeResults,
                                  viewerIndex: $viewerIndex,
                                  onPick: onPick,
                                  onImported: { dismiss() })
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task(id: serverURL) {
            if service != nil, browseResults.isEmpty, folders.isEmpty {
                await loadBrowse(path: nil)
            }
        }
    }

    // MARK: - Unconfigured

    private var unconfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No desktop server configured")
                .font(.headline)
            Text("Run desktop-server/server.py on your desktop and enter its Tailscale URL in Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            switch tab {
            case .search: searchTab
            case .browse: browseTab
            }
        }
    }

    // MARK: Search tab

    private var searchTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField("Semantic search (\"golden hour portrait\")", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { runSearch() }
            }
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)

            if isSearching {
                Spacer(); ProgressView("Searching…"); Spacer()
            } else if let searchError {
                Spacer()
                Text(searchError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                Text("Search your library by meaning, not filename")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            } else {
                MasonryGrid(results: searchResults) { index in
                    searchFocused = false
                    viewerIndex = index
                }
            }
        }
    }

    private func runSearch() {
        guard let service else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        viewerIndex = nil
        Task {
            do {
                searchResults = try await service.search(trimmed)
                searchError = searchResults.isEmpty ? "No matches in your library." : nil
            } catch {
                searchResults = []
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    // MARK: Browse tab

    private var browseTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    var stack = pathStack
                    if !stack.isEmpty { stack.removeLast() }
                    pathStack = stack
                    Task { await loadBrowse(path: stack.last) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(pathStack.isEmpty)
                .opacity(pathStack.isEmpty ? 0.4 : 1)

                Text(currentFolderName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if isBrowsing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)

            if let browseError {
                Spacer()
                Text(browseError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Retry") { Task { await loadBrowse(path: pathStack.last) } }
                    .buttonStyle(.bordered)
                Spacer()
            } else {
                ScrollView {
                    if !folders.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                                  spacing: 8) {
                            ForEach(folders, id: \.self) { folder in
                                folderCell(folder)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    MasonryGrid(results: browseResults) { index in
                        viewerIndex = index
                    }
                }
            }
        }
    }

    private var currentFolderName: String {
        guard let last = pathStack.last else { return "Library" }
        return last.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? "Library"
    }

    private func folderCell(_ folder: String) -> some View {
        Button {
            let base = pathStack.last
            let newPath = base != nil ? joinPath(base!, folder) : folder
            pathStack.append(newPath)
            Task { await loadBrowse(path: newPath) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(folder).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// First navigation level sends a relative name; the server responds with
    /// absolute paths which we use from then on.
    private func joinPath(_ base: String, _ name: String) -> String {
        base.contains("\\") ? base + "\\" + name : base + "/" + name
    }

    private func loadBrowse(path: String?) async {
        guard let service else { return }
        isBrowsing = true
        browseError = nil
        viewerIndex = nil
        do {
            let result = try await service.browse(path: path)
            folders = result.folders
            browseResults = service.browseImages(result)
            // Adopt the server's canonical absolute path for this level.
            if path != nil, !pathStack.isEmpty {
                pathStack[pathStack.count - 1] = result.path
            }
        } catch {
            browseError = error.localizedDescription
            folders = []
            browseResults = []
        }
        isBrowsing = false
    }
}
