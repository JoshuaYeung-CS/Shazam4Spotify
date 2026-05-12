import Foundation
import OSLog

final class SpotifyClient {
    private let tokenProvider: TokenProviding
    private let session: URLSession
    private let log = Logger.api

    init(auth: TokenProviding, session: URLSession = .shared) {
        self.tokenProvider = auth
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

    func playlists(limit: Int = 50, offset: Int = 0) async throws -> [SpotifyPlaylist] {
        struct Page: Decodable { let items: [SpotifyPlaylist] }
        let p: Page = try await get("/me/playlists", query: [
            "limit": "\(limit)",
            "offset": "\(offset)",
        ])
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

    /// Add a track to the user's Liked Songs library. Requires `user-library-modify` scope.
    func saveToLikedSongs(trackID: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await put("/me/tracks", query: ["ids": trackID])
    }

    /// Check whether a track is already in the user's Liked Songs. Requires `user-library-read` scope.
    func likedSongsContains(trackID: String) async throws -> Bool {
        let result: [Bool] = try await get("/me/tracks/contains", query: ["ids": trackID])
        return result.first ?? false
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

    private func put<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: makeURL(path: path, query: query))
        req.httpMethod = "PUT"
        let authed = try await authorize(req)
        return try await perform(authed)
    }

    private func authorize(_ request: URLRequest, forceRefresh: Bool = false) async throws -> URLRequest {
        var req = request
        let token = try await tokenProvider.validAccessToken(forceRefresh: forceRefresh)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest, retriesLeft: Int = 1) async throws -> T {
        let method = req.httpMethod ?? "GET"
        let urlString = req.url?.absoluteString ?? "?"

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            log.error("Network error \(method, privacy: .public) \(urlString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SpotifyError.transport
        }
        guard let http = resp as? HTTPURLResponse else { throw SpotifyError.transport }
        log.debug("\(method, privacy: .public) \(urlString, privacy: .public) → \(http.statusCode)")

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
            log.notice("401 — forcing token refresh and retrying")
            let refreshed = try await authorize(req, forceRefresh: true)
            return try await perform(refreshed, retriesLeft: retriesLeft - 1)
        }

        // 429 — rate limited. Respect Retry-After (capped at 5s so we stay snappy).
        if http.statusCode == 429, retriesLeft > 0 {
            let after = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)) ?? 1.0
            let wait = min(after, 5.0)
            log.notice("429 — rate-limited, waiting \(wait)s")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            return try await perform(req, retriesLeft: retriesLeft - 1)
        }

        // 5xx — transient server error. Retry GET only; POST may have side-effected on the server side already.
        if (500...599).contains(http.statusCode), retriesLeft > 0, method == "GET" {
            log.notice("\(http.statusCode) — transient, retrying GET after 800ms")
            try await Task.sleep(nanoseconds: 800_000_000)
            return try await perform(req, retriesLeft: retriesLeft - 1)
        }

        let parsedMessage = parseSpotifyMessage(from: data) ?? body
        log.error("\(http.statusCode) on \(method, privacy: .public) \(urlString, privacy: .public): \(parsedMessage, privacy: .public)")
        throw SpotifyError.api(status: http.statusCode, message: parsedMessage)
    }

    private func parseSpotifyMessage(from data: Data) -> String? {
        // Spotify error envelope: `{"error": {"status": 404, "message": "..."}}`
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let msg = env.error?.message, !msg.isEmpty {
            return msg
        }
        // OAuth-style envelope: `{"error": "invalid_grant", "error_description": "..."}`
        struct OAuthEnvelope: Decodable {
            let error: String?
            let error_description: String?
        }
        if let env = try? JSONDecoder().decode(OAuthEnvelope.self, from: data) {
            if let desc = env.error_description, !desc.isEmpty { return desc }
            if let err = env.error, !err.isEmpty { return err }
        }
        return nil
    }

    enum SpotifyError: Error, LocalizedError {
        case transport
        case api(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .transport: return "Couldn't reach Spotify. Check your network."
            case .api(let s, let m): return prettyMessage(status: s, message: m)
            }
        }

        var statusCode: Int? {
            if case .api(let s, _) = self { return s }
            return nil
        }

        private func prettyMessage(status: Int, message: String) -> String {
            // Common cases get user-friendly mapping.
            switch status {
            case 401: return "Your Spotify session expired. Sign in again."
            case 403: return message.contains("development mode")
                ? "Add your Spotify account to the app's User Management list on developer.spotify.com."
                : "Spotify rejected the request: \(message)"
            case 404: return message.isEmpty ? "Resource not found on Spotify." : message
            case 429: return "Spotify is rate-limiting us. Try again in a moment."
            case 500...599: return "Spotify is having a hiccup (HTTP \(status)). Try again."
            default:
                return message.isEmpty ? "Spotify error (HTTP \(status))." : message
            }
        }
    }
}
