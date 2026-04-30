import Combine
import Foundation
import OSLog

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

    private let client: SpotifyClientProtocol
    private let auth: AuthStateProviding
    private let settings: AppSettings
    private let store: CaughtStore
    private let log = Logger.pipeline
    private var bag = Set<AnyCancellable>()

    private var cachedUserID: String?
    private var resolvedPlaylistID: String?

    init(
        auth: AuthStateProviding,
        client: SpotifyClientProtocol,
        settings: AppSettings,
        store: CaughtStore? = nil
    ) {
        let resolved = store ?? CaughtStore()
        self.auth = auth
        self.client = client
        self.settings = settings
        self.store = resolved
        self.caughtSongs = resolved.load()
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

    /// Best-effort fetch of the signed-in user so the UI can show "Signed in as <name>" without waiting for a match.
    func refreshUserInfo() async {
        guard auth.isSignedIn else { return }
        do {
            let user = try await client.currentUser()
            cachedUserID = user.id
            if let name = user.displayName, !name.isEmpty {
                settings.userDisplayName = name
            }
        } catch {
            log.notice("Couldn't fetch user info: \(error.localizedDescription, privacy: .public)")
        }
    }

    func process(_ song: RecognizedSong) async {
        log.info("Processing match: \(song.title, privacy: .public) — \(song.artist, privacy: .public)")
        lastStatus = .searching(songTitle: song.title)
        do {
            guard auth.isSignedIn else { throw PipelineError.notSignedIn }

            let track = try await resolveTrack(for: song)
            guard let track else {
                log.notice("No Spotify match for ISRC=\(song.isrc ?? "nil", privacy: .public)")
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

            try await addTrackWithRecovery(playlistID: playlistID, track: track)
            log.info("Added \(track.uri, privacy: .public) to playlist \(playlistID, privacy: .public)")
            record(.init(song: song, track: track, status: .added))
            lastStatus = .added(songTitle: track.name, artist: track.artistNames)
            if settings.hapticsEnabled { Haptics.success() }
        } catch {
            log.error("Pipeline failure: \(error.localizedDescription, privacy: .public)")
            record(.init(song: song, track: nil, status: .failed(error.localizedDescription)))
            lastStatus = .failed(reason: error.localizedDescription, songTitle: song.title)
            if settings.hapticsEnabled { Haptics.error() }
        }
    }

    // MARK: - private

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

    /// Adds a track, recovering once if Spotify returns 404 (typically: target playlist was deleted on the server).
    private func addTrackWithRecovery(playlistID: String, track: SpotifyTrack) async throws {
        do {
            try await client.addTrack(playlistID: playlistID, trackURI: track.uri)
        } catch {
            guard error.spotifyStatus == 404 else { throw error }
            log.notice("Target playlist \(playlistID, privacy: .public) appears gone — re-resolving and retrying")
            resolvedPlaylistID = nil
            if settings.targetPlaylistID == playlistID {
                settings.targetPlaylistID = nil
                settings.targetPlaylistName = nil
            }
            let recoveredID = try await ensurePlaylist()
            try await client.addTrack(playlistID: recoveredID, trackURI: track.uri)
        }
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
        // Cache the display name for the UI so we don't have to hit /me on every launch.
        if let name = user.displayName, !name.isEmpty {
            settings.userDisplayName = name
        }
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

    init(song: RecognizedSong, track: SpotifyTrack?, status: Status, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.song = song
        self.track = track
        self.status = status
        self.timestamp = timestamp
    }

    var displayTitle: String { track?.name ?? song.title }
    var displayArtist: String { track?.artistNames ?? song.artist }
    var artworkURL: URL? { track?.artworkURL ?? song.artworkURL }
    var spotifyURL: URL? { track?.spotifyAppURL }
}
