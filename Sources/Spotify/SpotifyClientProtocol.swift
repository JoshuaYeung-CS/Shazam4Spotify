import Foundation

protocol SpotifyClientProtocol: AnyObject {
    func currentUser() async throws -> SpotifyUser
    func searchTrack(byISRC isrc: String) async throws -> SpotifyTrack?
    func searchTrack(name: String, artist: String) async throws -> SpotifyTrack?
    func playlists(limit: Int, offset: Int) async throws -> [SpotifyPlaylist]
    func createPlaylist(userID: String, name: String, description: String, isPublic: Bool) async throws -> SpotifyPlaylist
    func playlistContains(playlistID: String, trackURI: String) async throws -> Bool
    func addTrack(playlistID: String, trackURI: String) async throws
}

extension SpotifyClientProtocol {
    func playlists() async throws -> [SpotifyPlaylist] {
        try await playlists(limit: 50, offset: 0)
    }

    func playlists(limit: Int) async throws -> [SpotifyPlaylist] {
        try await playlists(limit: limit, offset: 0)
    }

    func createPlaylist(userID: String, name: String, description: String) async throws -> SpotifyPlaylist {
        try await createPlaylist(userID: userID, name: name, description: description, isPublic: false)
    }

    /// Fetches all of the user's playlists by paging through `/me/playlists`. Capped at `maxItems` to keep memory bounded.
    func allPlaylists(maxItems: Int = 500) async throws -> [SpotifyPlaylist] {
        var collected: [SpotifyPlaylist] = []
        let pageSize = 50
        var offset = 0
        while collected.count < maxItems {
            let page = try await playlists(limit: pageSize, offset: offset)
            collected.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return Array(collected.prefix(maxItems))
    }
}

extension SpotifyClient: SpotifyClientProtocol {}

/// Minimal surface MatchPipeline needs from the auth layer. Lets tests inject a stub instead of the full SpotifyAuth.
@MainActor
protocol AuthStateProviding: AnyObject {
    var isSignedIn: Bool { get }
}

extension SpotifyAuth: AuthStateProviding {}

/// Surface SpotifyClient needs to attach a Bearer token. Lets tests skip Keychain/OAuth entirely.
@MainActor
protocol TokenProviding: AnyObject {
    func validAccessToken(forceRefresh: Bool) async throws -> String
}

extension SpotifyAuth: TokenProviding {}

extension Error {
    /// Convenience: returns Spotify's HTTP status code if this error came from `SpotifyClient`.
    var spotifyStatus: Int? {
        if let e = self as? SpotifyClient.SpotifyError, case .api(let s, _) = e {
            return s
        }
        return nil
    }
}
