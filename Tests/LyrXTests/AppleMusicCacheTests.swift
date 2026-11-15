import XCTest
import SQLite3
@testable import LyrX

final class AppleMusicCacheTests: XCTestCase {
    private let xml = """
    <tt:tt xmlns:tt="http://www.w3.org/ns/ttml"><tt:body><tt:div>
    <tt:p begin="1s" end="4s"><tt:span begin="1s" end="2s">你</tt:span><tt:span begin="3s" end="4s">好</tt:span></tt:p>
    </tt:div></tt:body></tt:tt>
    """
    private var query: LyricsQuery { LyricsQuery(track: "測試 Test", artist: "Test Artist", album: "Test Album", duration: 10) }
    private func response(ttml: Any, title: String = "测试 Test", artist: String = "Test Artist", duration: Int = 10_000) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": [[
            "attributes": ["name": title, "artistName": artist, "durationInMillis": duration],
            "relationships": ["syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": ttml]]]]]
        ]]])
    }
    func testNativeResponseHasRealWordTimesAndPreservesPauses() throws {
        let result = AppleMusicLyricsCache.decode(try response(ttml: ["zh-Hant": xml]), for: query, languages: ["zh-Hant"])
        XCTAssertEqual(result?.sourceID, "apple-cache")
        XCTAssertEqual(result?.isWordSynced, true)
        XCTAssertEqual(result?.lines.first?.text, "你好")
        XCTAssertEqual(result?.lines.first?.words?.map(\.start), [1, 3])
        XCTAssertEqual(result?.lines.first?.words?.map(\.end), [2, 4])
        let plan = LyricHighlightPlan(line: try XCTUnwrap(result?.lines.first), end: 4)
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 2.5) }, [1, 0])
    }
    func testRejectsWrongArtistVersionDurationAndOutOfTrackTimes() throws {
        XCTAssertNil(AppleMusicLyricsCache.decode(try response(ttml: xml, artist: "Someone Else"), for: query))
        XCTAssertNil(AppleMusicLyricsCache.decode(try response(ttml: xml, title: "测试 Test (Live)"), for: query))
        XCTAssertNil(AppleMusicLyricsCache.decode(try response(ttml: xml, duration: 20_000), for: query))
        XCTAssertNil(AppleMusicLyricsCache.decode(try response(ttml: xml.replacingOccurrences(of: "4s", with: "40s")), for: query))
    }
    func testRawAndEncodedLocalizationsAndMissingParagraphBegin() throws {
        let noBegin = xml.replacingOccurrences(of: "<tt:p begin=\"1s\"", with: "<tt:p")
        let raw = AppleMusicLyricsCache.decode(try response(ttml: noBegin), for: query)
        XCTAssertEqual(raw?.lines.first?.time, 1)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: ["zh-Hans": xml]), encoding: .utf8)!
        XCTAssertEqual(AppleMusicLyricsCache.decode(try response(ttml: encoded), for: query)?.isWordSynced, true)
        XCTAssertNil(AppleMusicLyricsCache.decode(Data("invalid".utf8), for: query))
    }
    func testTimedOriginalIsPreferredToLineOnlyTranslation() throws {
        let translation = "<tt><body><div><p begin=\"1s\" end=\"4s\">Test translation</p></div></body></tt>"
        let result = AppleMusicLyricsCache.decode(try response(ttml: ["zh-Hans": translation, "en": xml]), for: query, languages: ["zh-Hans"])
        XCTAssertEqual(result?.isWordSynced, true)
        XCTAssertEqual(result?.lines.first?.words?.map(\.start), [1, 3])
    }
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        return directory
    }
    private func database(_ directory: URL, rows: [(Int, Data)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Cache.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE cfurl_cache_response(entry_ID INTEGER, request_key TEXT, time_stamp REAL); CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER, isDataOnFS INTEGER, receiver_data BLOB);"
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let hex = row.1.map { String(format: "%02x", $0) }.joined()
            let sql = "INSERT INTO cfurl_cache_response VALUES(\(index), 'https://example.invalid/syllable-lyrics', \(index)); INSERT INTO cfurl_cache_receiver_data VALUES(\(index), \(row.0), X'\(hex)');"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }
    func testReadsInlineAndFileCacheWithoutModifyingDatabase() throws {
        for fileBacked in [false, true] {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let body = try response(ttml: xml)
            let payload: Data
            if fileBacked {
                let filename = UUID().uuidString
                try body.write(to: directory.appendingPathComponent("fsCachedData/" + filename))
                payload = Data(filename.utf8)
            } else { payload = body }
            try database(directory, rows: [(fileBacked ? 1 : 0, payload)])
            let dbURL = directory.appendingPathComponent("Cache.db")
            let before = try Data(contentsOf: dbURL)
            if case .lyrics(let result) = AppleMusicLyricsCache().lookup(query, directory: directory) {
                XCTAssertTrue(result.isWordSynced)
                XCTAssertEqual(result.lines.first?.text, "你好")
            } else { XCTFail("Expected cached word timing") }
            XCTAssertEqual(try Data(contentsOf: dbURL), before)
        }
    }
    func testRejectsFileTraversalAndUnavailableCacheFallsBack() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database(directory, rows: [(1, Data("../../unexpected".utf8))])
        if case .unavailable(_, let needsAccess) = AppleMusicLyricsCache().lookup(query, directory: directory) {
            XCTAssertFalse(needsAccess)
        } else { XCTFail("Invalid file path must not be read") }
        let missing = directory.appendingPathComponent("missing")
        if case .unavailable(_, let needsAccess) = AppleMusicLyricsCache().lookup(query, directory: missing) {
            XCTAssertFalse(needsAccess, "Missing cache is not an authorization failure")
        } else { XCTFail("Missing cache must report access state") }
    }
    func testBusyMusicCacheReturnsPromptlyWithoutAskingForAccessOrChangingIt() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database(directory, rows: [(0, try response(ttml: xml))])
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Cache.db").path, &writer), SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let started = ProcessInfo.processInfo.systemUptime
        let lookup = AppleMusicLyricsCache().lookup(query, directory: directory)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        if case .busy = lookup {} else { XCTFail("An exclusively locked cache must be retried later") }
    }
}

@MainActor
final class AppleMusicCacheStoreTests: XCTestCase {
    func testNativeCacheEnablesWordHighlightAndRejectsStaleTrackResults() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricsStore(cache: LyricsCache(directory: directory), preferences: TrackPreferences(directory: directory.appendingPathComponent("Tracks")))
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        var state = MusicState(); state.running = true; state.trackID = "one"; state.title = "Test"; state.position = 1.5; state.duration = 10
        store.handle(state)
        let line = LyricLine(time: 1, text: "AB", endTime: 3, words: [LyricWord(text: "A", start: 1, end: 2), LyricWord(text: "B", start: 2, end: 3)])
        store.handleMusicCacheLookup(.lyrics(LyricsResult(lines: [line], sourceID: "apple-cache", isWordSynced: true)), trackID: "one")
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertTrue(store.supportsProgressHighlight)
        XCTAssertTrue(store.wordSynced)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.lines, [line])
        state.trackID = "two"; store.handle(state)
        store.handleMusicCacheLookup(.lyrics(LyricsResult(lines: [line], sourceID: "apple-cache", isWordSynced: true)), trackID: "one")
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertFalse(store.hasAppleTimedLyrics)
        store.stop()
    }
    func testLineOnlyCacheAllowsEstimatedProgressWithoutClaimingNativeWords() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricsStore(cache: LyricsCache(directory: directory), preferences: TrackPreferences(directory: directory.appendingPathComponent("Tracks")))
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        var state = MusicState(); state.trackID = "one"; state.title = "Test"; state.duration = 10
        store.handle(state)
        store.handleMusicCacheLookup(.unavailable(message: "access required", needsAccess: true), trackID: "one")
        XCTAssertTrue(store.musicCacheNeedsAccess)
        XCTAssertFalse(store.supportsProgressHighlight)
        XCTAssertTrue(store.lines.isEmpty)
        let result = LyricsResult(lines: [LyricLine(time: 1, text: "Native line")], sourceID: "apple-cache", isWordSynced: false)
        store.handleMusicCacheLookup(.lyrics(result), trackID: "one")
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertTrue(store.supportsProgressHighlight)
        XCTAssertFalse(store.wordSynced)
        XCTAssertTrue(store.musicHighlightDescription(progress: true).contains("估算"))
        store.stop()
    }
}

final class LocalizedMusicCacheTests: XCTestCase {
    private let xml = "<tt><body><div><p begin=\"1s\" end=\"4s\">缓存兼容测试</p></div></body></tt>"
    private func song(title: String, artist: String, album: String, id: String = "song-1", duration: Int = 240_000) -> [String: Any] {
        ["id": id, "type": "songs", "attributes": ["name": title, "artistName": artist, "albumName": album, "durationInMillis": duration],
         "relationships": ["lyrics": ["data": [["id": "lyric-1", "type": "lyrics", "attributes": ["ttml": xml]]]]]]
    }
    private func decode(_ root: [String: Any], query: LyricsQuery) throws -> LyricsResult? {
        AppleMusicLyricsCache.decode(try JSONSerialization.data(withJSONObject: root), for: query)
    }
    func testLocalizedArtistRequiresMatchingTitleAlbumAndExactDuration() throws {
        for (title, cachedArtist, queriedArtist, album) in [("爱错", "王力宏", "Leehom Wang", "心中的日月"),
                                                           ("走走", "李榮浩", "Ronghao Li", "黑馬"),
                                                           ("Payphone", "Maroon 5", "魔力红乐队", "Overexposed")] {
            let query = LyricsQuery(track: title, artist: queriedArtist, album: album, duration: 240)
            XCTAssertNotNil(try decode(["data": [song(title: title, artist: cachedArtist, album: album)]], query: query))
            XCTAssertNil(try decode(["data": [song(title: title, artist: cachedArtist, album: "Other Album")]], query: query))
            XCTAssertNil(try decode(["data": [song(title: title, artist: cachedArtist, album: album, duration: 242_000)]], query: query))
            XCTAssertNil(try decode(["data": [song(title: title + " (Live)", artist: cachedArtist, album: album)]], query: query))
        }
    }
    func testAmbiguousLocalizedArtistsAreRejected() throws {
        let query = LyricsQuery(track: "Payphone", artist: "魔力红乐队", album: "Overexposed", duration: 240)
        let root: [String: Any] = ["data": [song(title: "Payphone", artist: "Maroon 5", album: "Overexposed"),
                                                  song(title: "Payphone", artist: "Another Band", album: "Overexposed", id: "song-2")]]
        XCTAssertNil(try decode(root, query: query))
    }
    func testAlbumTracksAndLibraryCatalogRelationshipsAreTraversed() throws {
        let query = LyricsQuery(track: "愛錯", artist: "王力宏", album: "心中的日月", duration: 240)
        let resource = song(title: "爱错", artist: "王力宏", album: "心中的日月")
        for relationship in ["tracks", "catalog"] {
            let root: [String: Any] = ["data": ["id": "parent", "relationships": [relationship: ["data": [resource]]]]]
            XCTAssertEqual(try decode(root, query: query)?.lines.first?.text, "缓存兼容测试")
        }
    }
    func testIncludedLyricsReferencesResolveWithoutReadingUnrelatedLyrics() throws {
        let query = LyricsQuery(track: "Payphone", artist: "Maroon 5", album: "Overexposed", duration: 240)
        var resource = song(title: query.track, artist: query.artist, album: query.album)
        resource["relationships"] = ["lyrics": ["data": [["id": "chosen", "type": "lyrics"]]]]
        let included: [[String: Any]] = [
            ["id": "other", "type": "lyrics", "attributes": ["ttml": "<tt><body><p>wrong</p></body></tt>"]],
            ["id": "chosen", "type": "lyrics", "attributes": ["ttmlLocalizations": [["ttml": xml]]]]]
        XCTAssertEqual(try decode(["data": [resource], "included": included], query: query)?.lines.first?.text, "缓存兼容测试")
        resource["relationships"] = ["lyrics": ["data": [["id": "missing", "type": "lyrics"]]]]
        XCTAssertNil(try decode(["data": [resource], "included": included], query: query))
    }
    func testNestedAlbumMetadataBindsStandaloneLyricsByCatalogID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Cache.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cfurl_cache_response(entry_ID INTEGER, request_key TEXT, time_stamp REAL); CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER, isDataOnFS INTEGER, receiver_data BLOB);", nil, nil, nil), SQLITE_OK)
        var metadata = song(title: "Payphone", artist: "Maroon 5", album: "Overexposed", id: "123")
        metadata.removeValue(forKey: "relationships")
        let rows: [(String, [String: Any])] = [
            ("https://example.invalid/v1/catalog/us/albums/456?include=tracks", ["data": [["relationships": ["tracks": ["data": [metadata]]]]]]),
            ("https://example.invalid/v1/catalog/us/songs/123/lyrics", ["data": [["attributes": ["ttml": xml]]]])]
        for (i, row) in rows.enumerated() {
            let bytes = try JSONSerialization.data(withJSONObject: row.1).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO cfurl_cache_response VALUES(\(i), '\(row.0)', \(i)); INSERT INTO cfurl_cache_receiver_data VALUES(\(i), 0, X'\(bytes)');", nil, nil, nil), SQLITE_OK)
        }
        let query = LyricsQuery(track: "Payphone", artist: "魔力红乐队", album: "Overexposed", duration: 240)
        if case .lyrics(let result) = AppleMusicLyricsCache().lookup(query, directory: directory) {
            XCTAssertEqual(result.lines.first?.text, "缓存兼容测试")
        } else { XCTFail("Nested catalog metadata must identify the standalone lyric response") }
    }
}
