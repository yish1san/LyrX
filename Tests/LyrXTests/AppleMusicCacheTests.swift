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
            XCTAssertTrue(needsAccess)
        } else { XCTFail("Missing cache must report access state") }
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
