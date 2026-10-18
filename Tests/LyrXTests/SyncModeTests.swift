import XCTest
@testable import LyrX

final class MusicTimingParserTests: XCTestCase {
    func testUntimedPunctuationDoesNotDiscardAllWordTimestamps() throws {
        let lines = TTMLParser.parse("<tt><p begin='1s' end='4s'>（<span begin='1s' end='2s'>你</span>，<span begin='3s' end='4s'>好</span>！）</p></tt>")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.text, "（你，好！）")
        XCTAssertEqual(line.words?.map(\.text), ["你", "好"])
        let plan = LyricHighlightPlan(line: line, end: 4)
        XCTAssertEqual(plan.glyphs.first { $0.text == "你" }?.progress(at: 2.5), 1)
        XCTAssertEqual(plan.glyphs.first { $0.text == "好" }?.progress(at: 2.5), 0)
        XCTAssertEqual(plan.glyphs.map(\.text).joined(), line.text)
    }
    func testDurationAndStartOnlySpansKeepDeclaredBoundaries() throws {
        let line = try XCTUnwrap(TTMLParser.parse("<tt><p begin='1s' dur='5s'><span begin=' 1s ' dur='500ms'>A</span> <span begin='3s'>B</span><span begin='5s'>C</span></p></tt>").first)
        XCTAssertEqual(line.endTime, 6)
        XCTAssertEqual(line.words?.map(\.start), [1, 3, 5])
        XCTAssertEqual(line.words?.map(\.end), [1.5, 5, 6])
    }
    func testNestedWrappersDoNotReplaceIndividualWordTimesWithParentTime() throws {
        let line = try XCTUnwrap(TTMLParser.parse("<tt><p begin='1s' end='5s'><span begin='1s' end='5s'><span><span begin='1s' end='2s'>A</span><br/><span begin='4s' end='5s'>B</span></span></span></p></tt>").first)
        XCTAssertEqual(line.text, "A\nB")
        XCTAssertEqual(line.words?.map(\.start), [1, 4])
        XCTAssertEqual(line.words?.count, 2)
    }
    func testLineOnlyAndInvalidWordsAreNotClaimedAsNativeWords() throws {
        XCTAssertNil(TTMLParser.parse("<tt><p begin='1s' end='4s'>Only a line</p></tt>").first?.words)
        XCTAssertNil(TTMLParser.parse("<tt><p begin='1s' end='4s'><span begin='3s' end='2s'>Invalid</span></p></tt>").first?.words)
    }
}

@MainActor
final class MusicModeRecoveryTests: XCTestCase {
    private var directory: URL!
    private var store: LyricsStore!
    private var snapshot: MusicState!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LyricsStore(cache: LyricsCache(directory: directory), preferences: TrackPreferences(directory: directory.appendingPathComponent("Tracks")))
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        snapshot = MusicState(); snapshot.trackID = "one"; snapshot.title = "Test"
        snapshot.running = true; snapshot.playing = false; snapshot.position = 3; snapshot.duration = 100
        store.handle(snapshot)
    }
    override func tearDown() async throws {
        store.stop(); store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private var lineResult: LyricsResult {
        LyricsResult(lines: [LyricLine(time: 1, text: "ABCD", endTime: 5)], sourceID: "apple-cache", isWordSynced: false)
    }
    func testRetryAndPermissionFailureKeepLoadedLineLyricsUsable() {
        store.handleMusicCacheLookup(.lyrics(lineResult), trackID: "one")
        let lines = store.lines, index = store.currentIndex
        store.refreshLyrics()
        XCTAssertEqual(store.lines, lines)
        XCTAssertEqual(store.currentIndex, index)
        XCTAssertTrue(store.hasAppleTimedLyrics)
        store.handleMusicCacheLookup(.unavailable(message: "Need access", needsAccess: true), trackID: "one")
        XCTAssertEqual(store.lines, lines)
        XCTAssertTrue(store.musicCacheNeedsAccess)
        XCTAssertTrue(store.supportsProgressHighlight)
        XCTAssertEqual(store.overlayStatusText, "已暂停")
    }
    func testSameResultAfterRetryClearsAccessStateAndRestoresSessionCache() {
        store.handleMusicCacheLookup(.lyrics(lineResult), trackID: "one")
        store.refreshLyrics()
        store.handleMusicCacheLookup(.unavailable(message: "Need access", needsAccess: true), trackID: "one")
        store.handleMusicCacheLookup(.lyrics(lineResult), trackID: "one")
        XCTAssertFalse(store.musicCacheNeedsAccess)
        var other = snapshot!; other.trackID = "two"; store.handle(other)
        store.handle(snapshot)
        XCTAssertTrue(store.hasAppleTimedLyrics)
    }
    func testLineOnlyProgressIsAvailableAndAccuratelyDescribedAsEstimated() {
        store.handleMusicCacheLookup(.lyrics(lineResult), trackID: "one")
        XCTAssertFalse(store.wordSynced)
        XCTAssertTrue(store.supportsProgressHighlight)
        XCTAssertTrue(store.musicHighlightDescription(progress: true).contains("估算"))
        XCTAssertFalse(store.musicHighlightDescription(progress: true).contains("按 Apple Music 逐词时间"))
        let plan = LyricHighlightPlan(line: lineResult.lines[0], end: 5)
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 3) }, [1, 1, 0, 0])
    }
    func testModeCanBeChosenBeforeDataAndPersistsWithoutEnablingSyncOnLaunch() {
        let name = "LyrXTests.mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = OverlaySettings(defaults: defaults)
        settings.followMusicLyrics = true
        settings.karaoke = false
        XCTAssertTrue(store.musicHighlightDescription(progress: settings.karaoke).contains("整句"))
        settings.karaoke = true
        XCTAssertTrue(store.musicHighlightDescription(progress: settings.karaoke).contains("已选择逐字"))
        let next = OverlaySettings(defaults: defaults)
        XCTAssertTrue(next.karaoke)
        XCTAssertFalse(next.followMusicLyrics)
    }
}
