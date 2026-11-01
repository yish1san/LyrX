import XCTest
import SQLite3
@testable import LyrX

final class NativeLyricsCompatibilityTests: XCTestCase {
    private let query = LyricsQuery(track: "Test", artist: "Test Artist", album: "Test Album", duration: 20)
    private let timed = "<tt><body><p begin='3s' end='6s'><span begin='3s' end='4s'>One</span> <span begin='5s' end='6s'>two</span></p></body></tt>"
    private let plain = "<tt><body><div><p>First test line</p><p>Second test line</p></div></body></tt>"
    private func song(_ lyrics: String?, relation: String = "lyrics", title: String = "Test", artist: String = "Test Artist",
                      album: String = "Test Album", duration: Double = 20_000, id: String = "123") -> [String: Any] {
        var value: [String: Any] = ["id": id, "type": "songs", "attributes": ["name": title, "artistName": artist,
            "albumName": album, "durationInMillis": duration]]
        if let lyrics {
            value["relationships"] = [relation: ["data": [["type": relation, "attributes": ["ttml": lyrics]]]]]
        }
        return value
    }
    private func body(_ songs: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": songs]) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func database(_ directory: URL, responses: [(String, Data)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Cache.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp REAL); CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER, isDataOnFS INTEGER, receiver_data BLOB);", nil, nil, nil), SQLITE_OK)
        for (index, response) in responses.enumerated() {
            let key = response.0.replacingOccurrences(of: "'", with: "''")
            let hex = response.1.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO cfurl_cache_response VALUES(\(index), '\(key)', \(index)); INSERT INTO cfurl_cache_receiver_data VALUES(\(index), 0, X'\(hex)');", nil, nil, nil), SQLITE_OK)
        }
    }
    func testRegularLyricsRelationshipSupportsTimedAndStaticDocuments() throws {
        let line = try XCTUnwrap(AppleMusicLyricsCache.decode(try body([song(timed)]), for: query))
        XCTAssertTrue(line.isWordSynced)
        XCTAssertEqual(line.lines.first?.time, 3)
        let staticResult = try XCTUnwrap(AppleMusicLyricsCache.decode(try body([song(plain)]), for: query))
        XCTAssertTrue(staticResult.isPlain)
        XCTAssertFalse(staticResult.isWordSynced)
        XCTAssertEqual(staticResult.lines.map(\.text).joined(), "First test line\nSecond test line")
    }
    func testWordTimingWinsEvenWhenStaticTranslationIsListedFirst() throws {
        var candidate = song(plain)
        candidate["relationships"] = [
            "lyrics": ["data": [["attributes": ["ttmlLocalizations": ["zh-Hans": plain]]]]],
            "syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": ["en": ["ttml": timed]]]]]]
        ]
        let result = try XCTUnwrap(AppleMusicLyricsCache.decode(try body([candidate]), for: query))
        XCTAssertFalse(result.isPlain)
        XCTAssertTrue(result.isWordSynced)
        XCTAssertEqual(result.lines.first?.words?.map(\.start), [3, 5])
    }
    func testBilingualParenthesesAndFeaturedTitleMetadataCanMatch() throws {
        for (title, stored, artist) in [("爱错 (Wrong Love)", "Wrong Love", "王力宏"),
                                        ("走走（Wander）", "Wander", "李荣浩"),
                                        ("Payphone (feat. Wiz Khalifa)", "Payphone", "Maroon 5")] {
            let q = LyricsQuery(track: title, artist: artist, album: "Test Album", duration: 20)
            XCTAssertNotNil(AppleMusicLyricsCache.decode(try body([song(timed, title: stored, artist: artist)]), for: q), title)
        }
    }
    func testTranslatedTitleNeedsArtistAlbumExactDurationAndAnUnambiguousCandidate() throws {
        let q = LyricsQuery(track: "Wrong Love", artist: "Test Artist", album: "Test Album", duration: 20)
        XCTAssertNotNil(AppleMusicLyricsCache.decode(try body([song(timed, title: "愛錯")]), for: q))
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song(timed, title: "愛錯", album: "Different Album")]), for: q))
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song(timed, title: "愛錯", duration: 22_000)]), for: q))
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song(timed, title: "愛錯", artist: "Other Artist")]), for: q))
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song(timed, title: "愛錯"), song(timed, title: "其他歌曲", id: "456")]), for: q))
    }
    func testStandaloneLyricsAreBoundToVerifiedSongIDAndDatabaseStaysUnchanged() throws {
        for verified in [true, false] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let raw = try JSONSerialization.data(withJSONObject: ["data": [["type": "lyrics", "attributes": ["ttml": plain]]]])
            try database(dir, responses: [
                ("https://example.invalid/v1/catalog/us/songs/123", try body([song(nil, id: verified ? "123" : "999")])),
                ("https://example.invalid/v1/catalog/us/songs/123/lyrics", raw)
            ])
            let db = dir.appendingPathComponent("Cache.db"), before = try Data(contentsOf: db)
            if case .lyrics(let result) = AppleMusicLyricsCache().lookup(query, directory: dir) {
                XCTAssertTrue(verified, "Unverified response must not be used")
                XCTAssertTrue(result.isPlain)
            } else { XCTAssertFalse(verified, "Verified standalone lyrics must remain available") }
            XCTAssertEqual(try Data(contentsOf: db), before)
        }
    }
    func testOlderLyricResponseIsFoundBeyondPreviousEightyRowLimit() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var responses = [("https://example.invalid/v1/catalog/us/songs/123/lyrics", try body([song(timed)]))]
        for index in 0..<100 {
            responses.append(("https://example.invalid/syllable-lyrics/\(index)", try body([song(timed, title: "Other \(index)")])))
        }
        try database(dir, responses: responses)
        if case .lyrics(let result) = AppleMusicLyricsCache().lookup(query, directory: dir) {
            XCTAssertTrue(result.isWordSynced)
        } else { XCTFail("Recent unrelated lyrics must not hide this song's available response") }
    }
    func testMalformedTimingIsNotPresentedAsAStaticLyric() throws {
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song("<tt><p>Broken")]), for: query))
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song("[00:75]Broken time")]), for: query))
        let outsideTrack = timed.replacingOccurrences(of: "6s", with: "60s")
        XCTAssertNil(AppleMusicLyricsCache.decode(try body([song(outsideTrack)]), for: query))
    }
}

final class MusicReadRecoveryTests: XCTestCase {
    func testStartupAndShortInterruptionsAreRetriedBeforeDisplayingAnError() {
        var recovery = MusicReadRecovery()
        XCTAssertFalse(recovery.failed(code: -1728, at: 100).showError)
        XCTAssertFalse(recovery.failed(code: -1712, at: 102).showError)
        XCTAssertTrue(recovery.failed(code: -1712, at: 107).showError)
        recovery.recovered()
        XCTAssertFalse(recovery.failed(code: -1728, at: 120).showError)
    }
    func testDeniedAutomationPermissionIsReportedImmediately() {
        var recovery = MusicReadRecovery()
        XCTAssertTrue(recovery.failed(code: -1743, at: 100).showError)
    }
    func testIntroDotsFollowTheLyricClockWhenPausedCalibratedOrSeekingBackwards() {
        let clock = PlaybackClock()
        let date = Date(timeIntervalSince1970: 1000)
        clock.update(position: 3, duration: 30, playing: false, at: date)
        XCTAssertEqual((0..<3).map { LyricIntroProgress.dot($0, at: clock.lyricPosition(at: date.addingTimeInterval(20)), end: 9) }, [1, 0, 0])
        clock.offset = 1.5
        XCTAssertEqual(LyricIntroProgress.dot(1, at: clock.lyricPosition(at: date), end: 9), 0.5)
        clock.offset = 0
        clock.update(position: 1.5, duration: 30, playing: false, at: date)
        XCTAssertEqual((0..<3).map { LyricIntroProgress.dot($0, at: clock.lyricPosition(at: date), end: 9) }, [0.5, 0, 0])
        XCTAssertEqual(LyricIntroProgress.dot(2, at: 9, end: 9), 1)
        XCTAssertEqual(LyricIntroProgress.dot(0, at: .nan, end: 9), 0)
    }
}

@MainActor
final class NativeLyricsRecoveryTests: XCTestCase {
    private var directory: URL!
    private var cache: LyricsCache!
    private var store: LyricsStore!
    private var snapshot: MusicState {
        var s = MusicState(); s.running = true; s.trackID = "one"; s.title = "Test"
        s.artist = "Test Artist"; s.duration = 20; s.position = 4
        return s
    }
    private var words: LyricsResult {
        LyricsResult(lines: [LyricLine(time: 3, text: "One", endTime: 6,
            words: [LyricWord(text: "One", start: 3, end: 6)])], sourceID: "apple-cache", isWordSynced: true)
    }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = LyricsCache(directory: directory)
        store = makeStore()
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        store.handle(snapshot)
    }
    override func tearDown() async throws {
        store.stop(); store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeStore(reader: @escaping @Sendable (LyricsQuery, URL) -> AppleMusicCacheLookup = { _, _ in .busy }) -> LyricsStore {
        LyricsStore(cache: cache, preferences: TrackPreferences(directory: directory.appendingPathComponent("Tracks")), musicCacheLookup: reader)
    }
    private func waitForRead(_ target: LyricsStore) async throws {
        for _ in 0..<200 {
            if !target.musicCacheChecking { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Offline lyric read did not complete")
    }
    func testBriefReadFailureDoesNotReplaceValidLyricsOrFreezeTheirClock() {
        store.handleMusicCacheLookup(.lyrics(words), trackID: "one")
        let revision = store.clock.revision
        var pending = snapshot; pending.readPending = true
        store.handle(pending)
        XCTAssertNil(store.connectionError)
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertEqual(store.clock.revision, revision)
        store.handle(snapshot)
        XCTAssertFalse(store.connecting)
        XCTAssertEqual(store.lines, words.lines)
    }
    func testBusyCacheDoesNotBecomeAnAuthorizationErrorOrAnAbsentLyric() {
        store.handleMusicCacheLookup(.busy, trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 30)
        XCTAssertEqual(store.phase, .loading)
        XCTAssertFalse(store.musicCacheNeedsAccess)
        XCTAssertTrue(store.musicCacheHint.contains("自动重试"))
        store.handleMusicCacheLookup(.lyrics(words), trackID: "one")
        store.handleMusicCacheLookup(.busy, trackID: "one")
        XCTAssertTrue(store.hasAppleTimedLyrics)
    }
    func testUnsupportedCacheFormatHasAnHonestFailureState() {
        store.handleMusicCacheLookup(.incompatible, trackID: "one")
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.currentSourceTitle, "Apple Music")
        XCTAssertFalse(store.musicCacheNeedsAccess)
        XCTAssertTrue(store.musicCacheHint.contains("格式"))
    }
    func testStaticNativeLyricsCanUpgradeWithoutBeingDowngradedAgain() {
        let plain = LyricsResult(lines: [LyricLine(time: 0, text: "Static test lyric")], sourceID: "apple-cache", isWordSynced: false, isPlain: true)
        store.handleMusicCacheLookup(.lyrics(plain), trackID: "one")
        XCTAssertEqual(store.plainLyrics, "Static test lyric")
        XCTAssertEqual(store.currentSourceTitle, "Apple Music")
        XCTAssertTrue(store.hasAppleLyrics)
        XCTAssertFalse(store.canCalibrate)
        XCTAssertFalse(store.supportsProgressHighlight)
        store.handleMusicCacheLookup(.lyrics(words), trackID: "one")
        store.handleMusicCacheLookup(.lyrics(plain), trackID: "one")
        XCTAssertNil(store.plainLyrics)
        XCTAssertEqual(store.lines, words.lines)
        XCTAssertTrue(store.supportsProgressHighlight)
    }
    func testEmbeddedAppleLyricsRemainUsableWhenNoScrollingCacheIsAvailable() {
        var state = snapshot; state.embeddedLyrics = "Embedded test lyric"
        store.handle(state)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.sourceID, "apple-library")
        XCTAssertEqual(store.plainLyrics, "Embedded test lyric")
        XCTAssertEqual(store.overlayStatusText, "静态歌词")
        store.handleMusicCacheLookup(.unavailable(message: "Not cached", needsAccess: false), trackID: "one")
        XCTAssertEqual(store.plainLyrics, "Embedded test lyric")
    }
    func testConfirmedNativeLyricsPersistAndReloadEvenAfterMusicEvictsItsCache() async throws {
        store.handleMusicCacheLookup(.lyrics(words), trackID: "one")
        let key = try XCTUnwrap(LyricsStore.musicArchiveKey(for: snapshot))
        for _ in 0..<200 {
            if await cache.entry(for: key)?.result != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        store.stop()
        cache = LyricsCache(directory: directory)
        store = makeStore(reader: { _, _ in .unavailable(message: "Evicted", needsAccess: false) })
        store.setAppleMusicSyncEnabled(true)
        store.handle(snapshot)
        try await waitForRead(store)
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertEqual(store.lines, words.lines)
    }
    func testSameTitleWithDifferentDurationDoesNotReuseAnotherRecording() {
        store.handleMusicCacheLookup(.lyrics(words), trackID: "one")
        var longer = snapshot; longer.duration = 40
        XCTAssertNotEqual(LyricsStore.musicArchiveKey(for: snapshot), LyricsStore.musicArchiveKey(for: longer))
        store.handle(longer)
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertEqual(store.phase, .loading)
    }
    func testRapidTrackSwitchDiscardsACompletedReadForThePreviousSong() async throws {
        store.stop()
        let old = words
        store = makeStore(reader: { q, _ in
            if q.track == "Test" { Thread.sleep(forTimeInterval: 0.1); return .lyrics(old) }
            return .lyrics(LyricsResult(lines: [LyricLine(time: 0, text: "Second song")], sourceID: "apple-cache", isWordSynced: false))
        })
        store.setAppleMusicSyncEnabled(true)
        store.handle(snapshot)
        try await Task.sleep(nanoseconds: 20_000_000)
        var other = snapshot; other.trackID = "two"; other.title = "Second"
        store.handle(other)
        try await waitForRead(store)
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertEqual(store.title, "Second")
        XCTAssertEqual(store.lines.map(\.text), ["Second song"])
    }
}
