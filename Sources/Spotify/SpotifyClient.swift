import Foundation

final class SpotifyClient {
    private let auth: SpotifyAuth
    private let session: URLSession

    init(auth: SpotifyAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func currentUser() async throws -> SpotifyUser {
        try await get("/me")
    }

    func searchTrack(byISRC isrc: String) async throws -> SpotifyTrack? {
        struct SearchResponse: Decodable {
            struct Tracks: Decodable { let items: [SpotifyTrack] }
            let tracks: Tracks
        }
        let resp: SearchResponse = try await get("/search", query: [
            "q": "isrc:\(isrc)",
            "type": "track",
            "limit": "1",
        ])
        return resp.tracks.items.first
    }

    func searchTrack(name: String, artist: String) async throws -> SpotifyTrack? {
        struct SearchResponse: Decodable {
            struct Tracks: Decodable { let items: [SpotifyTrack] }
            let tracks: Tracks
        }
        let resp: SearchResponse = try await get("/search", query: [
            "q": "track:\(name) artist:\(artist)",
            "type": "track",
            "limit": "1",
        ])
        return resp.tracks.items.first
    }

    func playlists(limit: Int = 50) async throws -> [SpotifyPlaylist] {
        struct Page: Decodable { let items: [SpotifyPlaylist] }
        let p: Page = try await get("/me/playlists", query: ["limit": "\(limit)"])
        return p.items
    }

    func createPlaylist(userID: String, name: String, description: String, isPublic: Bool = false) async throws -> SpotifyPlaylist {
        try await post("/users/\(userID)/playlists", body: [
            "name": name,
            "description": description,
            "public": isPublic,
        ])
    }

    func playlistContains(playlistID: String, trackURI: String) async throws -> Bool {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Track: Decodable { let uri: String? }
                let track: Track?
            }
            let items: [Item]
            let next: String?
        }
        var url: URL? = makeURL(path: "/playlists/\(playlistID)/tracks", query: [
            "fields": "items(track(uri)),next",
            "limit": "100",
        ])
        while let u = url {
            let page: Page = try await getAbsolute(u)
            if page.items.contains(where: { $0.track?.uri == trackURI }) { return true }
            url = page.next.flatMap { URL(string: $0) }
        }
        return false
    }

    func addTrack(playlistID: String, trackURI: String) async throws {
        struct SnapshotResponse: Decodable { let snapshot_id: String? }
        let _: SnapshotResponse = try await post("/playlists/\(playlistID)/tracks", body: ["uris": [trackURI]])
    }

    private func makeURL(path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: Config.spotifyAPIBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await getAbsolute(makeURL(path: path, query: query))
    }

    private func getAbsolute<T: Decodable>(_ url: URL) async throws -> T {
        let req = try await authorize(URLRequest(url: url))
        return try await perform(req)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: makeURL(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let authed = try await authorize(req)
        return try await perform(authed)
    }

    private func authorize(_ request: URLRequest, forceRefresh: Bool = false) async throws -> URLRequest {
        var req = request
        let token = try await auth.validAccessToken(forceRefresh: forceRefresh)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest, retriesLeft: Int = 1) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyError.transport }

        if (200..<300).contains(http.statusCode) {
            // Some endpoints (e.g. DELETE) return empty bodies. Decoding "{}" works for empty Decodables.
            if data.isEmpty {
                return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
            }
            return try JSONDecoder().decode(T.self, from: data)
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        // 401 — token may have expired since we last checked. Force a refresh and retry once.
        if http.statusCode == 401, retriesLeft > 0 {
            let refreshed = try await authorize(req, forceRefresh: true)
            return try await perform(refreshed, retriesLeft: retriesLeft - 1)
        }

        // 429 — rate limited. Respect Retry-After (capped at 5s so we stay snappy).
        if http.statusCode == 429, retriesLeft > 0 {
            let after = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)) ?? 1.0
            try await Task.sleep(nanoseconds: UInt64(min(after, 5.0) * 1_000_000_000))
            return try await perform(req, retriesLeft: retriesLeft - 1)
        }

        // 5xx — transient server error. Retry GET only; POST may have side-effected on the server side already.
        let method = req.httpMethod ?? "GET"
        if (500...599).contains(http.statusCode), retriesLeft > 0, method == "GET" {
            try await Task.sleep(nanoseconds: 800_000_000)
            return try await perform(req, retriesLeft: retriesLeft - 1)
        }

        throw SpotifyError.api(status: http.statusCode, body: body)
    }

    enum SpotifyError: Error, LocalizedError {
        case transport
        case api(status: Int, body: String)
        var errorDescription: String? {
            switch self {
            case .transport: return "Network error talking to Spotify."
            case .api(let s, let b): return "Spotify API \(s): \(b)"
            }
        }
    }
}
