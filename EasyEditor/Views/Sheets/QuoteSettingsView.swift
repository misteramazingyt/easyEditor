import SwiftUI

/// The quote browser's cog page: sets, author ordering, search mode, and the
/// advanced deterministic filters (author / work / topic pickers).
struct QuoteSettingsView: View {
    @Binding var advAuthor: String?
    @Binding var advWork: String?
    @Binding var advTopic: String
    let service: QuoteService?

    @AppStorage(QuoteSettings.orderKey) private var authorOrder = "chrono"
    @AppStorage(QuoteSettings.modeKey) private var searchMode = "nl"
    @AppStorage(QuoteSettings.setsKey) private var setsCSV = QuoteSettings.defaultSets

    private var enabledSets: Set<String> {
        Set(setsCSV.split(separator: ",").map(String.init))
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    setsSection
                    orderSection
                    modeSection
                    filtersSection
                }
                .padding(16)
            }
        }
        .navigationTitle("QUOTE SETTINGS")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sets

    private var setsSection: some View {
        VStack(spacing: 8) {
            header("Sets")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(QuoteSettings.allSets, id: \.slug) { set in
                    setTile(set)
                }
            }
        }
    }

    private func setTile(_ set: (slug: String, name: String, working: Bool)) -> some View {
        let isOn = enabledSets.contains(set.slug)
        return Button {
            var sets = enabledSets
            if isOn { sets.remove(set.slug) } else { sets.insert(set.slug) }
            setsCSV = QuoteSettings.allSets.map(\.slug).filter { sets.contains($0) }
                .joined(separator: ",")
            Haptics.selection()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(set.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !set.working {
                        Text("coming soon")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isOn ? Color.blue.opacity(0.6) : .white.opacity(0.1),
                              lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Order & mode

    private var orderSection: some View {
        VStack(spacing: 8) {
            header("Author Order")
            Picker("Order", selection: $authorOrder) {
                Text("Chronological").tag("chrono")
                Text("Alphabetical").tag("alpha")
            }
            .pickerStyle(.segmented)
        }
    }

    private var modeSection: some View {
        VStack(spacing: 8) {
            header("Search Mode")
            Picker("Mode", selection: $searchMode) {
                Text("Natural Language").tag("nl")
                Text("Advanced (Deterministic)").tag("advanced")
            }
            .pickerStyle(.segmented)
            Text(searchMode == "nl"
                 ? "Uses Gemini interpretation of your query."
                 : "Looks up the database directly with the filters below.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Advanced filters

    private var filtersSection: some View {
        VStack(spacing: 8) {
            header("Advanced Filters")
            VStack(spacing: 1) {
                NavigationLink {
                    QuoteAuthorPicker(service: service, selection: $advAuthor,
                                      onChanged: { advWork = nil })
                } label: {
                    filterRow("Author", icon: "person", value: advAuthor ?? "Any")
                }
                NavigationLink {
                    QuoteWorkPicker(service: service, author: advAuthor, selection: $advWork)
                } label: {
                    filterRow("Work", icon: "book", value: advWork ?? "Any")
                }
                NavigationLink {
                    QuoteTopicEntry(topic: $advTopic)
                } label: {
                    filterRow("Topic", icon: "tag",
                              value: advTopic.isEmpty ? "Any" : advTopic)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func filterRow(_ label: String, icon: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24)
                .foregroundStyle(.white)
            Text(label).font(.headline).foregroundStyle(.white)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(.white.opacity(0.045))
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).kerning(1.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pickers

/// Scrollable, type-to-narrow author list.
struct QuoteAuthorPicker: View {
    let service: QuoteService?
    @Binding var selection: String?
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var authors: [QuoteService.Author] = []
    @State private var filter = ""

    private var filtered: [QuoteService.Author] {
        guard !filter.isEmpty else { return authors }
        return authors.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        pickerList(items: ["Any"] + filtered.map(\.name),
                   current: selection ?? "Any",
                   filter: $filter, placeholder: "Filter authors") { picked in
            let newValue = picked == "Any" ? nil : picked
            if newValue != selection { onChanged() }
            selection = newValue
            dismiss()
        }
        .navigationTitle("Author")
        .task {
            authors = (try? await service?.authors(order: "alpha")) ?? []
        }
    }
}

/// Works for the picked author (or the whole corpus when author is Any).
struct QuoteWorkPicker: View {
    let service: QuoteService?
    let author: String?
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var works: [QuoteService.Work] = []
    @State private var filter = ""

    private var filtered: [QuoteService.Work] {
        guard !filter.isEmpty else { return works }
        return works.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        pickerList(items: ["Any"] + filtered.map(\.name),
                   current: selection ?? "Any",
                   filter: $filter, placeholder: "Filter works") { picked in
            selection = picked == "Any" ? nil : picked
            dismiss()
        }
        .navigationTitle("Work")
        .task {
            works = (try? await service?.works(author: author)) ?? []
        }
    }
}

struct QuoteTopicEntry: View {
    @Binding var topic: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 14) {
                TextField("e.g. justice, ambition, love…", text: $topic)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { dismiss() }
                    .padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Text("Matched against the quote text (full-text search).")
                    .font(.caption).foregroundStyle(.secondary)
                if !topic.isEmpty {
                    Button("Clear") { topic = "" }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(16)
        }
        .navigationTitle("Topic")
        .onAppear { focused = true }
    }
}

/// Shared searchable single-select list used by the pickers.
@ViewBuilder
private func pickerList(items: [String], current: String,
                        filter: Binding<String>, placeholder: String,
                        onPick: @escaping (String) -> Void) -> some View {
    ZStack {
        Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: filter)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            onPick(item)
                        } label: {
                            HStack {
                                Text(item).foregroundStyle(.white)
                                Spacer()
                                if item == current {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(.white.opacity(0.06)).padding(.leading, 16)
                    }
                }
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
    }
}
