import XCTest
@testable import Shazam2Spotify

@MainActor
final class CaughtStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaughtStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("caught.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testEmptyLoadReturnsEmpty() {
        let store = CaughtStore(fileURL: fileURL)
        XCTAssertEqual(store.load(), [])
    }

    func testSaveThenLoadRoundtrip() {
        let store = CaughtStore(fileURL: fileURL)
        let entries = sampleEntries(count: 3)
        store.save(entries)
        XCTAssertEqual(store.load(), entries)
    }

    func testSaveTrimsToMaxEntries() {
        let store = CaughtStore(fileURL: fileURL, maxEntries: 5)
        let entries = sampleEntries(count: 10)
        store.save(entries)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 5)
        // Verify it kept the prefix (most-recent-first ordering preserved).
        XCTAssertEqual(loaded, Array(entries.prefix(5)))
    }

    func testClearRemovesFile() {
        let store = CaughtStore(fileURL: fileURL)
        store.save(sampleEntries(count: 2))
        XCTAssertFalse(store.load().isEmpty)
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptedFileLoadsAsEmpty() throws {
        try Data("not valid json".utf8).write(to: fileURL)
        let store = CaughtStore(fileURL: fileURL)
        XCTAssertEqual(store.load(), [])
    }

    // MARK: - helpers

    private func sampleEntries(count: Int) -> [CaughtEntry] {
        (0..<count).map { i in
            let song = RecognizedSong(
                title: "Song \(i)",
                artist: "Artist \(i)",
                isrc: "ISRC\(i)",
                recognizedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))
            )
            return CaughtEntry(song: song, track: nil, status: .added)
        }
    }
}
