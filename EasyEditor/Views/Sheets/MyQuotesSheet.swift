import SwiftUI

/// My Quotes: semantic search over the misteramazing card collection, with a
/// preview of the card and a randomized style per search.
struct MyQuotesSheet: View {
    /// Downloads the card and places it at the playhead; true on success.
    let onInsert: (URL, OverlayPlacement) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DesktopLibrarySettings.urlKey) private var serverURL = ""
    @AppStorage(DesktopLibrarySettings.tokenKey) private var serverToken = ""

    @State private var query = ""
    @State private var sections: [MyQuotesService.Section] = []
    @State private var activeSection: String?
    @State private var results: [MyQuotesService.Quote] = []
    @State private var selected: MyQuotesService.Quote?
    @State private var isSearching = false
    @State private var loadError: String?
    @State private var isInserting = false
    @FocusState private var searchFocused: Bool

    private var service: MyQuotesService? {
        guard let library = DesktopLibraryService(urlString: serverURL, token: serverToken) else {
            return nil
        }
        return MyQuotesService(library: library)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
                if service == nil {
                    unconfigured
                } else {
                    content
                }
            }
            .navigationTitle("MY QUOTES")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if selected != nil { insertBar }
        }
        .task(id: serverURL) {
            sections = (try? await service?.sections()) ?? []
            await runSearch()
        }
    }

    private var unconfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No desktop server configured").font(.headline)
            Text("My Quotes is served by desktop-server. Set the server URL in Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            searchBar
            sectionChips
            if isSearching {
                Spacer(); ProgressView(); Spacer()
            } else if let loadError {
                Spacer()
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                Text("No matching cards.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            } else {
                resultsList
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your quote cards", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await runSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
    }

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: activeSection == nil) {
                    activeSection = nil
                    Task { await runSearch() }
                }
                ForEach(sections) { section in
                    chip(title: "\(section.name) \(section.count)",
                         isOn: activeSection == section.slug) {
                        activeSection = activeSection == section.slug ? nil : section.slug
                        Task { await runSearch() }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(isOn ? Color.blue.opacity(0.35) : .white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.blue : .clear, lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(results) { quote in
                    row(quote)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, selected == nil ? 16 : 150)
        }
    }

    private func row(_ quote: MyQuotesService.Quote) -> some View {
        let isSelected = selected?.qid == quote.qid
        return Button {
            selected = isSelected ? nil : quote
            Haptics.selection()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.fromHex(quote.colour, fallback: .blue))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 7) {
                    Text(quote.text)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    HStack(spacing: 6) {
                        Text(quote.sectionName.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.fromHex(quote.colour, fallback: .blue))
                        if !quote.work.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                            Text(quote.work).font(.system(size: 11))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let style = quote.style, quote.hasChoiceOfStyles {
                            Text(style)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(.blue)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.blue : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Insert

    private var insertBar: some View {
        VStack(spacing: 10) {
            if let service, let quote = selected {
                AsyncImage(url: service.imageURL(qid: quote.qid, style: quote.style)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Button {
                    insert()
                } label: {
                    Label("INSERT AT PLAYHEAD", systemImage: "text.insert")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.blue.opacity(0.7), lineWidth: 1.2))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                if selected?.hasChoiceOfStyles == true {
                    Button {
                        shuffleStyle()
                    } label: {
                        Label("STYLE", systemImage: "shuffle")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1.2))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .overlay {
            if isInserting {
                ProgressView().padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func insert() {
        guard let service, let quote = selected, !isInserting else { return }
        isInserting = true
        Task {
            let ok = await onInsert(
                service.imageURL(qid: quote.qid, style: quote.style),
                OverlayPlacement(centerX: 0.5, centerY: 0.5, widthFraction: 0.9))
            isInserting = false
            if ok { dismiss() }
        }
    }

    /// Re-roll this card's style without re-running the search.
    private func shuffleStyle() {
        guard var quote = selected, quote.styles.count > 1 else { return }
        let others = quote.styles.filter { $0 != quote.style }
        quote.style = others.randomElement() ?? quote.style
        selected = quote
        if let index = results.firstIndex(where: { $0.qid == quote.qid }) {
            results[index] = quote
        }
        Haptics.selection()
    }

    private func runSearch() async {
        guard let service else { return }
        isSearching = true
        loadError = nil
        selected = nil
        do {
            results = try await service.search(query, section: activeSection)
        } catch {
            results = []
            loadError = error.localizedDescription
        }
        isSearching = false
    }
}
