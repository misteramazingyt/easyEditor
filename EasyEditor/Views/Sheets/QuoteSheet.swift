import SwiftUI

/// Quote browser: natural-language search over the greatBooks corpus (Gemini
/// on the desktop server), author → work → quote drilldown, deterministic
/// advanced mode, and card/crop insertion at the playhead.
struct QuoteSheet: View {
    /// Downloads the image and places it at the playhead; true on success.
    let onInsert: (URL, OverlayPlacement) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DesktopLibrarySettings.urlKey) private var serverURL = ""
    @AppStorage(DesktopLibrarySettings.tokenKey) private var serverToken = ""
    @AppStorage(QuoteSettings.orderKey) private var authorOrder = "chrono"
    @AppStorage(QuoteSettings.modeKey) private var searchMode = "nl"
    @AppStorage(QuoteSettings.setsKey) private var setsCSV = QuoteSettings.defaultSets

    @State private var authors: [QuoteService.Author] = []
    @State private var authorsError: String?
    @State private var query = ""
    @State private var results: [QuoteService.Quote]?
    @State private var isSearching = false
    @State private var searchError: String?
    // Advanced (deterministic) filters — shared with the settings page.
    @State private var advAuthor: String?
    @State private var advWork: String?
    @State private var advTopic = ""

    @State private var selected: QuoteService.Quote?
    @State private var isInserting = false
    @FocusState private var searchFocused: Bool

    private var service: QuoteService? {
        guard let library = DesktopLibraryService(urlString: serverURL, token: serverToken) else {
            return nil
        }
        return QuoteService(library: library, sets: setsCSV)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
                if let service {
                    content(service)
                } else {
                    unconfigured
                }
            }
            .navigationTitle("QUOTE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: QuoteService.Author.self) { author in
                QuoteWorksView(service: service, author: author, selected: $selected)
            }
            .navigationDestination(for: WorkRoute.self) { route in
                QuoteWorkQuotesView(service: service, route: route, selected: $selected)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if selected != nil { insertBar }
        }
        .task(id: "\(authorOrder)|\(setsCSV)|\(serverURL)") {
            await loadAuthors()
        }
        .onChange(of: searchMode) { _, _ in
            results = nil
            selected = nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ service: QuoteService) -> some View {
        VStack(spacing: 10) {
            if searchMode == "nl" {
                nlSearchBar
                HStack {
                    chip("Natural Language", systemImage: "bubble.left.and.text.bubble.right")
                    Spacer()
                }
                .padding(.horizontal, 14)
            } else {
                advancedFields
            }

            if isSearching {
                Spacer(); ProgressView("Searching…"); Spacer()
            } else if let searchError {
                Spacer()
                Text(searchError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            } else if let results {
                sectionHeader("\(results.count) results")
                QuoteResultsList(quotes: results, selected: $selected)
            } else {
                authorsList
            }
        }
    }

    private var unconfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No desktop server configured").font(.headline)
            Text("Quotes are served by desktop-server (run it with --quotes). Set the server URL in Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
        }
    }

    // MARK: - NL search

    private var nlSearchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search quotations in natural language", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { runNLSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = nil
                        selected = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(11)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            settingsLink
        }
        .padding(.horizontal, 14)
    }

    private var settingsLink: some View {
        NavigationLink {
            QuoteSettingsView(advAuthor: $advAuthor, advWork: $advWork,
                              advTopic: $advTopic, service: service)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue.opacity(0.6), lineWidth: 1.2))
        }
    }

    private func runNLSearch() {
        guard let service else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        selected = nil
        Task {
            do {
                results = try await service.search(trimmed)
                searchError = results?.isEmpty == true ? "No matches — try rephrasing." : nil
                if results?.isEmpty == true { results = nil }
            } catch {
                results = nil
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    // MARK: - Advanced (deterministic)

    private var advancedFields: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(spacing: 1) {
                    advancedRow("Author", value: advAuthor ?? "Any")
                    advancedRow("Work", value: advWork ?? "Any")
                    advancedRow("Topic", value: advTopic.isEmpty ? "Any" : advTopic)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                settingsLink
            }
            HStack {
                chip("Deterministic", systemImage: "checklist")
                Spacer()
                Button {
                    runDeterministic()
                } label: {
                    Text("Search")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(advAuthor == nil && advWork == nil && advTopic.isEmpty)
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 14)
    }

    private func advancedRow(_ label: String, value: String) -> some View {
        NavigationLink {
            QuoteSettingsView(advAuthor: $advAuthor, advWork: $advWork,
                              advTopic: $advTopic, service: service)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold)).kerning(1)
                        .foregroundStyle(.secondary)
                    Text(value).font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.05))
        }
        .buttonStyle(.plain)
    }

    private func runDeterministic() {
        guard let service else { return }
        isSearching = true
        searchError = nil
        selected = nil
        Task {
            do {
                results = try await service.deterministic(author: advAuthor,
                                                          work: advWork,
                                                          topic: advTopic)
                searchError = results?.isEmpty == true ? "No matches for those filters." : nil
                if results?.isEmpty == true { results = nil }
            } catch {
                results = nil
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    // MARK: - Authors

    private var authorsList: some View {
        VStack(spacing: 6) {
            HStack {
                sectionHeader("Authors")
                Spacer()
                Button {
                    authorOrder = authorOrder == "chrono" ? "alpha" : "chrono"
                } label: {
                    Text(authorOrder == "chrono" ? "Chronological" : "Alphabetical")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Color.blue, lineWidth: 1))
                        .foregroundStyle(.blue)
                }
                .padding(.trailing, 14)
            }
            if let authorsError {
                Spacer()
                Text(authorsError).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Retry") { Task { await loadAuthors() } }
                    .buttonStyle(.bordered)
                Spacer()
            } else if authors.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(authors) { author in
                            NavigationLink(value: author) {
                                HStack {
                                    Text(author.name).font(.title3)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(author.dates)
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 13)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(.white.opacity(0.06)).padding(.leading, 16)
                        }
                    }
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 90)
                }
            }
        }
    }

    private func loadAuthors() async {
        guard let service else { return }
        authorsError = nil
        do {
            authors = try await service.authors(order: authorOrder)
            if authors.isEmpty {
                authorsError = "No authors — check that Great Books is enabled in the quote settings."
            }
        } catch {
            authors = []
            authorsError = error.localizedDescription
        }
    }

    // MARK: - Insert bar

    private var insertBar: some View {
        VStack(spacing: 10) {
            Text("INSERT AT PLAYHEAD")
                .font(.system(size: 10, weight: .semibold)).kerning(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                insertButton("Card", subtitle: "Full quote as designed card",
                             systemImage: "menucard", kind: "card",
                             enabled: true,
                             placement: OverlayPlacement(centerX: 0.5, centerY: 0.5,
                                                         widthFraction: 0.95))
                insertButton("Crop", subtitle: selected?.hasCrop == true
                                ? "Cropped scan of the passage" : "Card only",
                             systemImage: "crop", kind: "crop",
                             enabled: selected?.hasCrop == true,
                             placement: OverlayPlacement(centerX: 0.5, centerY: 0.5,
                                                         widthFraction: 0.85))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .overlay(alignment: .center) {
            if isInserting {
                ProgressView().padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func insertButton(_ title: String, subtitle: String, systemImage: String,
                              kind: String, enabled: Bool,
                              placement: OverlayPlacement) -> some View {
        Button {
            guard let service, let quote = selected, !isInserting else { return }
            isInserting = true
            Task {
                let ok = await onInsert(service.imageURL(qid: quote.qid, kind: kind), placement)
                isInserting = false
                if ok { dismiss() }
            }
        } label: {
            VStack(spacing: 4) {
                Label(title.uppercased(), systemImage: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(enabled ? .blue : .secondary)
                Text(subtitle)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(enabled ? Color.blue.opacity(0.7) : .white.opacity(0.1),
                              lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Bits

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).kerning(1.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.blue.opacity(0.7), lineWidth: 1))
            .foregroundStyle(.blue)
    }
}

// MARK: - Drilldown routes & views

struct WorkRoute: Hashable {
    let author: String
    let work: String
}

struct QuoteWorksView: View {
    let service: QuoteService?
    let author: QuoteService.Author
    @Binding var selected: QuoteService.Quote?
    @State private var works: [QuoteService.Work] = []
    @State private var error: String?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(works) { work in
                        NavigationLink(value: WorkRoute(author: author.name, work: work.name)) {
                            HStack {
                                Text(work.name).font(.headline).foregroundStyle(.white)
                                Spacer()
                                Text("\(work.count)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(.white.opacity(0.06)).padding(.leading, 16)
                    }
                }
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .padding(12)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(author.name)
        .task {
            do {
                works = try await service?.works(author: author.name) ?? []
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct QuoteWorkQuotesView: View {
    let service: QuoteService?
    let route: WorkRoute
    @Binding var selected: QuoteService.Quote?
    @State private var quotes: [QuoteService.Quote] = []
    @State private var error: String?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                QuoteResultsList(quotes: quotes, selected: $selected)
            }
        }
        .navigationTitle(route.work)
        .task {
            do {
                quotes = try await service?.quotes(author: route.author, work: route.work) ?? []
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Shared results list

struct QuoteResultsList: View {
    let quotes: [QuoteService.Quote]
    @Binding var selected: QuoteService.Quote?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(quotes) { quote in
                    row(quote)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 130)
        }
    }

    private func row(_ quote: QuoteService.Quote) -> some View {
        let isSelected = selected?.qid == quote.qid
        return Button {
            selected = isSelected ? nil : quote
            Haptics.selection()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "quote.opening")
                    .font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 7) {
                    Text(quote.text)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    HStack(spacing: 6) {
                        Text(quote.author.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text("·").foregroundStyle(.secondary)
                        Text(quote.work).font(.system(size: 12))
                            .foregroundStyle(.secondary).lineLimit(1)
                        if let page = quote.page {
                            Text("·").foregroundStyle(.secondary)
                            Text("p.\(page)").font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(quote.hasCrop ? "Crop available" : "Card only")
                            .font(.system(size: 11))
                            .foregroundStyle(quote.hasCrop ? .blue : .secondary)
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
}
