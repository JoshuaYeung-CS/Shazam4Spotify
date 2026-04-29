import Foundation

struct SpotifyTrack: Codable, Hashable {
    let id: String
    let uri: String
    let name: String
    let artists: [Artist]
    let album: Album?
    let externalIDs: ExternalIDs?

    struct Artist: Codable, Hashable {
        let id: String
        let name: String
    }

    struct Album: Codable, Hashable {
        let id: String
        let name: String
        let images: [Image]?

        struct Image: Codable, Hashable {
            let url: URL
            let width: Int?
            let height: Int?
        }

        var smallestImageURL: URL? {
            images?.min(by: { ($0.width ?? .max) < ($1.width ?? .max) })?.url
        }
    }

    struct ExternalIDs: Codable, Hashable {
        let isrc: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, album
        case externalIDs = "external_ids"
    }

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var artworkURL: URL? { album?.smallestImageURL }
    var spotifyAppURL: URL? { URL(string: "spotify:track:\(id)") }
    var spotifyWebURL: URL? { URL(string: "https://open.spotify.com/track/\(id)") }
}

struct SpotifyPlaylist: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let tracks: TrackCount?

    struct TrackCount: Decodable, Hashable {
        let total: Int
    }

    var spotifyAppURL: URL? { URL(string: "spotify:playlist:\(id)") }
}

struct SpotifyUser: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}
