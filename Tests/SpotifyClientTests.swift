import XCTest
@testable import Shazam2Spotify

@MainActor
final class SpotifyClientTests: XCTestCase {
    private var session: URLSession!
    private var tokenProvider: MockTokenProvider!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        tokenProvider = MockTokenProvider()
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Auth header

    func testAddsBearerHeader() async throws {
        tokenProvider.tokenToReturn = "abc123"
        MockURLProtocol.enqueue(status: 200, body: #"{"id":"u","display_name":"User"}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        _ = try await client.currentUser()

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
    }

    // MARK: - Search ISRC

    func testSearchByISRCReturnsFirstMatch() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 200, body: """
        {"tracks":{"items":[{"id":"t1","uri":"spotify:track:t1","name":"Hi","artists":[{"id":"a","name":"Anon"}]}]}}
        """)
        let client = SpotifyClient(auth: tokenProvider, session: session)
        let track = try await client.searchTrack(byISRC: "USRC17607839")
        XCTAssertEqual(track?.uri, "spotify:track:t1")
        XCTAssertTrue(MockURLProtocol.lastRequest?.url?.query?.contains("q=isrc:USRC17607839") == true
                      || MockURLProtocol.lastRequest?.url?.query?.contains("isrc%3AUSRC17607839") == true)
    }

    // MARK: - Retry policy

    func testRefreshOn401AndRetry() async throws {
        tokenProvider.tokenToReturn = "stale"
        // First response: 401. Second response: 200.
        MockURLProtocol.enqueue(status: 401, body: #"{"error":{"status":401,"message":"expired"}}"#)
        MockURLProtocol.enqueue(status: 200, body: #"{"id":"u","display_name":"OK"}"#)
        tokenProvider.refreshSwapsTokenTo = "fresh"

        let client = SpotifyClient(auth: tokenProvider, session: session)
        let user = try await client.currentUser()
        XCTAssertEqual(user.id, "u")
        XCTAssertEqual(tokenProvider.callCount, 2, "Expected one initial + one forced refresh")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "Expected initial 401 + retry")
        XCTAssertEqual(MockURLProtocol.allRequests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testRetryAfterOn429() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 429, body: "", headers: ["Retry-After": "0"])
        MockURLProtocol.enqueue(status: 200, body: #"{"id":"u","display_name":"OK"}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        let user = try await client.currentUser()
        XCTAssertEqual(user.id, "u")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testNoRetryOn500ForPOST() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 500, body: #"{"error":{"status":500,"message":"down"}}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        do {
            _ = try await client.createPlaylist(userID: "u", name: "p", description: "")
            XCTFail("Expected throw")
        } catch let e as SpotifyClient.SpotifyError {
            XCTAssertEqual(e.statusCode, 500)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "POSTs must NOT retry on 5xx")
    }

    func testRetryOn500ForGET() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 503, body: "")
        MockURLProtocol.enqueue(status: 200, body: #"{"id":"u","display_name":"OK"}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        let user = try await client.currentUser()
        XCTAssertEqual(user.id, "u")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    // MARK: - Error parsing

    func testParsesSpotifyErrorEnvelope() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 404, body: #"{"error":{"status":404,"message":"playlist gone"}}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        do {
            try await client.addTrack(playlistID: "p", trackURI: "spotify:track:x")
            XCTFail("Expected throw")
        } catch let e as SpotifyClient.SpotifyError {
            XCTAssertEqual(e.statusCode, 404)
            XCTAssertEqual(e.errorDescription, "playlist gone")
        }
    }

    func testRetainsExtraStatusCodeForCallerInspection() async throws {
        tokenProvider.tokenToReturn = "tok"
        MockURLProtocol.enqueue(status: 403, body: #"{"error":{"status":403,"message":"User not registered in development mode"}}"#)

        let client = SpotifyClient(auth: tokenProvider, session: session)
        do {
            _ = try await client.currentUser()
            XCTFail()
        } catch {
            XCTAssertEqual(error.spotifyStatus, 403)
            // The user-facing message gets a friendlier translation for dev-mode users.
            XCTAssertTrue(error.localizedDescription.contains("User Management"))
        }
    }
}

// MARK: - Test doubles

@MainActor
final class MockTokenProvider: TokenProviding {
    var tokenToReturn: String = "test-token"
    var refreshSwapsTokenTo: String?
    private(set) var callCount = 0

    func validAccessToken(forceRefresh: Bool) async throws -> String {
        callCount += 1
        if forceRefresh, let next = refreshSwapsTokenTo {
            tokenToReturn = next
        }
        return tokenToReturn
    }
}

/// Lightweight mock URL protocol that returns canned responses in FIFO order.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let body: Data; let headers: [String: String] }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private(set) static var allRequests: [URLRequest] = []

    static var lastRequest: URLRequest? { allRequests.last }
    static var requestCount: Int { allRequests.count }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
        allRequests.removeAll()
    }

    static func enqueue(status: Int, body: String, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        queue.append(.init(status: status, body: Data(body.utf8), headers: headers))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.allRequests.append(request)
        let resp = Self.queue.isEmpty
            ? Response(status: 500, body: Data("{}".utf8), headers: [:])
            : Self.queue.removeFirst()
        Self.lock.unlock()

        let url = request.url ?? URL(string: "about:blank")!
        let httpResp = HTTPURLResponse(
            url: url,
            statusCode: resp.status,
            httpVersion: "HTTP/1.1",
            headerFields: resp.headers
        )!
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resp.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
