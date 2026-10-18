import XCTest
import Combine
@testable import LyrX

final class LineBoundaryTests: XCTestCase {
    func testSchedulesActualNextBoundaryWithoutPollingQuantization() {
        let times = [0.0, 0.051, 0.117, 0.117, 1]
        XCTAssertEqual(LyricsStore.nextLineDelay(at: 0.05, times: times)!, 0.001, accuracy: 0.000001)
        XCTAssertEqual(LyricsStore.nextLineDelay(at: 0.051, times: times)!, 0.066, accuracy: 0.000001)
        XCTAssertEqual(LyricsStore.nextLineDelay(at: 0.117, times: times)!, 0.883, accuracy: 0.000001)
        XCTAssertEqual(LyricsStore.nextLineDelay(at: -0.2, times: times)!, 0.2, accuracy: 0.000001)
        XCTAssertNil(LyricsStore.nextLineDelay(at: 1, times: times))
        XCTAssertNil(LyricsStore.nextLineDelay(at: .nan, times: times))
        XCTAssertNil(LyricsStore.nextLineDelay(at: 0, times: []))
    }
}

@MainActor
final class NativePlaybackTimingTests: XCTestCase {
    private var directory: URL!
    private var preferences: TrackPreferences!
    private var store: LyricsStore!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        preferences = TrackPreferences(directory: directory.appendingPathComponent("Tracks"))
        store = LyricsStore(cache: LyricsCache(directory: directory), preferences: preferences)
        store.setAppleMusicSyncEnabled(true, startReaders: false)
    }
    override func tearDown() async throws {
        store.stop(); store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func state(_ id: String = "one", position: Double = 0, playing: Bool = false, at: Date = Date()) -> MusicState {
        var s = MusicState(); s.running = true; s.trackID = id; s.title = id
        s.position = position; s.duration = 100; s.playing = playing; s.polledAt = at
        return s
    }
    private func result(_ times: [Double] = [0, 1, 2]) -> LyricsResult {
        LyricsResult(lines: times.enumerated().map { LyricLine(time: $0.element, text: "Line \($0.offset)") }, sourceID: "apple-cache", isWordSynced: false)
    }
    func testNativeModeReportsMissingDataWithoutWaitingForAnyWindow() {
        store.handle(state())
        store.handleMusicCacheLookup(.unavailable(message: "No cached lyrics", needsAccess: false), trackID: "one")
        XCTAssertEqual(store.phase, .notFound)
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertEqual(store.currentSourceTitle, "暂无 Music 本地歌词")
        XCTAssertEqual(store.overlayStatusText, "暂无本地歌词")
        store.handleMusicCacheLookup(.lyrics(result()), trackID: "one")
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertEqual(store.overlayStatusText, "已暂停")
    }
    func testMusicCalibrationUses50msStepsAndDoesNotChangeAutomaticOffset() throws {
        try preferences.save(TrackPreferences.Entry(offset: 1.5), for: "one")
        store.handle(state(position: 0.95))
        store.handleMusicCacheLookup(.lyrics(result()), trackID: "one")
        XCTAssertEqual(store.timingOffset, 0)
        XCTAssertTrue(store.canCalibrate)
        XCTAssertEqual(store.currentIndex, 0)
        store.setTimingOffset(0.05)
        XCTAssertEqual(store.timingOffset, 0.05, accuracy: 0.000001)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(preferences.entry(for: "one").offset, 1.5)
        XCTAssertEqual(preferences.entry(for: "one").musicOffset, 0.05)
        store.setAppleMusicSyncEnabled(false, startReaders: false)
        XCTAssertEqual(store.timingOffset, 1.5)
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        XCTAssertEqual(store.timingOffset, 0.05)
        XCTAssertEqual(store.currentIndex, 1)
    }
    func testOldTrackPreferencesDecodeWithNoMusicOffsetAndBothPersist() throws {
        let old = Data("{\"offset\":0.75}".utf8)
        var entry = try JSONDecoder().decode(TrackPreferences.Entry.self, from: old)
        XCTAssertEqual(entry.offset, 0.75)
        XCTAssertNil(entry.musicOffset)
        entry.musicOffset = -0.15
        try preferences.save(entry, for: "one")
        let restored = preferences.entry(for: "one")
        XCTAssertEqual(restored.offset, 0.75)
        XCTAssertEqual(restored.musicOffset, -0.15)
    }
    func testPauseSeekAndCalibrationImmediatelyRecomputeBoundary() {
        let now = Date()
        store.handle(state(position: 0.95, playing: true, at: now))
        store.handleMusicCacheLookup(.lyrics(result()), trackID: "one")
        store.updateCurrentIndex(at: now.addingTimeInterval(0.051))
        XCTAssertEqual(store.currentIndex, 1)
        store.handle(state(position: 0.5, playing: false))
        store.updateCurrentIndex(at: Date().addingTimeInterval(20))
        XCTAssertEqual(store.currentIndex, 0)
        store.setTimingOffset(0.5)
        XCTAssertEqual(store.currentIndex, 1)
        store.handle(state(position: 2.5, playing: false))
        XCTAssertEqual(store.currentIndex, 2)
    }
    func testBoundaryTimerAdvancesWhileNoMusicPollArrives() async throws {
        store.start(preview: true)
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        store.handle(state(position: 0, playing: true))
        let advanced = expectation(description: "Crossed both lyric boundaries without a new playback snapshot")
        let subscription = store.$currentIndex.sink { index in if index == 2 { advanced.fulfill() } }
        store.handleMusicCacheLookup(.lyrics(result([0, 0.05, 0.12])), trackID: "one")
        await fulfillment(of: [advanced], timeout: 1)
        XCTAssertEqual(store.currentIndex, 2)
        withExtendedLifetime(subscription) {}
    }
    func testNativeSessionCacheAndTrackIsolationRemainIntact() {
        store.handle(state())
        store.handleMusicCacheLookup(.lyrics(result()), trackID: "one")
        store.handle(state("two"))
        store.handleMusicCacheLookup(.lyrics(result()), trackID: "one")
        XCTAssertTrue(store.lines.isEmpty)
        store.handle(state())
        XCTAssertTrue(store.hasAppleTimedLyrics)
        XCTAssertEqual(store.lines.count, 3)
    }
}
