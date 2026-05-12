import XCTest
@testable import Shazam4Spotify

@MainActor
final class MatchPipelineTests: XCTestCase {
    private var auth: MockAuth!
    private var settings: AppSettings!
    private var client: MockSpotifyClient!
    private var store: CaughtStore!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MatchPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Wipe UserDefaults so settings start clean.
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "test")
        settings = AppSettings()
        settings.targetPlaylistID = nil
        settings.targetPlaylistName = nil
        // Default to playlist-only in tests; opt-in to liked songs per-test.
        settings.saveToLikedSongs = false
        settings.saveToShazamPlaylist = true
        settings.additionalPlaylistIDs = []
        settings.additionalPlaylistNames = [:]

        auth = MockAuth()
        client = MockSpotifyClient()
        store = CaughtStore(fileURL: tempDir.appendingPathComponent("caught.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makePipeline(signedIn: Bool = true) -> MatchPipeline {
        auth.isSignedIn = signedIn
        return MatchPipeline(auth: auth, client: client, settings: settings, store: store)
    }

    private func makeSong(title: String = "Bohemian Rhapsody",
                         artist: String = "Queen",
                         isrc: String? = "GBUM71029604") -> RecognizedSong {
        RecognizedSong(title: title, artist: artist, isrc: isrc)
    }

    // MARK: - Tests

    func testNotSignedInRecordsFailure() async {
        let pipeline = makePipeline(signedIn: false)
        await pipeline.process(makeSong())
        XCTAssertEqual(pipeline.caughtSongs.count, 1)
        if case .failed = pipeline.caughtSongs[0].status {} else {
            XCTFail("Expected .failed status when not signed in")
        }
    }

    func testHappyPathAddsToShazamPlaylist() async {
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = []
        client.createPlaylistReturns = samplePlaylist
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        XCTAssertEqual(client.addedTracks, [.init(playlistID: samplePlaylist.id, trackURI: sampleTrack.uri)])
        XCTAssertEqual(pipeline.caughtSongs.count, 1)
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added)
    }

    func testLikedSongsOnly() async {
        settings.saveToLikedSongs = true
        settings.saveToShazamPlaylist = false
        client.searchByISRCResult = sampleTrack
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        XCTAssertEqual(client.savedToLikedSongs, [sampleTrack.id])
        XCTAssertTrue(client.addedTracks.isEmpty)
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added)
    }

    func testBothLikedAndPlaylistDestinations() async {
        settings.saveToLikedSongs = true
        settings.saveToShazamPlaylist = true
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = []
        client.createPlaylistReturns = samplePlaylist
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        XCTAssertEqual(client.savedToLikedSongs, [sampleTrack.id])
        XCTAssertEqual(client.addedTracks, [.init(playlistID: samplePlaylist.id, trackURI: sampleTrack.uri)])
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added)
    }

    func testAdditionalPlaylistMirroring() async {
        let extraPlaylistID = "extra-playlist-id"
        settings.saveToLikedSongs = false
        settings.saveToShazamPlaylist = false
        settings.additionalPlaylistIDs = [extraPlaylistID]
        settings.additionalPlaylistNames = [extraPlaylistID: "My Genre Playlist"]
        client.searchByISRCResult = sampleTrack
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        XCTAssertEqual(client.addedTracks, [.init(playlistID: extraPlaylistID, trackURI: sampleTrack.uri)])
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added)
    }

    func testNoDestinationsEnabledFailsGracefully() async {
        settings.saveToLikedSongs = false
        settings.saveToShazamPlaylist = false
        settings.additionalPlaylistIDs = []
        client.searchByISRCResult = sampleTrack
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        if case .failed(let msg) = pipeline.caughtSongs[0].status {
            XCTAssertTrue(msg.contains("destinations"))
        } else {
            XCTFail("Expected .failed when no destinations enabled")
        }
        XCTAssertTrue(client.addedTracks.isEmpty)
        XCTAssertTrue(client.savedToLikedSongs.isEmpty)
    }

    func testSongNotOnSpotifyIsRecordedSeparately() async {
        client.searchByISRCResult = nil
        client.searchByNameResult = nil
        let pipeline = makePipeline()
        await pipeline.process(makeSong())
        XCTAssertEqual(pipeline.caughtSongs[0].status, .notOnSpotify)
        XCTAssertTrue(client.addedTracks.isEmpty)
    }

    func testAlreadyInPlaylistDoesNotReAdd() async {
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = [samplePlaylist]
        client.playlistContainsResult = true
        settings.targetPlaylistID = samplePlaylist.id
        settings.targetPlaylistName = samplePlaylist.name

        let pipeline = makePipeline()
        await pipeline.process(makeSong())

        XCTAssertTrue(client.addedTracks.isEmpty)
        XCTAssertEqual(pipeline.caughtSongs[0].status, .alreadyInPlaylist)
    }

    func testHistoryPersistsAcrossNewPipeline() async {
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = [samplePlaylist]
        settings.targetPlaylistID = samplePlaylist.id

        let p1 = makePipeline()
        await p1.process(makeSong())
        XCTAssertEqual(p1.caughtSongs.count, 1)

        // New pipeline using same store should restore history.
        let p2 = MatchPipeline(auth: auth, client: client, settings: settings, store: store)
        XCTAssertEqual(p2.caughtSongs.count, 1)
        XCTAssertEqual(p2.caughtSongs[0].displayTitle, sampleTrack.name)
    }

    func testClearHistoryEmptiesBoth() async {
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = [samplePlaylist]
        settings.targetPlaylistID = samplePlaylist.id

        let pipeline = makePipeline()
        await pipeline.process(makeSong())
        XCTAssertFalse(pipeline.caughtSongs.isEmpty)
        pipeline.clearHistory()
        XCTAssertTrue(pipeline.caughtSongs.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Sample data

    private var sampleTrack: SpotifyTrack {
        SpotifyTrack(
            id: "track-1",
            uri: "spotify:track:track-1",
            name: "Bohemian Rhapsody",
            artists: [.init(id: "queen", name: "Queen")],
            album: SpotifyTrack.Album(id: "album-1", name: "A Night at the Opera", images: nil),
            externalIDs: SpotifyTrack.ExternalIDs(isrc: "GBUM71029604")
        )
    }

    private var samplePlaylist: SpotifyPlaylist {
        SpotifyPlaylist(
            id: "playlist-fresh",
            name: Config.defaultPlaylistName,
            description: nil,
            tracks: nil
        )
    }
}

// MARK: - Mock client

@MainActor
final class MockSpotifyClient: SpotifyClientProtocol {
    enum AddTrackBehavior {
        case alwaysSucceed
        case alwaysFail(Error)
        case failFirstThenSucceed(error: Error)
    }

    var currentUserResult: SpotifyUser = .init(displayName: "Test User", id: "test-user")
    var searchByISRCResult: SpotifyTrack?
    var searchByNameResult: SpotifyTrack?
    var playlists_returns: [SpotifyPlaylist] = []
    var createPlaylistReturns: SpotifyPlaylist!
    var playlistContainsResult: Bool = false
    var likedSongsContainsResult: Bool = false
    var addTrackBehavior: AddTrackBehavior = .alwaysSucceed

    struct AddedTrack: Equatable { let playlistID: String; let trackURI: String }
    private(set) var addedTracks: [AddedTrack] = []
    private(set) var savedToLikedSongs: [String] = []
    private var addCallCount = 0

    func currentUser() async throws -> SpotifyUser { currentUserResult }
    func searchTrack(byISRC isrc: String) async throws -> SpotifyTrack? { searchByISRCResult }
    func searchTrack(name: String, artist: String) async throws -> SpotifyTrack? { searchByNameResult }
    func playlists(limit: Int, offset: Int) async throws -> [SpotifyPlaylist] {
        guard offset < playlists_returns.count else { return [] }
        let end = min(offset + limit, playlists_returns.count)
        return Array(playlists_returns[offset..<end])
    }
    func createPlaylist(userID: String, name: String, description: String, isPublic: Bool) async throws -> SpotifyPlaylist {
        guard let p = createPlaylistReturns else { throw NSError(domain: "Mock", code: 0) }
        return p
    }
    func playlistContains(playlistID: String, trackURI: String) async throws -> Bool { playlistContainsResult }
    func addTrack(playlistID: String, trackURI: String) async throws {
        addCallCount += 1
        addedTracks.append(.init(playlistID: playlistID, trackURI: trackURI))
        switch addTrackBehavior {
        case .alwaysSucceed: return
        case .alwaysFail(let err): throw err
        case .failFirstThenSucceed(let err):
            if addCallCount == 1 { throw err }
        }
    }
    func saveToLikedSongs(trackID: String) async throws {
        savedToLikedSongs.append(trackID)
    }
    func likedSongsContains(trackID: String) async throws -> Bool { likedSongsContainsResult }
}

// MARK: - Mock auth + test-only helpers on Spotify models

@MainActor
final class MockAuth: AuthStateProviding {
    var isSignedIn: Bool = true
}

extension SpotifyUser {
    init(displayName: String?, id: String) {
        let json: [String: Any] = ["id": id, "display_name": displayName as Any]
        let data = try! JSONSerialization.data(withJSONObject: json)
        self = try! JSONDecoder().decode(SpotifyUser.self, from: data)
    }
}

extension SpotifyPlaylist {
    init(id: String, name: String, description: String?, tracks: TrackCount?) {
        let json: [String: Any] = [
            "id": id,
            "name": name,
            "description": description as Any,
            "tracks": tracks.map { ["total": $0.total] } as Any,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        self = try! JSONDecoder().decode(SpotifyPlaylist.self, from: data)
    }
}

extension SpotifyTrack {
    init(id: String, uri: String, name: String, artists: [Artist], album: Album?, externalIDs: ExternalIDs?) {
        let payload: [String: Any] = [
            "id": id,
            "uri": uri,
            "name": name,
            "artists": artists.map { ["id": $0.id, "name": $0.name] },
            "album": album.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "images": $0.images.map { $0.map { ["url": $0.url.absoluteString, "width": $0.width as Any, "height": $0.height as Any] } } as Any,
                ]
            } as Any,
            "external_ids": externalIDs.map { ["isrc": $0.isrc as Any] } as Any,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        self = try! JSONDecoder().decode(SpotifyTrack.self, from: data)
    }
}
