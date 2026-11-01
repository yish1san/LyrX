import Foundation
import SQLite3
import Darwin

enum AppleMusicCacheLookup: Sendable {
    case lyrics(LyricsResult)
    case unavailable(message: String, needsAccess: Bool)
    case busy
    case incompatible
}

/// 仅读取 Music 已缓存的歌词及曲目身份，不发请求，不访问响应头或账户信息。
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
            if let database, sqlite3_system_errno(database) == ENOENT {
                return .unavailable(message: "Music 尚未建立本地歌词缓存。可在 Music 中打开这首歌的歌词，LyrX 会继续读取。", needsAccess: false)
            }
            return .unavailable(message: "无法读取 Music 本地歌词，可选择缓存文件夹授权。", needsAccess: true)
        }
        sqlite3_busy_timeout(database, 25)
        // Music 正在使用的数据库只做短时读取；查询过慢就退出，稍后重试。
        let deadline = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
        deadline.initialize(to: ProcessInfo.processInfo.systemUptime + 0.25)
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
        }, deadline)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            deadline.deinitialize(count: 1); deadline.deallocate()
        }
        let sql = """
        WITH recent_lyrics AS (
            SELECT entry_ID FROM cfurl_cache_response WHERE request_key LIKE '%lyrics%'
            ORDER BY time_stamp DESC LIMIT 160
        ), recent_songs AS (
            SELECT entry_ID FROM cfurl_cache_response
            WHERE request_key LIKE '%/catalog/%/songs/%' AND request_key NOT LIKE '%lyrics%'
            ORDER BY time_stamp DESC LIMIT 80
        )
        SELECT d.isDataOnFS, d.receiver_data, r.request_key
        FROM cfurl_cache_response AS r JOIN cfurl_cache_receiver_data AS d USING(entry_ID)
        WHERE r.entry_ID IN (SELECT entry_ID FROM recent_lyrics UNION SELECT entry_ID FROM recent_songs)
        ORDER BY CASE WHEN r.request_key LIKE '%lyrics%' THEN 0 ELSE 1 END,
                 r.time_stamp DESC LIMIT 240
        """
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let cursor = statement else {
            if [SQLITE_BUSY, SQLITE_LOCKED].contains(prepared) {
                return .busy
            }
            return .incompatible
        }
        var payloads: [(onFile: Bool, data: Data, key: String)] = []
        var totalBytes = 0
        while ProcessInfo.processInfo.systemUptime < deadline.pointee, sqlite3_step(cursor) == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(cursor, 1))
            guard length > 0, length <= maximumBytes, let bytes = sqlite3_column_blob(cursor, 1) else { continue }
            totalBytes += length
            if totalBytes > 24 * 1024 * 1024 { break }
            let key = sqlite3_column_text(cursor, 2).map { String(cString: $0) } ?? ""
            payloads.append((sqlite3_column_int(cursor, 0) == 1, Data(bytes: bytes, count: length), key))
        }
        let readStatus = sqlite3_errcode(database)
        // 先释放查询游标，再读缓存文件和解析歌词，避免解析期间占住数据库读事务。
        sqlite3_finalize(cursor); statement = nil
        var responses: [(root: [String: Any], key: String)] = []
        totalBytes = 0
        let decodeDeadline = ProcessInfo.processInfo.systemUptime + 1
        for entry in payloads where ProcessInfo.processInfo.systemUptime < decodeDeadline {
            let payload = entry.data
            let data: Data
            if entry.onFile {
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
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            responses.append((root, entry.key))
        }
        let localizedTitle = Self.uniqueLocalizedTitle(in: responses.map(\.root), for: query)
        let catalogIDs = responses.reduce(into: Set<String>()) {
            $0.formUnion(Self.matchingCatalogIDs(in: $1.root, for: query, localizedTitle: localizedTitle))
        }
        var best: LyricsResult?
        for response in responses {
            guard ProcessInfo.processInfo.systemUptime < decodeDeadline else { break }
            if let result = Self.decode(response.root, for: query, languages: Locale.preferredLanguages,
                                        requestKey: response.key, catalogIDs: catalogIDs, localizedTitle: localizedTitle) {
                if result.isWordSynced { return .lyrics(result) }
                if best == nil || (best?.isPlain == true && !result.isPlain) { best = result }
            }
        }
        if let best { return .lyrics(best) }
        if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(readStatus) {
            return .busy
        }
        return .unavailable(message: "尚未读到这首歌的本地歌词。可在 Music 中打开一次歌词；缓存出现后会自动显示。", needsAccess: false)
    }

    static func decode(_ data: Data, for query: LyricsQuery, languages: [String] = Locale.preferredLanguages) -> LyricsResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(root, for: query, languages: languages, requestKey: "", catalogIDs: [],
                      localizedTitle: uniqueLocalizedTitle(in: [root], for: query))
    }

    private static func items(in root: [String: Any]) -> [[String: Any]] {
        (root["data"] as? [[String: Any]] ?? []) + (root["included"] as? [[String: Any]] ?? [])
    }
    private static func titleMatches(_ title: String, _ query: LyricsQuery) -> Bool {
        TextNormalizer.looselyEqual(title, query.track) || TextNormalizer.bilingualAliasMatches(title, query.track)
    }
    private static func uniqueLocalizedTitle(in roots: [[String: Any]], for query: LyricsQuery) -> String? {
        let titles = Set(roots.flatMap { items(in: $0) }.compactMap { item -> String? in
            guard let attributes = item["attributes"] as? [String: Any], identityMatches(attributes, query: query),
                  let title = attributes["name"] as? String, !titleMatches(title, query) else { return nil }
            return TextNormalizer.canonical(title)
        })
        return titles.count == 1 ? titles.first : nil
    }
    private static func identityMatches(_ attributes: [String: Any], query: LyricsQuery) -> Bool {
        guard let title = attributes["name"] as? String, let artist = attributes["artistName"] as? String,
              let milliseconds = attributes["durationInMillis"] as? Double,
              query.duration.isFinite, query.duration > 0, milliseconds > 0,
              abs(milliseconds / 1000 - query.duration) <= 3,
              TextNormalizer.versionsCompatible(title, query.track),
              TextNormalizer.artistsMatch(artist, query.artist) || TextNormalizer.bilingualAliasMatches(artist, query.artist) else { return false }
        if titleMatches(title, query) { return true }
        // 仅在艺人、专辑及精确时长同时吻合时，允许中英文标题本地化差异。
        guard LyricQuality.containsCJK(title) != LyricQuality.containsCJK(query.track),
              let album = attributes["albumName"] as? String, !query.album.isEmpty,
              TextNormalizer.looselyEqual(album, query.album),
              abs(milliseconds / 1000 - query.duration) <= 0.75 else { return false }
        return true
    }
    private static func matchingCatalogIDs(in root: [String: Any], for query: LyricsQuery, localizedTitle: String?) -> Set<String> {
        Set(items(in: root).compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any], identityMatches(attributes, query: query),
                  let title = attributes["name"] as? String,
                  titleMatches(title, query) || TextNormalizer.canonical(title) == localizedTitle,
                  let id = item["id"] as? String, !id.isEmpty else { return nil }
            return id
        })
    }
    private static func decode(_ root: [String: Any], for query: LyricsQuery, languages: [String],
                               requestKey: String, catalogIDs: Set<String>, localizedTitle: String?) -> LyricsResult? {
        var lyricEntries: [[String: Any]] = []
        for song in items(in: root) {
            guard let attributes = song["attributes"] as? [String: Any], identityMatches(attributes, query: query),
                  let title = attributes["name"] as? String,
                  titleMatches(title, query) || TextNormalizer.canonical(title) == localizedTitle else { continue }
            let relationships = song["relationships"] as? [String: Any] ?? [:]
            for key in ["syllable-lyrics", "lyrics"] {
                let relationship = relationships[key] as? [String: Any]
                lyricEntries += relationship?["data"] as? [[String: Any]] ?? []
            }
            // 一些缓存响应把 TTML 放在歌曲属性中。
            if attributes["ttmlLocalizations"] != nil || attributes["ttml"] != nil { lyricEntries.append(song) }
        }
        // 独立 /songs/<id>/lyrics 响应必须先由同批歌曲元数据确认身份，不能仅凭时间猜测。
        if let path = URLComponents(string: requestKey)?.percentEncodedPath.removingPercentEncoding,
           let range = path.range(of: #"/songs/([^/]+)/(?:syllable-lyrics|lyrics)/?$"#, options: .regularExpression) {
            let parts = path[range].split(separator: "/")
            if parts.count >= 3, catalogIDs.contains(String(parts[1])) {
                lyricEntries += root["data"] as? [[String: Any]] ?? []
            }
        }
        var best: LyricsResult?
        for entry in lyricEntries {
            guard let attributes = entry["attributes"] as? [String: Any] else { continue }
            for key in ["ttmlLocalizations", "ttml", "lyrics", "text"] {
                guard let value = attributes[key] else { continue }
                for text in lyricCandidates(value, languages: languages) {
                    guard let result = result(from: text, duration: query.duration) else { continue }
                    if result.isWordSynced { return result }
                    if best == nil || (best?.isPlain == true && !result.isPlain) { best = result }
                }
            }
        }
        return best
    }
    private static func result(from text: String, duration: Double) -> LyricsResult? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var lines: [LyricLine]
        var plain: String?
        if text.hasPrefix("<") {
            guard let document = TTMLParser.document(text) else { return nil }
            lines = document.lines
            if lines.isEmpty { plain = document.plainText }
        } else {
            lines = LRCParser.parse(text)
            if lines.isEmpty {
                // 不把损坏的时间标签当成静态歌词。
                guard text.range(of: #"\[\d+:"#, options: .regularExpression) == nil else { return nil }
                plain = text
            }
        }
        if let plain, !plain.isEmpty {
            return LyricsResult(lines: [LyricLine(time: 0, text: plain)], sourceID: "apple-cache", isWordSynced: false, isPlain: true)
        }
        guard !lines.isEmpty, duration > 0,
              lines.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= duration + 3 && ($0.endTime ?? $0.time) <= duration + 3 }) else { return nil }
        let timed = lines.flatMap { $0.words ?? [] }
        guard timed.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.end.isFinite && $0.end >= $0.start && $0.end <= duration + 3 }) else { return nil }
        return LyricsResult(lines: lines, sourceID: "apple-cache", isWordSynced: !timed.isEmpty)
    }

    private static func lyricCandidates(_ value: Any, languages: [String], depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        if let string = value as? String {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { return [string] }
            if let data = string.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data) {
                return lyricCandidates(nested, languages: languages, depth: depth + 1)
            }
            return [string]
        }
        guard let entries = value as? [String: Any], !entries.isEmpty else { return [] }
        for field in ["ttml", "text"] where entries[field] != nil {
            return lyricCandidates(entries[field]!, languages: languages, depth: depth + 1)
        }
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
        return ordered.prefix(8).flatMap { lyricCandidates(entries[$0]!, languages: languages, depth: depth + 1) }
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
