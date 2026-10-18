import Foundation
import CryptoKit

/// 用户修正独立于网络缓存，缓存过期不会覆盖手动歌词或校准。
@MainActor
final class TrackPreferences {
    struct Entry: Codable {
        var offset: Double = 0
        var lyrics: LyricsResult?
        var musicOffset: Double?
    }
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsOverlay/Tracks", isDirectory: true)
    }
    func entry(for key: String) -> Entry {
        guard let data = try? Data(contentsOf: url(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        return entry
    }
    func save(_ entry: Entry, for key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url(for: key), options: .atomic)
    }
    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}
