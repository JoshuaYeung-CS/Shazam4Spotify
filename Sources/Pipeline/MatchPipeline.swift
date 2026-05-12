import Combine
import Foundation
import OSLog

@MainActor
final class MatchPipeline: ObservableObject {

    enum Status: Equatable {
        case idle
        case searching(songTitle: String)
        case added(songTitle: String, artist: String, summary: String)
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
    private var resolvedShazamPlaylistID: String?

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

    /// Forget the cached Shazam-playlist resolution — call after the user changes target settings.
    func invalidatePlaylistCache() {
        resolvedShazamPlaylistID = nil
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

            let destinations = await buildDestinations()
            guard !destinations.isEmpty else {
                let msg = "No destinations enabled — turn on Liked Songs or a playlist in Settings"
                record(.init(song: song, track: track, status: .failed(msg)))
                lastStatus = .failed(reason: msg, songTitle: track.name)
                if settings.hapticsEnabled { Haptics.warning() }
                return
            }

            var addedTo: [String] = []
            var alreadyIn: [String] = []
            var failedAt: [(String, String)] = []  // (label, error message)

            for dest in destinations {
                do {
                    if try await isAlreadyIn(track: track, destination: dest) {
                        log.info("\(dest.label, privacy: .public): already contains track — skipping")
                        alreadyIn.append(dest.label)
                        continue
                    }
                    try await add(track: track, to: dest)
                    log.info("Added \(track.uri, privacy: .public) → \(dest.label, privacy: .public)")
                    addedTo.append(dest.label)
                } catch {
                    log.error("Failed \(dest.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failedAt.append((dest.label, error.localizedDescription))
                }
            }

            // Aggregate result.
            if !addedTo.isEmpty {
                let summary = makeSummary(added: addedTo, alreadyIn: alreadyIn, failed: failedAt)
                record(.init(song: song, track: track, status: .added))
                lastStatus = .added(songTitle: track.name, artist: track.artistNames, summary: summary)
                if settings.hapticsEnabled { Haptics.success() }
            } else if alreadyIn.count == destinations.count {
                record(.init(song: song, track: track, status: .alreadyInPlaylist))
                lastStatus = .skipped(reason: "Already saved everywhere", songTitle: track.name)
                if settings.hapticsEnabled { Haptics.warning() }
            } else {
                let firstError = failedAt.first?.1 ?? "All destinations refused the track"
                record(.init(song: song, track: track, status: .failed(firstError)))
                lastStatus = .failed(reason: firstError, songTitle: track.name)
                if settings.hapticsEnabled { Haptics.error() }
            }
        } catch {
            log.error("Pipeline failure: \(error.localizedDescription, privacy: .public)")
            record(.init(song: song, track: nil, status: .failed(error.localizedDescription)))
            lastStatus = .failed(reason: error.localizedDescription, songTitle: song.title)
            if settings.hapticsEnabled { Haptics.error() }
        }
    }

    // MARK: - destinations

    private enum Destination {
        case likedSongs
        case playlist(id: String, name: String)

        var label: String {
            switch self {
            case .likedSongs: return "Liked Songs"
            case .playlist(_, let name): return name
            }
        }
    }

    /// Builds the list of enabled destinations for the current match.
    /// Failing to resolve the Shazam playlist silently omits it rather than failing the whole pipeline.
    private func buildDestinations() async -> [Destination] {
        var result: [Destination] = []
        if settings.saveToLikedSongs { result.append(.likedSongs) }
        if settings.saveToShazamPlaylist, let id = await ensureShazamPlaylistID() {
            result.append(.playlist(id: id, name: Config.defaultPlaylistName))
        }
        for id in settings.additionalPlaylistIDs {
            let name = settings.additionalPlaylistNames[id] ?? "Playlist"
            result.append(.playlist(id: id, name: name))
        }
        return result
    }

    private func ensureShazamPlaylistID() async -> String? {
        if let id = resolvedShazamPlaylistID { return id }
        // Reuse previously resolved/persisted ID if present.
        if let id = settings.targetPlaylistID {
            resolvedShazamPlaylistID = id
            return id
        }
        // Look up by name, otherwise create.
        do {
            let userID = try await currentUserID()
            if let existing = try await client.playlists().first(where: { $0.name == Config.defaultPlaylistName }) {
                resolvedShazamPlaylistID = existing.id
                settings.targetPlaylistID = existing.id
                settings.targetPlaylistName = existing.name
                return existing.id
            }
            let new = try await client.createPlaylist(
                userID: userID,
                name: Config.defaultPlaylistName,
                description: Config.defaultPlaylistDescription
            )
            resolvedShazamPlaylistID = new.id
            settings.targetPlaylistID = new.id
            settings.targetPlaylistName = new.name
            return new.id
        } catch {
            log.error("Couldn't ensure Shazam playlist: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isAlreadyIn(track: SpotifyTrack, destination: Destination) async throws -> Bool {
        switch destination {
        case .likedSongs:
            return try await client.likedSongsContains(trackID: track.id)
        case .playlist(let id, _):
            return try await client.playlistContains(playlistID: id, trackURI: track.uri)
        }
    }

    private func add(track: SpotifyTrack, to destination: Destination) async throws {
        switch destination {
        case .likedSongs:
            try await client.saveToLikedSongs(trackID: track.id)
        case .playlist(let id, _):
            do {
                try await client.addTrack(playlistID: id, trackURI: track.uri)
            } catch {
                // If the playlist 404s, clear the cached resolution so the next attempt re-resolves.
                if error.spotifyStatus == 404, id == resolvedShazamPlaylistID {
                    log.notice("Shazam playlist \(id, privacy: .public) appears gone — clearing cache")
                    resolvedShazamPlaylistID = nil
                    settings.targetPlaylistID = nil
                    settings.targetPlaylistName = nil
                }
                throw error
            }
        }
    }

    // MARK: - helpers

    private func makeSummary(added: [String], alreadyIn: [String], failed: [(String, String)]) -> String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append("added to \(added.joined(separator: ", "))")
        }
        if !alreadyIn.isEmpty {
            parts.append("already in \(alreadyIn.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            parts.append("failed: \(failed.map(\.0).joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
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

    private func currentUserID() async throws -> String {
        if let id = cachedUserID { return id }
        let user = try await client.currentUser()
        cachedUserID = user.id
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
