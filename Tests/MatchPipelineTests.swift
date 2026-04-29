import XCTest
@testable import Shazam2Spotify

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

    func testHappyPathAddsAndRecords() async {
        client.searchByISRCResult = sampleTrack
        client.playlists_returns = []
        client.createPlaylistReturns = samplePlaylist
        let pipeline = makePipeline()

        await pipeline.process(makeSong())

        XCTAssertEqual(client.addedTracks, [(samplePlaylist.id, sampleTrack.uri)])
        XCTAssertEqual(pipeline.caughtSongs.count, 1)
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added)
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

    func testAutoRecoveryWhenPlaylistDeleted() async {
        // Set up: user-picked playlist whose addTrack 404s the first time, succeeds the second.
        settings.targetPlaylistID = "stale-playlist"
        settings.targetPlaylistName = "Old Playlist"
        client.searchByISRCResult = sampleTrack
        client.playlistContainsResult = false
        client.playlists_returns = []  // forces createPlaylist on retry
        client.createPlaylistReturns = samplePlaylist
        client.addTrackBehavior = .failFirstThenSucceed(error: SpotifyClient.SpotifyError.api(status: 404, message: "Playlist not found"))

        let pipeline = makePipeline()
        await pipeline.process(makeSong())

        // After recovery: targetPlaylistID should be cleared (or replaced) and the second add should hit a fresh playlist.
        XCTAssertEqual(pipeline.caughtSongs[0].status, .added, "Expected pipeline to recover and record .added")
        XCTAssertEqual(client.addedTracks.count, 2, "Expected one failed + one successful addTrack")
        XCTAssertEqual(client.addedTracks.last?.0, samplePlaylist.id)
        XCTAssertEqual(settings.targetPlaylistID, samplePlaylist.id)
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
    var addTrackBehavior: AddTrackBehavior = .alwaysSucceed

    private(set) var addedTracks: [(String, String)] = []  // (playlistID, trackURI)
    private var addCallCount = 0

    func currentUser() async throws -> SpotifyUser { currentUserResult }
    func searchTrack(byISRC isrc: String) async throws -> SpotifyTrack? { searchByISRCResult }
    func searchTrack(name: String, artist: String) async throws -> SpotifyTrack? { searchByNameResult }
    func playlists(limit: Int, offset: Int) async throws -> [SpotifyPlaylist] {
        // Simulate paging: only return entries beyond `offset`. Tests using small fixture
        // sets just rely on the first page (offset == 0) being non-empty.
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
        addedTracks.append((playlistID, trackURI))
        switch addTrackBehavior {
        case .alwaysSucceed: return
        case .alwaysFail(let err): throw err
        case .failFirstThenSucceed(let err):
            if addCallCount == 1 { throw err }
        }
    }
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
        // Construct via JSON because Decodable-only types don't have memberwise inits.
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
