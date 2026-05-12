import Foundation

enum Config {
    static let spotifyClientID = "425c8fe4e7c2448a9174e83b7bb2b6a2"
    static let spotifyRedirectURI = "shazam4spotify://callback"
    static let spotifyAuthorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let spotifyTokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let spotifyAPIBase = URL(string: "https://api.spotify.com/v1")!

    static let spotifyScopes = [
        "playlist-read-private",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-read-private",
        "user-library-read",
        "user-library-modify",
    ]

    static let defaultPlaylistName = "Shazam Songs"
    static let defaultPlaylistDescription = "Songs auto-added by Shazam4Spotify"
}
