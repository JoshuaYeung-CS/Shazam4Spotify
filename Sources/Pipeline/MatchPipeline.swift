import Combine
import Foundation

@MainActor
final class MatchPipeline: ObservableObject {

    enum Status: Equatable {
        case idle
        case searching(songTitle: String)
        case added(songTitle: String, artist: String)
        case skipped(reason: String, songTitle: String)
        case failed(reason: String, songTitle: String)
    }

    @Published private(set) var lastStatus: Status = .idle
    @Published private(set) var caughtSongs: [CaughtEntry] = []

    private let client: SpotifyClient
    private let auth: SpotifyAuth
    private let settings: AppSettings
    private let store = CaughtStore()
    private var bag = Set<AnyCancellable>()

    private var cachedUserID: String?
    private var resolvedPlaylistID: String?

    init(auth: SpotifyAuth, client: SpotifyClient, settings: AppSettings) {
        self.auth = auth
        self.client = client
        self.settings = settings
        self.caughtSongs = store.load()
    }

    func bind(to matcher: ShazamMatcher) {
        matcher.matchPublisher
            .sink { [weak self] song in
                Task { @MainActor in await self?.process(song) }
            }
            .store(in: &bag)
    }

    func clearHistory() {
        caughtSongs = []
        store.clear()
    }

    /// Forget the cached playlist resolution — call after the user changes the target playlist in Settings.
    func invalidatePlaylistCache() {
        resolvedPlaylistID = nil
    }

    func process(_ song: RecognizedSong) async {
        lastStatus = .searching(songTitle: song.title)
        do {
            guard auth.isSignedIn else { throw PipelineError.notSignedIn }
            let track = try await resolveTrack(for: song)
            guard let track else {
                record(.init(song: song, track: nil, status: .notOnSpotify))
                lastStatus = .skipped(reason: "Not found on Spotify", songTitle: song.title)
                if settings.hapticsEnabled { Haptics.warning() }
                return
            }
            let playlistID = try await ensurePlaylist()
            let alreadyIn = try await client.playlistContains(playlistID: playlistID, trackURI: track.uri)
            if alreadyIn {
                record(.init(song: song, track: track, status: .alreadyInPlaylist))
                lastStatus = .skipped(reason: "Already in playlist", songTitle: track.name)
                if settings.hapticsEnabled { Haptics.warning() }
                return
            }
            try await client.addTrack(playlistID: playlistID, trackURI: track.uri)
            record(.init(song: song, track: track, status: .added))
            lastStatus = .added(songTitle: track.name, artist: track.artistNames)
            if settings.hapticsEnabled { Haptics.success() }
        } catch {
            record(.init(song: song, track: nil, status: .failed(error.localizedDescription)))
            lastStatus = .failed(reason: error.localizedDescription, songTitle: song.title)
            if settings.hapticsEnabled { Haptics.error() }
        }
    }

    private func record(_ entry: CaughtEntry) {
        caughtSongs.insert(entry, at: 0)
        store.save(caughtSongs)
    }

    private func resolveTrack(for song: RecognizedSong) async throws -> SpotifyTrack? {
        if let isrc = song.isrc, let track = try await client.searchTrack(byISRC: isrc) {
            return track
        }
        return try await client.searchTrack(name: song.title, artist: song.artist)
    }

    private func ensurePlaylist() async throws -> String {
        if let id = resolvedPlaylistID { return id }

        // 1. User-picked playlist takes priority.
        if let id = settings.targetPlaylistID {
            resolvedPlaylistID = id
            return id
        }

        // 2. Otherwise look up (or create) the default-named playlist.
        let userID = try await currentUserID()
        if let existing = try await client.playlists().first(where: { $0.name == Config.defaultPlaylistName }) {
            resolvedPlaylistID = existing.id
            return existing.id
        }
        let new = try await client.createPlaylist(
            userID: userID,
            name: Config.defaultPlaylistName,
            description: Config.defaultPlaylistDescription
        )
        resolvedPlaylistID = new.id
        settings.targetPlaylistID = new.id
        settings.targetPlaylistName = new.name
        return new.id
    }

    private func currentUserID() async throws -> String {
        if let id = cachedUserID { return id }
        let user = try await client.currentUser()
        cachedUserID = user.id
        return user.id
    }

    enum PipelineError: Error, LocalizedError {
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to Spotify first."
            }
        }
    }
}

struct CaughtEntry: Identifiable, Equatable, Codable {
    enum Status: Equatable, Codable {
        case added
        case alreadyInPlaylist
        case notOnSpotify
        case failed(String)
    }

    let id: UUID
    let song: RecognizedSong
    let track: SpotifyTrack?
    let status: Status
    let timestamp: Date

    init(song: RecognizedSong, track: SpotifyTrack?, status: Status) {
        self.id = UUID()
        self.song = song
        self.track = track
        self.status = status
        self.timestamp = Date()
    }

    var displayTitle: String { track?.name ?? song.title }
    var displayArtist: String { track?.artistNames ?? song.artist }
    var artworkURL: URL? { track?.artworkURL ?? song.artworkURL }
    var spotifyURL: URL? { track?.spotifyAppURL }
}
