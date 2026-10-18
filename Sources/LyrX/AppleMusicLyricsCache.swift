import Foundation
import SQLite3

enum AppleMusicCacheLookup: Sendable {
    case lyrics(LyricsResult)
    case unavailable(message: String, needsAccess: Bool)
}

/// 仅读取 Music 已缓存的 syllable-lyrics 响应，不发请求，不访问响应头或账户信息。
/// 缓存结构参考：https://github.com/Takpap/apple-music-lyrics（MIT）。
struct AppleMusicLyricsCache: Sendable {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
    }
    private let maximumBytes = 8 * 1024 * 1024

    func lookup(_ query: LyricsQuery, directory: URL = Self.defaultDirectory) -> AppleMusicCacheLookup {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        var database: OpaquePointer?
        let code = sqlite3_open_v2(directory.appendingPathComponent("Cache.db").path, &database,
                                   SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard code == SQLITE_OK, let database else {
            return .unavailable(message: "无法读取 Music 本地歌词，可选择缓存文件夹授权。", needsAccess: true)
        }
        sqlite3_busy_timeout(database, 150)
        let sql = """
        SELECT d.isDataOnFS, d.receiver_data
        FROM cfurl_cache_response AS r JOIN cfurl_cache_receiver_data AS d USING(entry_ID)
        WHERE r.request_key LIKE '%syllable-lyrics%'
        ORDER BY r.time_stamp DESC LIMIT 80
        """
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .unavailable(message: "当前 Music 缓存格式暂不兼容，可关闭 Music 同步使用自动匹配。", needsAccess: false)
        }
        var totalBytes = 0
        var lineOnly: LyricsResult?
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, sqlite3_step(statement) == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, length <= maximumBytes, let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let payload = Data(bytes: bytes, count: length)
            let data: Data
            if sqlite3_column_int(statement, 0) == 1 {
                guard let name = String(data: payload, encoding: .utf8), UUID(uuidString: name) != nil else { continue }
                let allowed = directory.appendingPathComponent("fsCachedData", isDirectory: true).resolvingSymlinksInPath()
                let file = allowed.appendingPathComponent(name).resolvingSymlinksInPath()
                guard file.deletingLastPathComponent() == allowed,
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= maximumBytes, let body = try? Data(contentsOf: file) else { continue }
                data = body
            } else { data = payload }
            totalBytes += data.count
            if totalBytes > 24 * 1024 * 1024 { break }
            if let result = Self.decode(data, for: query) {
                if result.isWordSynced { return .lyrics(result) }
                if lineOnly == nil { lineOnly = result }
            }
        }
        if let lineOnly { return .lyrics(lineOnly) }
        return .unavailable(message: "尚无这首歌的逐词缓存，请在 Music 展开歌词后重试。", needsAccess: false)
    }

    static func decode(_ data: Data, for query: LyricsQuery, languages: [String] = Locale.preferredLanguages) -> LyricsResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = root["data"] as? [[String: Any]] else { return nil }
        var lineOnly: LyricsResult?
        for song in songs {
            guard let attributes = song["attributes"] as? [String: Any],
                  let title = attributes["name"] as? String, let artist = attributes["artistName"] as? String,
                  TextNormalizer.versionsCompatible(title, query.track),
                  TextNormalizer.looselyEqual(title, query.track) || TextNormalizer.bilingualAliasMatches(title, query.track),
                  TextNormalizer.artistsMatch(artist, query.artist),
                  let milliseconds = attributes["durationInMillis"] as? Double,
                  query.duration > 0, milliseconds > 0, abs(milliseconds / 1000 - query.duration) <= 3,
                  let relationships = song["relationships"] as? [String: Any],
                  let lyrics = relationships["syllable-lyrics"] as? [String: Any],
                  let entries = lyrics["data"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let lyricAttributes = entry["attributes"] as? [String: Any],
                      let value = lyricAttributes["ttmlLocalizations"] else { continue }
              for xml in ttmlCandidates(value, languages: languages) {
                let lines = TTMLParser.parse(xml)
                guard !lines.isEmpty, lines.allSatisfy({ $0.time >= 0 && $0.time <= query.duration + 3 && ($0.endTime ?? $0.time) <= query.duration + 3 }) else { continue }
                let timed = lines.flatMap { $0.words ?? [] }
                guard timed.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start && $0.end <= query.duration + 3 }) else { continue }
                let result = LyricsResult(lines: lines, sourceID: "apple-cache", isWordSynced: !timed.isEmpty)
                if result.isWordSynced { return result }
                if lineOnly == nil { lineOnly = result }
              }
            }
        }
        return lineOnly
    }

    private static func ttmlCandidates(_ value: Any, languages: [String], depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        if let string = value as? String {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { return [string] }
            guard let data = string.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data) else { return [] }
            return ttmlCandidates(nested, languages: languages, depth: depth + 1)
        }
        guard let entries = value as? [String: String], !entries.isEmpty else { return [] }
        let keys = entries.keys.sorted().filter {
            !$0.lowercased().contains("latn") && !$0.lowercased().contains("roman")
        }
        var ordered: [String] = []
        for language in languages.map({ $0.replacingOccurrences(of: "_", with: "-").lowercased() }) {
            if let exact = keys.first(where: { $0.lowercased() == language }), !ordered.contains(exact) { ordered.append(exact) }
            for related in keys where related.lowercased().split(separator: "-").first == language.split(separator: "-").first && !ordered.contains(related) { ordered.append(related) }
        }
        ordered += keys.filter { !ordered.contains($0) }
        if ordered.isEmpty { ordered = entries.keys.sorted() }
        return ordered.prefix(8).compactMap { entries[$0] }
    }
}

enum MusicLyricsCacheLocation {
    private static let key = "music.lyricsCacheBookmark"
    static func restored() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale))
    }
    static func save(_ url: URL) throws {
        let data: Data
        do { data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(data, forKey: key)
    }
}
