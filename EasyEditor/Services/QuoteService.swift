import Foundation

/// Client for the desktop server's /quote/* endpoints (the greatBooks
/// corpus queried through nlq.py — natural language via Gemini on the
/// desktop, deterministic filters otherwise).
struct QuoteService {

    struct Author: Decodable, Identifiable, Hashable {
        let name: String
        let count: Int
        let dates: String
        var id: String { name }
    }

    struct Work: Decodable, Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct Quote: Decodable, Identifiable, Hashable {
        let qid: String
        let author: String
        let work: String
        let text: String
        let page: Int?
        let grade: String?
        let hasCrop: Bool
        var id: String { qid }
    }

    private struct AuthorsResponse: Decodable { let authors: [Author] }
    private struct WorksResponse: Decodable { let works: [Work] }
    private struct QuotesResponse: Decodable { let quotes: [Quote] }
    private struct ResultsResponse: Decodable { let results: [Quote] }

    let library: DesktopLibraryService

    /// Sets are forwarded so future corpora can hook in; only Great Books is
    /// live on the server today.
    var sets: String = "greatbooks"

    private func get<T: Decodable>(_ type: T.Type, route: String,
                                   _ items: [URLQueryItem]) async throws -> T {
        var all = items
        all.append(URLQueryItem(name: "sets", value: sets))
        var request = URLRequest(url: library.url(route, all))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DesktopLibraryService.ServiceError.server("Quote server error (\(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func authors(order: String) async throws -> [Author] {
        try await get(AuthorsResponse.self, route: "quote/authors",
                      [URLQueryItem(name: "order", value: order)]).authors
    }

    func works(author: String?) async throws -> [Work] {
        var items: [URLQueryItem] = []
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        return try await get(WorksResponse.self, route: "quote/works", items).works
    }

    func quotes(author: String, work: String) async throws -> [Quote] {
        try await get(QuotesResponse.self, route: "quote/list", [
            URLQueryItem(name: "author", value: author),
            URLQueryItem(name: "work", value: work),
        ]).quotes
    }

    func search(_ query: String) async throws -> [Quote] {
        try await get(ResultsResponse.self, route: "quote/search",
                      [URLQueryItem(name: "q", value: query)]).results
    }

    func deterministic(author: String?, work: String?, topic: String?) async throws -> [Quote] {
        var items: [URLQueryItem] = []
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        if let work, !work.isEmpty { items.append(URLQueryItem(name: "work", value: work)) }
        if let topic, !topic.isEmpty { items.append(URLQueryItem(name: "topic", value: topic)) }
        return try await get(ResultsResponse.self, route: "quote/det", items).results
    }

    func imageURL(qid: String, kind: String) -> URL {
        library.url("quote/image", [
            URLQueryItem(name: "qid", value: qid),
            URLQueryItem(name: "kind", value: kind),
        ])
    }
}

/// Quote browser preferences.
enum QuoteSettings {
    static let orderKey = "quoteAuthorOrder"     // "chrono" | "alpha"
    static let modeKey = "quoteSearchMode"       // "nl" | "advanced"
    static let setsKey = "quoteSets"             // CSV of set slugs

    static let allSets: [(slug: String, name: String, working: Bool)] = [
        ("greatbooks", "Great Books", true),
        ("bible", "Bible", false),
        ("criticaltheory", "Critical Theory", false),
        ("digitaltheory", "Digital Theory", false),
        ("socialtheory", "Social/Cultural Theory", false),
        ("politicaltheory", "Political Theory", false),
    ]
    static let defaultSets = allSets.map(\.slug).joined(separator: ",")
}
