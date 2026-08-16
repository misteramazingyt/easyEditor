import Foundation

/// Client for the desktop server's /myquotes/* endpoints — the misteramazing
/// `_quotes` card collection. Each quote may exist in several card styles;
/// the server picks one at random per search, and the app can re-roll locally
/// from the returned list.
struct MyQuotesService {

    struct Section: Decodable, Identifiable, Hashable {
        let slug: String
        let name: String
        let count: Int
        var id: String { slug }
    }

    struct Quote: Decodable, Identifiable, Hashable {
        let qid: String
        let text: String
        let gloss: String
        let work: String
        let section: String
        let sectionName: String
        let colour: String
        let shortlink: String
        let styles: [String]
        var style: String?

        var id: String { qid }
        var hasChoiceOfStyles: Bool { styles.count > 1 }
    }

    private struct SectionsResponse: Decodable { let sections: [Section] }
    private struct ResultsResponse: Decodable { let results: [Quote] }

    let library: DesktopLibraryService

    private func get<T: Decodable>(_ type: T.Type, route: String,
                                   _ items: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: library.url(route, items))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DesktopLibraryService.ServiceError.server(
                "My Quotes server error (\(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func sections() async throws -> [Section] {
        try await get(SectionsResponse.self, route: "myquotes/sections").sections
    }

    /// Every call re-rolls the style shown for each quote.
    func search(_ query: String, section: String?) async throws -> [Quote] {
        var items = [URLQueryItem(name: "q", value: query)]
        if let section, !section.isEmpty {
            items.append(URLQueryItem(name: "section", value: section))
        }
        return try await get(ResultsResponse.self, route: "myquotes/search", items).results
    }

    func imageURL(qid: String, style: String?) -> URL {
        var items = [URLQueryItem(name: "qid", value: qid)]
        if let style, !style.isEmpty {
            items.append(URLQueryItem(name: "style", value: style))
        }
        return library.url("myquotes/image", items)
    }
}
