import Foundation

protocol SpotifyClientProtocol: AnyObject {
    func currentUser() async throws -> SpotifyUser
    func searchTrack(byISRC isrc: String) async throws -> SpotifyTrack?
    func searchTrack(name: String, artist: String) async throws -> SpotifyTrack?
    func playlists(limit: Int) async throws -> [SpotifyPlaylist]
    func createPlaylist(userID: String, name: String, description: String, isPublic: Bool) async throws -> SpotifyPlaylist
    func playlistContains(playlistID: String, trackURI: String) async throws -> Bool
    func addTrack(playlistID: String, trackURI: String) async throws
}

extension SpotifyClientProtocol {
    func playlists() async throws -> [SpotifyPlaylist] {
        try await playlists(limit: 50)
    }

    func createPlaylist(userID: String, name: String, description: String) async throws -> SpotifyPlaylist {
        try await createPlaylist(userID: userID, name: name, description: description, isPublic: false)
    }
}

extension SpotifyClient: SpotifyClientProtocol {}

/// Minimal surface MatchPipeline needs from the auth layer. Lets tests inject a stub instead of the full SpotifyAuth.
@MainActor
protocol AuthStateProviding: AnyObject {
    var isSignedIn: Bool { get }
}

extension SpotifyAuth: AuthStateProviding {}

extension Error {
    /// Convenience: returns Spotify's HTTP status code if this error came from `SpotifyClient`.
    var spotifyStatus: Int? {
        if let e = self as? SpotifyClient.SpotifyError, case .api(let s, _) = e {
            return s
        }
        return nil
    }
}
