import XCTest
import AppKit
@testable import LyrX

final class LyricsTests: XCTestCase {
    func testLRCOffsetAndMultipleTimestamps() {
        let lines = LRCParser.parse("[offset:-500]\n[00:02.50][00:04.000]Hello\n[00:99.00]Invalid")
        XCTAssertEqual(lines.map(\.time), [2, 3.5])
        XCTAssertEqual(lines.map(\.text), ["Hello", "Hello"])
    }
    func testTranslationsShareOneTimestampWithoutDuplicates() {
        let lines = LRCParser.parse("[00:01]Hello\n[00:01]你好\n[00:01]Hello\n[00:00]作词：某人")
        XCTAssertEqual(lines, [LyricLine(time: 1, text: "Hello\n你好")])
    }
    func testTitleMatchingRejectsSubstringsButAllowsDualTitles() {
        XCTAssertFalse(TextNormalizer.looselyEqual("爱", "爱情"))
        XCTAssertFalse(TextNormalizer.looselyEqual("Love", "Love Story"))
        XCTAssertTrue(TextNormalizer.looselyEqual("花田错 | Mistake in the Flower Field", "Mistake in the Flower Field"))
        XCTAssertTrue(TextNormalizer.looselyEqual("ＤＲＥＡＭ", "dream"))
        XCTAssertFalse(TextNormalizer.looselyEqual("Song (Part Two)", "Song"))
    }
    func testTraditionalAndSimplifiedTitlesPreserveVersionIdentity() {
        XCTAssertTrue(TextNormalizer.looselyEqual("淺粉紅 pale pink", "浅粉红 pale pink"))
        XCTAssertTrue(TextNormalizer.looselyEqual("淺粉紅 baby pink", "浅粉红baby pink"))
        XCTAssertFalse(TextNormalizer.looselyEqual("淺粉紅 pale pink", "浅粉红 baby pink"))
        XCTAssertTrue(TextNormalizer.bilingualAliasMatches("淺粉紅 pale pink", "pale pink"))
        XCTAssertFalse(TextNormalizer.bilingualAliasMatches("淺粉紅 pale pink", "baby pink"))
        let pale = candidate("pale pink", "Gareth.T", 202)
        let baby = candidate("baby pink", "Gareth.T", 232)
        XCTAssertEqual(LyricsService.pickBest([baby, pale], track: "淺粉紅 pale pink", artist: "Gareth.T", album: "淺粉紅", duration: 201.816)?.trackName, "pale pink")
        XCTAssertEqual(LyricsService.pickBest([pale, baby], track: "淺粉紅 baby pink", artist: "Gareth.T", album: "淺粉紅", duration: 232.319)?.trackName, "baby pink")
        XCTAssertNil(LyricsService.pickBest([pale], track: "淺粉紅 pale pink", artist: "Another Artist", album: "", duration: 202))
        XCTAssertNil(LyricsService.pickBest([pale], track: "淺粉紅 pale pink", artist: "Gareth.T", album: "", duration: 232))
    }
    func testArtistAndVersionMatching() {
        XCTAssertFalse(TextNormalizer.artistsMatch("王力", "王力宏"))
        XCTAssertFalse(TextNormalizer.artistsMatch("Someone", ""))
        XCTAssertTrue(TextNormalizer.artistsMatch("Artist A feat. Artist B", "Artist B"))
        XCTAssertFalse(TextNormalizer.versionsCompatible("Song (Live)", "Song"))
        XCTAssertFalse(TextNormalizer.versionsCompatible("Song - Remix", "Song (Acoustic)"))
        XCTAssertTrue(TextNormalizer.versionsCompatible("Song - Remastered", "Song"))
        XCTAssertTrue(TextNormalizer.versionsCompatible("Live Forever", "Live Forever"))
    }
    func testSameArtistAndDurationCannotAdmitDifferentSong() {
        let wrong = candidate("Other Song", "Artist", 180)
        XCTAssertNil(LyricsService.pickBest([wrong], track: "My Song", artist: "Artist", album: "Album", duration: 180))
    }
    func testRejectCoverAndWrongDurationEvenWhenAlbumMatches() {
        let cover = candidate("My Song", "Cover Artist", 180)
        let long = candidate("My Song", "Artist", 240)
        XCTAssertNil(LyricsService.pickBest([cover, long], track: "My Song", artist: "Artist", album: "Album", duration: 180))
    }
    func testRejectLiveVersionAndPreferCorrectAlbum() {
        let live = candidate("My Song (Live)", "Artist", 180)
        let studio = candidate("My Song", "Artist", 181)
        let result = LyricsService.pickBest([live, studio], track: "My Song", artist: "Artist", album: "Album", duration: 180)
        XCTAssertEqual(result?.trackName, "My Song")
    }
    private func candidate(_ title: String, _ artist: String, _ duration: Double) -> LRCLibResponse {
        LRCLibResponse(trackName: title, artistName: artist, albumName: "Album", duration: duration,
                       syncedLyrics: "[00:01]Test", plainLyrics: nil)
    }
    func testTTMLParsesReorderedAttributesEntitiesAndExcludesTranslations() {
        let xml = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p end="00:05" begin="00:01"><span end="2s" begin="1s">You &amp; I</span> <span begin="2s" end="5s">sing</span><span ttm:role="x-translation">你和我唱歌</span></p>
        </div></body></tt>
        """
        let lines = TTMLParser.parse(xml)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "You & I sing")
        XCTAssertEqual(lines.first?.endTime, 5)
        XCTAssertEqual(lines.first?.words?.map(\.text), ["You & I ", "sing"])
        XCTAssertTrue(TTMLParser.parse("<tt><p begin='1s'>broken").isEmpty)
    }
    func testNestedTTMLDoesNotDuplicateTimedWords() {
        let lines = TTMLParser.parse("<tt><p begin='1s' end='3s'><span begin='1s' end='3s'><span begin='1s' end='2s'>你</span><span begin='2s' end='3s'>好</span></span></p></tt>")
        XCTAssertEqual(lines.first?.words?.count, 2)
        XCTAssertEqual(lines.first?.text, "你好")
    }
    func testArtworkRejectsInvalidOrOversizedData() {
        XCTAssertNil(MusicArtwork.thumbnailData(from: Data("not an image".utf8)))
        XCTAssertNil(MusicArtwork.thumbnailData(from: Data(repeating: 0, count: 20_000_001)))
    }
    func testArtworkScriptCompilesWithoutReadingMusic() {
        let script = NSAppleScript(source: MusicArtwork.scriptSource)
        var error: NSDictionary?
        XCTAssertTrue(script?.compileAndReturnError(&error) == true)
        XCTAssertNil(error)
    }
    func testWordTimingsInYRC() {
        XCTAssertEqual(YRCParser.parse("[1000,2000](1000,500,0)你(1500,1500,0)好").first?.words?.last?.end, 3)
    }
    func testClockFreezesWhenPausedAndAppliesOffset() {
        let clock = PlaybackClock(), date = Date(timeIntervalSince1970: 100)
        clock.update(position: 10, duration: 15, playing: true, at: date)
        XCTAssertEqual(clock.position(at: date.addingTimeInterval(20)), 15)
        clock.update(position: 10, duration: 15, playing: false, at: date)
        clock.offset = -0.5
        XCTAssertEqual(clock.lyricPosition(at: date.addingTimeInterval(5)), 9.5)
    }

    func testConcurrentSourcesDoNotWaitForSlowProvider() async throws {
        let result = LyricsResult(lines: [LyricLine(time: 1, text: "Hello")], sourceID: "fast", isWordSynced: false)
        let orchestrator = LyricsOrchestrator(sources: [StubSource(id: "slow", delay: 5_000_000_000, result: nil), StubSource(id: "fast", delay: 1_000_000, result: result)])
        let start = Date()
        let outcome = try await orchestrator.fetch(LyricsQuery(track: "Song", artist: "Artist", album: "", duration: 180))
        XCTAssertEqual(outcome.result?.sourceID, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testOriginalPlainLyricsWinOverRomanizedSyncedFallback() async throws {
        let plain = LyricsResult(lines: [LyricLine(time: 0, text: "原文歌词")], sourceID: "plain", isWordSynced: false, isPlain: true)
        let romanized = LyricsResult(lines: [LyricLine(time: 0, text: "yuan wen")], sourceID: "romanized", isWordSynced: false)
        let outcome = try await LyricsOrchestrator(sources: [StubSource(id: "plain", delay: 0, result: plain), StubSource(id: "romanized", delay: 0, result: romanized)])
            .fetch(LyricsQuery(track: "歌曲", artist: "歌手", album: "", duration: 180))
        XCTAssertEqual(outcome.result?.sourceID, "plain")
        XCTAssertFalse(outcome.isRomanizedFallback)
    }
    func testCacheInvalidationRemovesPositiveAndNegativeEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsCache(directory: directory)
        await cache.storeNotFound(for: "one")
        let negative = await cache.entry(for: "one")
        XCTAssertEqual(negative?.negative, true)
        await cache.remove(for: "one")
        let removed = await cache.entry(for: "one")
        XCTAssertNil(removed)
        let result = LyricsResult(lines: [LyricLine(time: 0, text: "Hello")], sourceID: "test", isWordSynced: false)
        await cache.store(result: result, note: nil, for: "two")
        let secondCache = LyricsCache(directory: directory)
        let disk = await secondCache.entry(for: "two")
        XCTAssertEqual(disk?.result?.lines, result.lines)
    }
}

private struct StubSource: LyricsSource {
    let id: String
    let delay: UInt64
    let result: LyricsResult?
    var isEnabled: Bool { true }
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return result
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private var directory: URL!
    private var cache: LyricsCache!
    private var preferences: TrackPreferences!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = LyricsCache(directory: directory.appendingPathComponent("Cache"))
        preferences = TrackPreferences(directory: directory.appendingPathComponent("Tracks"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func snapshot(_ id: String = "song", position: Double = 0) -> MusicState {
        var snapshot = MusicState()
        snapshot.running = true; snapshot.trackID = id; snapshot.title = id
        snapshot.artist = "Artist"; snapshot.position = position; snapshot.duration = 200
        return snapshot
    }
    func testBinarySearchAndSeekingBackwards() {
        XCTAssertEqual(LyricsStore.lineIndex(at: -1, times: [0, 10, 20]), -1)
        XCTAssertEqual(LyricsStore.lineIndex(at: 10, times: [0, 10, 20]), 1)
        XCTAssertEqual(LyricsStore.lineIndex(at: 5, times: [0, 10, 20]), 0)
        XCTAssertEqual(LyricsStore.lineIndex(at: 999, times: []), -1)
    }
    func testLocalImportOffsetAndPersistence() throws {
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot(position: 9))
        store.importLyrics("[00:10]Hello\n[00:20]World")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.currentIndex, -1)
        store.setTimingOffset(1)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(preferences.entry(for: "song").offset, 1)
        let second = LyricsStore(cache: cache, preferences: preferences)
        second.handle(snapshot(position: 19))
        XCTAssertEqual(second.sourceID, "local")
        XCTAssertEqual(second.currentIndex, 1)
        second.stop(); store.stop()
    }
    func testSongSwitchResetsOffsetAndLyrics() throws {
        try preferences.save(TrackPreferences.Entry(offset: 2, lyrics: LyricsResult(lines: [LyricLine(time: 1, text: "One")], sourceID: "local", isWordSynced: false)), for: "one")
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot("one"))
        XCTAssertEqual(store.timingOffset, 2)
        store.handle(snapshot("two"))
        XCTAssertEqual(store.timingOffset, 0)
        XCTAssertTrue(store.lines.isEmpty)
        store.stop()
    }
    func testPermissionFailurePreservesLastTrustedTrackThenRecovers() {
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot())
        store.importLyrics("[00:01]Hello")
        var bad = MusicState(); bad.scriptError = "Denied (-1743)"
        store.handle(bad)
        XCTAssertEqual(store.title, "song")
        XCTAssertNotNil(store.connectionError)
        store.handle(snapshot(position: 2))
        XCTAssertNil(store.connectionError)
        XCTAssertEqual(store.currentIndex, 0)
        store.stop()
    }
    func testInvalidImportDoesNotReplaceExistingLyrics() {
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot())
        store.importLyrics("[00:01]Hello")
        store.importLyrics("[00:99]Invalid")
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(store.lines.first?.text, "Hello")
        store.stop()
    }
    func testNegativeCacheShowsNotFoundAndCanBeOverriddenLocally() async {
        await cache.storeNotFound(for: "song")
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot())
        for _ in 0..<100 {
            if store.phase == .notFound { break }
            await Task.yield()
        }
        XCTAssertEqual(store.phase, .notFound)
        store.importLyrics("[00:01]Local correction")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.sourceID, "local")
        store.stop()
    }
    func testPreviewSettingsDoNotReadOrWriteStoredPreferences() {
        let name = "LyricsOverlayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(28, forKey: "overlay.fontSize")
        let settings = OverlaySettings(defaults: defaults, temporary: true)
        XCTAssertEqual(settings.fontSize, 20)
        settings.fontSize = 16
        XCTAssertEqual(defaults.double(forKey: "overlay.fontSize"), 28)
        settings.compact = true
        XCTAssertEqual(settings.windowHeight, settings.rowHeight * 2 + 16)
    }
    func testMusicSyncStartsOffEachSessionWithoutChangingOtherSavedSettings() {
        let name = "LyrXTests.session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "overlay.followMusicLyrics")
        defaults.set(24, forKey: "overlay.fontSize")
        let settings = OverlaySettings(defaults: defaults)
        XCTAssertFalse(settings.followMusicLyrics)
        XCTAssertEqual(settings.fontSize, 24)
        var changes = 0
        settings.onLyricsSourceChange = { changes += 1 }
        settings.followMusicLyrics = true
        XCTAssertTrue(settings.followMusicLyrics)
        XCTAssertEqual(changes, 1)
        let nextSession = OverlaySettings(defaults: defaults)
        XCTAssertFalse(nextSession.followMusicLyrics)
        XCTAssertEqual(nextSession.fontSize, 24)
    }
    func testSwitchingMusicOffRestoresImportedLyricsAndOffsetWithoutDeletingThem() {
        let store = LyricsStore(cache: cache, preferences: preferences)
        store.handle(snapshot("one"))
        store.importLyrics("[00:01]My import")
        store.setTimingOffset(1.5)
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        XCTAssertEqual(store.sourceID, "apple-cache")
        store.importLyrics("[00:01]Must not replace")
        XCTAssertNotNil(store.actionError)
        store.refreshLyrics()
        XCTAssertEqual(preferences.entry(for: "one").lyrics?.lines.first?.text, "My import")
        store.handleMusicCacheLookup(.lyrics(LyricsResult(lines: [LyricLine(time: 0, text: "Music")], sourceID: "apple-cache", isWordSynced: false)), trackID: "one")
        XCTAssertEqual(store.lines.first?.text, "Music")
        store.setAppleMusicSyncEnabled(false, startReaders: false)
        XCTAssertEqual(store.sourceID, "local")
        XCTAssertEqual(store.lines.first?.text, "My import")
        XCTAssertEqual(store.timingOffset, 1.5)
        XCTAssertTrue(store.canCalibrate)
        store.stop()
    }
    func testEmbeddedMusicLyricsWorkWithoutExternalProvider() async {
        await cache.storeNotFound(for: "song")
        let store = LyricsStore(cache: cache, preferences: preferences)
        var state = snapshot(); state.embeddedLyrics = "Local music metadata lyric"
        store.handle(state)
        for _ in 0..<100 { if store.phase == .ready { break }; await Task.yield() }
        XCTAssertEqual(store.sourceID, "apple-library")
        XCTAssertEqual(store.plainLyrics, "Local music metadata lyric")
        store.stop()
    }
    func testTransparentThemeAndLyricsOnlySize() {
        let settings = OverlaySettings(temporary: true)
        let regularHeight = settings.windowHeight
        settings.compact = true
        XCTAssertLessThan(settings.windowHeight, regularHeight - 100)
        XCTAssertLessThan(settings.minimumWindowHeight, settings.windowHeight)
        settings.appearance = .transparent
        XCTAssertTrue(settings.isTransparent)
        XCTAssertEqual(settings.appearance.colorScheme, .dark)
        settings.clickThrough = true
        XCTAssertTrue(settings.isTransparent)
        XCTAssertTrue(settings.clickThrough)
    }
    func testArtworkFollowsTrackAndClearsWhenMissing() {
        let store = LyricsStore(cache: cache, preferences: preferences)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); image.unlockFocus()
        let data = MusicArtwork.thumbnailData(from: image.tiffRepresentation!)
        XCTAssertNotNil(data)
        var first = snapshot("one"); first.artworkData = data
        store.handle(first)
        XCTAssertNotNil(store.artwork)
        let sameImage = store.artwork
        store.handle(first)
        XCTAssertTrue(store.artwork === sameImage)
        store.handle(snapshot("two"))
        XCTAssertNil(store.artwork)
        store.stop()
    }
    func testSettingsClampInvalidPersistedValues() {
        let name = "LyricsOverlayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(100, forKey: "overlay.visibleLines")
        defaults.set(-2, forKey: "overlay.backgroundOpacity")
        defaults.set(200, forKey: "overlay.fontSize")
        let settings = OverlaySettings(defaults: defaults)
        XCTAssertEqual(settings.visibleLines, 7)
        XCTAssertEqual(settings.fontSize, 28)
        XCTAssertEqual(settings.backgroundOpacity, 0)
    }
}
