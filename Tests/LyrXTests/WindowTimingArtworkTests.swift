import AppKit
import SwiftUI
import XCTest
@testable import LyrX

@MainActor
final class OverlayWindowSizingTests: XCTestCase {
    func testActualPanelCannotCollapseEvenIfAppKitMinimumIsOverwritten() {
        _ = NSApplication.shared
        let panel = OverlayPanel(contentRect: NSRect(x: 100, y: 100, width: 480, height: 317),
                                 styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setSizeLimits(minimum: NSSize(width: 380, height: 220))
        // 模拟宿主视图重新计算系统约束；自己的限制仍须有效。
        panel.minSize = .zero; panel.contentMinSize = .zero
        panel.setFrame(NSRect(x: 100, y: 100, width: 1, height: 1), display: false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 380, height: 220))
        panel.setFrame(NSRect(x: 100, y: 100, width: 1, height: 1), display: false, animate: false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 380, height: 220))
        panel.setContentSize(.zero)
        XCTAssertGreaterThanOrEqual(panel.frame.width, 380)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 220)
    }
    func testCompactAndFullModeKeepEnoughHeightAtEverySupportedFontSize() {
        let settings = OverlaySettings(temporary: true)
        for size in [14.0, 20, 28] {
            settings.fontSize = size
            settings.compact = false
            XCTAssertGreaterThanOrEqual(settings.minimumWindowHeight, 220)
            XCTAssertGreaterThanOrEqual(settings.minimumWindowHeight, settings.rowHeight * 2 + 122)
            settings.compact = true
            XCTAssertEqual(settings.minimumWindowHeight, settings.rowHeight * 2 + 16)
            XCTAssertEqual(settings.minimumWindowSize.width, 380)
        }
    }
    func testInvalidAndExtremeDimensionsCannotCreateInvisibleFrames() {
        let limits = OverlayWindowSizing(minimum: NSSize(width: 380, height: 220))
        for size in [NSSize.zero, NSSize(width: -1000, height: -1000), NSSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            XCTAssertEqual(limits.clamped(size), NSSize(width: 380, height: 220))
        }
        XCTAssertEqual(limits.clamped(NSSize(width: 10_000, height: 10_000)), NSSize(width: 1000, height: 900))
        let result = limits.clamped(NSRect(x: CGFloat.nan, y: CGFloat.infinity, width: 1, height: 1))
        XCTAssertTrue(result.origin.x.isFinite && result.origin.y.isFinite)
    }
    func testModeSwitchChangesHardLimitWithoutLosingTheWidthLimit() {
        _ = NSApplication.shared
        let panel = OverlayPanel(contentRect: NSRect(x: 100, y: 100, width: 480, height: 317),
                                 styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setSizeLimits(minimum: NSSize(width: 380, height: 94))
        panel.setFrame(NSRect(x: 100, y: 100, width: 1, height: 1), display: false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 380, height: 94))
        panel.setSizeLimits(minimum: NSSize(width: 380, height: 220))
        panel.setFrame(NSRect(x: 100, y: 100, width: 1, height: 1), display: false)
        XCTAssertEqual(panel.frame.size, NSSize(width: 380, height: 220))
    }
    func testAllFourDragEdgesReturnToTheRunLoopAndKeepTheOppositeEdgeAnchored() throws {
        _ = NSApplication.shared
        let initial = NSRect(x: 100, y: 100, width: 480, height: 317)
        let panel = OverlayPanel(contentRect: initial, styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setSizeLimits(minimum: NSSize(width: 380, height: 220))
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        for (start, finish, horizontal) in [
            (NSPoint(x: 478, y: 158), NSPoint(x: -1000, y: 158), true),
            (NSPoint(x: 2, y: 158), NSPoint(x: 2000, y: 158), true),
            (NSPoint(x: 240, y: 315), NSPoint(x: 240, y: -1000), false),
            (NSPoint(x: 240, y: 2), NSPoint(x: 240, y: 2000), false)
        ] {
            panel.setFrame(initial, display: false)
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, finish)
            try send(.leftMouseUp, finish)
            if horizontal {
                XCTAssertEqual(panel.frame.width, 380)
                XCTAssertEqual(panel.frame.height, initial.height)
                XCTAssertEqual(start.x < 8 ? panel.frame.maxX : panel.frame.minX, start.x < 8 ? initial.maxX : initial.minX)
            } else {
                XCTAssertEqual(panel.frame.height, 220)
                XCTAssertEqual(panel.frame.width, initial.width)
                XCTAssertEqual(start.y < 8 ? panel.frame.maxY : panel.frame.minY, start.y < 8 ? initial.maxY : initial.minY)
            }
        }
    }
    func testLyricHostKeepsVisibleBoundsAtTheMinimumWindowSize() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LyricsStore(cache: LyricsCache(directory: directory), preferences: TrackPreferences(directory: directory))
        let settings = OverlaySettings(temporary: true)
        let actions = OverlayActions(settings: {}, importLyrics: {}, hide: {}, resetPosition: {}, timing: {})
        let host = NSHostingView(rootView: LyricsView(actions: actions).environmentObject(store).environmentObject(settings))
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        let panel = OverlayPanel(contentRect: NSRect(x: 100, y: 100, width: 480, height: 317),
                                 styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); store.stop(); try? FileManager.default.removeItem(at: directory) }
        panel.contentView = host
        panel.setSizeLimits(minimum: settings.minimumWindowSize)
        panel.setFrame(NSRect(x: 100, y: 100, width: 1, height: 1), display: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.size, settings.minimumWindowSize)
        XCTAssertEqual(host.frame.size, panel.contentRect(forFrameRect: panel.frame).size)
        XCTAssertGreaterThan(host.bounds.width, 0)
        XCTAssertGreaterThan(host.bounds.height, 0)
    }
}

@MainActor
final class DefaultCalibrationTests: XCTestCase {
    private var directory: URL!
    private var preferences: TrackPreferences!
    private var store: LyricsStore!
    private var native: LyricsResult {
        LyricsResult(lines: [LyricLine(time: 1, text: "Test", endTime: 4)], sourceID: "apple-cache", isWordSynced: false)
    }
    private func state(_ id: String = "one") -> MusicState {
        var state = MusicState(); state.running = true; state.trackID = id
        state.title = "Test"; state.duration = 20
        return state
    }
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
    func testBothSourcesUseTwentyHundredthsForPreviouslyUncalibratedSongs() throws {
        XCTAssertEqual(preferences.entry(for: "never-played").offset, 0.20)
        let local = LyricsResult(lines: native.lines, sourceID: "local", isWordSynced: false)
        try preferences.save(TrackPreferences.Entry(lyrics: local), for: "one")
        store.handle(state())
        XCTAssertEqual(store.timingOffset, 0.20)
        XCTAssertEqual(store.clock.offset, 0.20)
        store.setAppleMusicSyncEnabled(false, startReaders: false)
        XCTAssertEqual(store.timingOffset, 0.20)
        XCTAssertEqual(store.clock.offset, 0.20)
    }
    func testOldExplicitZeroAndOtherManualOffsetsArePreserved() throws {
        let old = try JSONDecoder().decode(TrackPreferences.Entry.self, from: Data("{\"offset\":0,\"musicOffset\":0}".utf8))
        try preferences.save(old, for: "one")
        store.handle(state())
        XCTAssertEqual(store.timingOffset, 0)
        let partial = try JSONDecoder().decode(TrackPreferences.Entry.self, from: Data("{\"musicOffset\":-0.45}".utf8))
        XCTAssertEqual(partial.offset, 0.20)
        XCTAssertEqual(partial.musicOffset, -0.45)
    }
    func testSettingsAndPopoverShareTheSavedOffsetAndResetDefault() throws {
        store.handle(state())
        store.handleMusicCacheLookup(.lyrics(native), trackID: "one")
        store.setTimingOffset(0.55)
        XCTAssertEqual(preferences.entry(for: "one").musicOffset, 0.55)
        store.resetTimingOffset()
        XCTAssertEqual(store.timingOffset, 0.20)
        XCTAssertEqual(preferences.entry(for: "one").musicOffset, 0.20)
        store.stop()
        let restoredPreferences = TrackPreferences(directory: directory.appendingPathComponent("Tracks"))
        store = LyricsStore(cache: LyricsCache(directory: directory), preferences: restoredPreferences)
        store.setAppleMusicSyncEnabled(true, startReaders: false)
        store.handle(state())
        XCTAssertEqual(store.timingOffset, 0.20)
    }
    func testAppleMusicSourceTitleStaysSimpleForEveryLyricFormat() {
        store.handle(state())
        XCTAssertEqual(store.currentSourceTitle, "Apple Music")
        for (index, result) in [
            LyricsResult(lines: [LyricLine(time: 0, text: "Static")], sourceID: "apple-cache", isWordSynced: false, isPlain: true),
            native,
            LyricsResult(lines: [LyricLine(time: 1, text: "Word", endTime: 4, words: [LyricWord(text: "Word", start: 1, end: 4)])], sourceID: "apple-cache", isWordSynced: true)
        ].enumerated() {
            store.handle(state(String(index)))
            store.handleMusicCacheLookup(.lyrics(result), trackID: String(index))
            XCTAssertEqual(store.currentSourceTitle, "Apple Music")
        }
    }
}

final class ArtworkSynchronizationTests: XCTestCase {
    private func response(title: String = "Title", before: String = "current", after: String = "current") -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, value) in [title, "Artist", "Album"].enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        list.insert(NSAppleEventDescriptor.null(), at: 4)
        list.insert(NSAppleEventDescriptor(string: before), at: 5)
        list.insert(NSAppleEventDescriptor(string: after), at: 6)
        return list
    }
    func testCoverMustBelongToTheSameTrackBeforeAndAfterTheRead() {
        XCTAssertTrue(MusicArtwork.isCurrentResponse(response(), trackID: "Title|Artist|Album", token: "current"))
        XCTAssertFalse(MusicArtwork.isCurrentResponse(response(before: "previous"), trackID: "Title|Artist|Album", token: "current"))
        XCTAssertFalse(MusicArtwork.isCurrentResponse(response(after: "next"), trackID: "Title|Artist|Album", token: "current"))
        XCTAssertFalse(MusicArtwork.isCurrentResponse(response(title: "Other"), trackID: "Title|Artist|Album", token: "current"))
        XCTAssertFalse(MusicArtwork.isCurrentResponse(response(), trackID: "Title|Artist|Album", token: ""))
    }
    func testLateArtworkIsRecheckedEvenAfterTheFirstImageArrivesButRetriesAreBounded() {
        for received in [false, true] {
            XCTAssertNotNil(MusicArtwork.refreshDelay(afterAttempt: 1, receivedImage: received))
            XCTAssertNotNil(MusicArtwork.refreshDelay(afterAttempt: 2, receivedImage: received))
            XCTAssertNil(MusicArtwork.refreshDelay(afterAttempt: 3, receivedImage: received))
        }
    }
}
