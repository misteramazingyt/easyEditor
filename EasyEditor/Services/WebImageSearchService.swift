import Foundation

struct WebImage: Identifiable, Equatable {
    let id: String
    let thumbURL: URL
    let fullURL: URL
    let width: Double
    let height: Double
    let title: String

    var aspect: Double { height > 0 ? width / height : 1 }
}

/// Web image search with two providers: DuckDuckGo Images (scraped token
/// endpoint — best results, occasionally breaks) with Openverse as the
/// keyless fallback.
struct WebImageSearchService {

    enum SearchError: LocalizedError {
        case noResults
        var errorDescription: String? { "No images found — try a different search." }
    }

    func search(_ query: String) async throws -> [WebImage] {
        if let ddg = try? await searchDuckDuckGo(query), !ddg.isEmpty {
            return ddg
        }
        let openverse = try await searchOpenverse(query)
        guard !openverse.isEmpty else { throw SearchError.noResults }
        return openverse
    }

    // MARK: - DuckDuckGo

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private func searchDuckDuckGo(_ query: String) async throws -> [WebImage] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // 1. Fetch the token (vqd) DuckDuckGo requires for its image endpoint.
        var tokenRequest = URLRequest(url: URL(string: "https://duckduckgo.com/?q=\(encoded)&iax=images&ia=images")!)
        tokenRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
        let html = String(data: tokenData, encoding: .utf8) ?? ""
        guard let vqd = Self.firstMatch(in: html, patterns: [
            "vqd=\"([\\d-]+)\"", "vqd='([\\d-]+)'", "vqd=([\\d-]+)&",
        ]) else {
            Log.importer.info("DuckDuckGo vqd token not found; falling back")
            return []
        }

        // 2. Query the JSON image endpoint.
        var request = URLRequest(url: URL(string:
            "https://duckduckgo.com/i.js?l=us-en&o=json&q=\(encoded)&vqd=\(vqd)&p=1")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct DDGResponse: Decodable {
            struct Result: Decodable {
                let image: String
                let thumbnail: String
                let width: Double?
                let height: Double?
                let title: String?
            }
            let results: [Result]
        }
        let decoded = try JSONDecoder().decode(DDGResponse.self, from: data)
        return decoded.results.compactMap { result in
            guard let full = URL(string: result.image), full.scheme == "https",
                  let thumb = URL(string: result.thumbnail), thumb.scheme == "https" else {
                return nil
            }
            return WebImage(id: result.image,
                            thumbURL: thumb, fullURL: full,
                            width: result.width ?? 1, height: result.height ?? 1,
                            title: result.title ?? "")
        }
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    // MARK: - Openverse (keyless fallback)

    private func searchOpenverse(_ query: String) async throws -> [WebImage] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var request = URLRequest(url: URL(string:
            "https://api.openverse.org/v1/images/?q=\(encoded)&page_size=40")!)
        request.setValue("EasyEditor/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct OpenverseResponse: Decodable {
            struct Result: Decodable {
                let id: String
                let title: String?
                let url: String?
                let thumbnail: String?
                let width: Double?
                let height: Double?
            }
            let results: [Result]
        }
        let decoded = try JSONDecoder().decode(OpenverseResponse.self, from: data)
        return decoded.results.compactMap { result in
            guard let urlString = result.url, let full = URL(string: urlString),
                  full.scheme == "https" else { return nil }
            let thumb = result.thumbnail.flatMap(URL.init(string:)) ?? full
            return WebImage(id: result.id,
                            thumbURL: thumb, fullURL: full,
                            width: result.width ?? 1, height: result.height ?? 1,
                            title: result.title ?? "")
        }
    }
}
