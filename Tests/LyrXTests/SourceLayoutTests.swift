import XCTest
import AppKit
@testable import LyrX

private actor Requests {
    var choices: [TrackLyricsSource] = []
    func record(_ choice: TrackLyricsSource) { choices.append(choice) }
}

@MainActor
final class SourceRoutingTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func state(_ id: String = "one") -> MusicState {
        var s = MusicState(); s.running = true; s.playing = true; s.trackID = id
        s.title = id; s.artist = "Artist"; s.duration = 240; s.position = 12
        return s
    }
    private func timed(_ source: String = "netease") -> LyricsResult {
        LyricsResult(lines: [LyricLine(time: 1, text: "第一句"), LyricLine(time: 20, text: "第二句")], sourceID: source, isWordSynced: false)
    }
    private func make(_ lookup: @escaping @Sendable (LyricsQuery, TrackLyricsSource) async throws -> LyricsResult?) -> LyricsStore {
        LyricsStore(cache: LyricsCache(directory: directory.appendingPathComponent("Cache")),
                    preferences: TrackPreferences(directory: directory.appendingPathComponent("Tracks")), externalLookup: lookup)
    }
    private func settle() async throws { for _ in 0..<30 { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) } }
    func testPreviewSourceSelectionDoesNotContactProviders() async throws {
        let requests = Requests()
        let store = make { _, choice in await requests.record(choice); return nil }
        defer { store.stop() }
        store.start(preview: true)
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.setTrackSource(.netease)
        try await settle(); let count = await requests.choices.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(TrackPreferences(directory: directory.appendingPathComponent("Tracks")).entry(for: "preview").source, .followDefault)
    }
    func testFallbackIsOptInAndWaitsThroughTransientMiss() async throws {
        let requests = Requests(), result = timed()
        let store = make { _, choice in await requests.record(choice); return result }
        defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: false, startReaders: false)
        store.handle(state())
        store.handleMusicCacheLookup(.unavailable(message: "missing", needsAccess: false), trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 20)
        try await settle()
        var count = await requests.choices.count; XCTAssertEqual(count, 0)
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handleMusicCacheLookup(.unavailable(message: "loading", needsAccess: false), trackID: "one")
        try await settle(); count = await requests.choices.count; XCTAssertEqual(count, 0)
        store.handleMusicCacheLookup(.unavailable(message: "missing", needsAccess: false), trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 20)
        try await settle()
        XCTAssertEqual(store.sourceID, "netease"); XCTAssertTrue(store.appleMusicSyncEnabled)
        XCTAssertTrue(store.fallbackActive); XCTAssertTrue(store.canCalibrate); XCTAssertTrue(store.supportsProgressHighlight)
        XCTAssertEqual(store.currentSourceTitle, "网易云音乐")
        // Continued cache misses must not restart requests or hide the ready fallback.
        store.handleMusicCacheLookup(.busy, trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 30)
        store.handleMusicCacheLookup(.unavailable(message: "missing", needsAccess: false), trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 40)
        try await settle(); count = await requests.choices.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(store.phase, .ready)
        store.handleMusicCacheLookup(.lyrics(timed("apple-cache")), trackID: "one")
        XCTAssertEqual(store.currentSourceTitle, "Apple Music"); XCTAssertFalse(store.fallbackActive)
    }
    func testStaticMusicFallsBackButKeepsOriginalIfNoTimedAlternative() async throws {
        let staticMusic = LyricsResult(lines: [LyricLine(time: 0, text: "静态原文")], sourceID: "apple-cache", isWordSynced: false, isPlain: true)
        let otherPlain = LyricsResult(lines: [LyricLine(time: 0, text: "其他静态")], sourceID: "lrclib", isWordSynced: false, isPlain: true)
        let store = make { _, _ in otherPlain }; defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state()); store.handleMusicCacheLookup(.lyrics(staticMusic), trackID: "one")
        try await settle()
        XCTAssertEqual(store.plainLyrics, "静态原文"); XCTAssertEqual(store.currentSourceTitle, "Apple Music")
    }
    func testZeroTimestampDocumentIsStaticAndTriggersFallback() async throws {
        let result = timed()
        let store = make { _, _ in result }; defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state())
        store.handleMusicCacheLookup(.lyrics(LyricsResult(lines: [LyricLine(time: 0, text: "第一句"), LyricLine(time: 0, text: "第二句")], sourceID: "apple-cache", isWordSynced: false)), trackID: "one")
        try await settle()
        XCTAssertEqual(store.sourceID, "netease"); XCTAssertTrue(store.synced)
    }
    func testTimedMusicAndLongLyricsNeverTriggerFallback() async throws {
        let requests = Requests()
        let store = make { _, choice in await requests.record(choice); return nil }; defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state())
        store.handleMusicCacheLookup(.lyrics(LyricsResult(lines: [LyricLine(time: 1, text: String(repeating: "很长的歌词", count: 100))], sourceID: "apple-cache", isWordSynced: false)), trackID: "one")
        store.handleMusicCacheLookup(.unavailable(message: "temporarily missing", needsAccess: false), trackID: "one", atUptime: ProcessInfo.processInfo.systemUptime + 20)
        try await settle(); let count = await requests.choices.count
        XCTAssertEqual(count, 0); XCTAssertEqual(store.phase, .ready)
    }
    func testManualProviderIsSavedAndOverridesGlobalSettings() async throws {
        let requests = Requests(), result = timed("lrclib")
        let store = make { _, choice in await requests.record(choice); return result }; defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state()); store.setTrackSource(.lrclib); try await settle()
        XCTAssertEqual(store.sourceID, "lrclib"); XCTAssertFalse(store.appleMusicSyncEnabled)
        let preferences = TrackPreferences(directory: directory.appendingPathComponent("Tracks"))
        XCTAssertEqual(preferences.entry(for: "one").source, .lrclib)
        store.configureSources(preferMusic: false, automaticFallback: false, startReaders: false)
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        try await settle(); XCTAssertFalse(store.appleMusicSyncEnabled)
        store.handle(state("two")); XCTAssertTrue(store.appleMusicSyncEnabled)
        store.handle(state()); try await settle(); XCTAssertFalse(store.appleMusicSyncEnabled)
        let restarted = make { _, _ in result }; defer { restarted.stop() }
        restarted.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        restarted.handle(state()); try await settle()
        XCTAssertEqual(restarted.selectedTrackSource, .lrclib)
        XCTAssertEqual(restarted.sourceID, "lrclib")
        restarted.setTrackSource(.followDefault)
        XCTAssertTrue(restarted.appleMusicSyncEnabled)
    }
    func testExplicitAppleMusicDisablesFallbackEvenOnFailure() async throws {
        let requests = Requests()
        let store = make { _, choice in await requests.record(choice); return nil }; defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state()); store.setTrackSource(.appleMusic)
        store.handleMusicCacheLookup(.incompatible, trackID: "one")
        try await settle(); let count = await requests.choices.count
        XCTAssertEqual(count, 0); XCTAssertFalse(store.fallbackActive)
    }
    func testLateFallbackCannotReplaceRecoveredMusicOrAnotherSong() async throws {
        let result = timed()
        let store = make { _, _ in try? await Task.sleep(nanoseconds: 100_000_000); return result }
        defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state()); store.handleMusicCacheLookup(.incompatible, trackID: "one")
        await Task.yield()
        store.handleMusicCacheLookup(.lyrics(timed("apple-cache")), trackID: "one")
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertEqual(store.sourceID, "apple-cache")
        store.handle(state("two")); store.handleMusicCacheLookup(.incompatible, trackID: "two")
        await Task.yield(); store.handle(state("three"))
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertTrue(store.lines.isEmpty); XCTAssertFalse(store.fallbackActive)
    }
    func testFallbackCalibrationRemainsSeparateFromMusic() async throws {
        let result = timed()
        let store = make { _, _ in result }
        defer { store.stop() }
        store.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        store.handle(state()); store.handleMusicCacheLookup(.lyrics(timed("apple-cache")), trackID: "one")
        store.setTimingOffset(0.7)
        store.handle(state("two")); store.handle(state())
        // A fresh store has no session snapshot; force a failure before archive lookup.
        let fallback = make { _, _ in result }; defer { fallback.stop() }
        fallback.configureSources(preferMusic: true, automaticFallback: true, startReaders: false)
        fallback.handle(state()); fallback.handleMusicCacheLookup(.incompatible, trackID: "one")
        try await settle(); fallback.setTimingOffset(-0.4)
        fallback.handleMusicCacheLookup(.lyrics(timed("apple-cache")), trackID: "one")
        XCTAssertEqual(fallback.timingOffset, 0.7, accuracy: 0.001)
        let entry = TrackPreferences(directory: directory.appendingPathComponent("Tracks")).entry(for: "one")
        XCTAssertEqual(entry.offset, -0.4); XCTAssertEqual(entry.musicOffset, 0.7)
    }
}

@MainActor
final class ViewportSettingsTests: XCTestCase {
    func testCompactCountsAndNewPreferencesSurviveRestart() {
        let name = "LyrX.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = OverlaySettings(defaults: defaults)
        XCTAssertFalse(settings.automaticSourceFallback)
        XCTAssertEqual(settings.compactLines, 2)
        settings.compact = true; settings.compactLines = 5; settings.automaticSourceFallback = true; settings.autoFitWidth = false
        let restored = OverlaySettings(defaults: defaults)
        XCTAssertEqual(restored.compactLines, 5); XCTAssertTrue(restored.automaticSourceFallback); XCTAssertFalse(restored.autoFitWidth)
        for count in 1...7 {
            settings.compactLines = count
            XCTAssertEqual(settings.windowHeight, settings.rowHeight * CGFloat(count) + 16)
            if count % 2 == 1 { XCTAssertEqual(LyricViewport.focusedRow(lines: count), count / 2) }
        }
    }
    func testWidthNeverExceedsMaximumAndDoesNotConfuseStaticLyrics() {
        let lines = [LyricLine(time: 1, text: String(repeating: "长歌词", count: 100))]
        XCTAssertEqual(LyricViewport.requiredWidth(lines: lines, font: .systemFont(ofSize: 28), minimum: 480, maximum: 1000), 1000)
        XCTAssertEqual(LyricViewport.requiredWidth(lines: lines, font: .systemFont(ofSize: 28), minimum: 480, maximum: 800), 800)
        XCTAssertEqual(LyricViewport.requiredWidth(lines: [], font: .systemFont(ofSize: 20), minimum: 480, maximum: 1000), 480)
        XCTAssertEqual(CompactLyricText.scrollProgress(position: 1, start: 1, end: 10), 0)
        XCTAssertEqual(CompactLyricText.scrollProgress(position: 10, start: 1, end: 10), 1)
        XCTAssertGreaterThan(CompactLyricText.scrollProgress(position: 5, start: 1, end: 10), 0)
    }
    func testResetOriginPreservesArbitraryWindowSize() {
        let panel = OverlayPanel(contentRect: NSRect(x: -200, y: -400, width: 740, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.setSizeLimits(minimum: NSSize(width: 380, height: 94))
        let oldSize = panel.frame.size
        panel.setFrameOrigin(LyricViewport.resetOrigin(size: oldSize, screen: NSRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertEqual(panel.frame.size, oldSize); XCTAssertEqual(panel.frame.origin, NSPoint(x: 350, y: 72))
        panel.orderOut(nil)
    }
}
