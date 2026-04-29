import Foundation

@MainActor
final class CaughtStore {
    private let url: URL
    private let maxEntries: Int

    init(fileURL: URL? = nil, maxEntries: Int = 200) {
        if let fileURL {
            self.url = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("caught-songs.json")
        }
        self.maxEntries = maxEntries
    }

    func load() -> [CaughtEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([CaughtEntry].self, from: data)) ?? []
    }

    func save(_ entries: [CaughtEntry]) {
        let trimmed = Array(entries.prefix(maxEntries))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
