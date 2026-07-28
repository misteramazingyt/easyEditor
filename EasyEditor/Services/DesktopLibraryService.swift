import Foundation

/// Client for the desktop-server (see desktop-server/server.py): browse the
/// picture library, run semantic searches, and build thumb/file URLs — all
/// over the tailnet.
struct DesktopLibraryService {

    struct Health: Decodable {
        let ok: Bool
        let indexReady: Bool
        let indexedImages: Int
    }

    struct BrowseResult: Decodable {
        struct Entry: Decodable {
            let path: String
            let name: String
        }
        let folders: [String]
        let images: [Entry]
        let path: String
    }

    struct SearchResponse: Decodable {
        struct Entry: Decodable {
            let path: String
            let name: String
            let width: Double?
            let height: Double?
        }
        let results: [Entry]
    }

    enum ServiceError: LocalizedError {
        case badURL
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "The server URL in Settings doesn't look valid."
            case .server(let message): return message
            }
        }
    }

    let baseURL: URL
    let token: String

    init?(urlString: String, token: String) {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        self.baseURL = url
        self.token = token.trimmingCharacters(in: .whitespaces)
    }

    // MARK: URL building

    func url(_ route: String, _ items: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(route),
                                       resolvingAgainstBaseURL: false)!
        var all = items
        if !token.isEmpty { all.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = all.isEmpty ? nil : all
        return components.url!
    }

    func thumbURL(forPath path: String) -> URL {
        url("thumb", [URLQueryItem(name: "path", value: path)])
    }

    func fileURL(forPath path: String) -> URL {
        url("file", [URLQueryItem(name: "path", value: path)])
    }

    // MARK: Calls

    private func get<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 {
                throw ServiceError.server("Unauthorized — check the token in Settings.")
            }
            throw ServiceError.server("Server error (\(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func health() async throws -> Health {
        try await get(Health.self, from: url("health"))
    }

    func browse(path: String?) async throws -> BrowseResult {
        var items: [URLQueryItem] = []
        if let path { items.append(URLQueryItem(name: "path", value: path)) }
        return try await get(BrowseResult.self, from: url("browse", items))
    }

    func search(_ query: String, count: Int = 60,
                folder: String? = nil,
                background: String? = nil,
                colorHex: String? = nil) async throws -> [WebImage] {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "k", value: String(count)),
        ]
        if let folder, !folder.isEmpty {
            items.append(URLQueryItem(name: "folder", value: folder))
        }
        if let background, !background.isEmpty {
            items.append(URLQueryItem(name: "bg", value: background))
        }
        if let colorHex, !colorHex.isEmpty {
            items.append(URLQueryItem(name: "color", value: colorHex))
        }
        let response = try await get(SearchResponse.self, from: url("search", items))
        return response.results.map { entry in
            WebImage(id: entry.path,
                     thumbURL: thumbURL(forPath: entry.path),
                     fullURL: fileURL(forPath: entry.path),
                     width: entry.width ?? 1,
                     height: entry.height ?? 1,
                     title: entry.name)
        }
    }

    func browseImages(_ result: BrowseResult) -> [WebImage] {
        result.images.map { entry in
            WebImage(id: entry.path,
                     thumbURL: thumbURL(forPath: entry.path),
                     fullURL: fileURL(forPath: entry.path),
                     width: 1, height: 1,
                     title: entry.name)
        }
    }
}

/// App-wide settings keys for the desktop library connection.
enum DesktopLibrarySettings {
    static let urlKey = "desktopServerURL"
    static let tokenKey = "desktopServerToken"
}
