import AppKit
import XCTest
@testable import LyrX

@MainActor
final class SyncClockTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1000)

    func testDeliveryDelayDoesNotShiftThePlaybackTimelineBehindAudio() {
        let clock = PlaybackClock()
        clock.update(position: 10, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        XCTAssertEqual(clock.position(atUptime: 100.25), 10.25, accuracy: 0.000001)
        XCTAssertEqual(clock.position(atUptime: 100.8), 10.8, accuracy: 0.000001)
    }

    func testSmallLateSamplesCorrectSmoothlyWithoutRewindingHighlight() {
        let clock = PlaybackClock()
        clock.update(position: 10, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        clock.update(position: 10.7, duration: 100, playing: true, at: date.addingTimeInterval(0.8), sampledAtUptime: 100.8)
        XCTAssertEqual(clock.position(atUptime: 100.8), 10.8, accuracy: 0.000001)
        XCTAssertGreaterThan(clock.position(atUptime: 100.9), clock.position(atUptime: 100.8))
        XCTAssertEqual(clock.position(atUptime: 101.2), 11.1, accuracy: 0.000001)
    }

    func testSeekingPausingAndTrackResetsTakeEffectImmediately() {
        let clock = PlaybackClock()
        clock.update(position: 10, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        clock.update(position: 30, duration: 100, playing: true, at: date, sampledAtUptime: 101)
        XCTAssertEqual(clock.position(atUptime: 101), 30)
        clock.update(position: 5, duration: 100, playing: false, at: date, sampledAtUptime: 102)
        XCTAssertEqual(clock.position(atUptime: 200), 5)
        clock.update(position: 5, duration: 100, playing: true, at: date, sampledAtUptime: 103)
        clock.update(position: 5.1, duration: 100, playing: true, at: date, sampledAtUptime: 103.2, reset: true)
        XCTAssertEqual(clock.position(atUptime: 103.2), 5.1, accuracy: 0.000001)
    }

    func testStaleArtworkOrMetadataSnapshotsDoNotResetTimeAgain() {
        let clock = PlaybackClock()
        clock.update(position: 10, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        clock.update(position: 10.8, duration: 100, playing: true, at: date, sampledAtUptime: 100.8)
        let revision = clock.revision
        clock.update(position: 10, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        clock.update(position: 10.8, duration: 100, playing: true, at: date, sampledAtUptime: 100.8)
        XCTAssertEqual(clock.revision, revision)
        XCTAssertEqual(clock.position(atUptime: 101), 11, accuracy: 0.000001)
    }

    func testMonotonicProjectionIgnoresWallClockChangesAndKeepsDurationBounds() {
        let clock = PlaybackClock()
        clock.update(position: 98, duration: 100, playing: true, at: date, sampledAtUptime: 100)
        clock.update(position: 98.8, duration: 100, playing: true, at: date.addingTimeInterval(5000), sampledAtUptime: 100.8)
        XCTAssertEqual(clock.position(atUptime: 101), 99, accuracy: 0.000001)
        XCTAssertEqual(clock.position(atUptime: 200), 100)
    }

    func testTransportTimestampUsesOnlyThePositionReadInterval() {
        XCTAssertEqual(MusicMonitor.sampleTime(start: 100, end: 100.02, received: 100.3)!, 100.01, accuracy: 0.000001)
        XCTAssertEqual(MusicMonitor.sampleTime(start: 100, end: 101, received: 101.1), 101)
        XCTAssertNil(MusicMonitor.sampleTime(start: .nan, end: 100, received: 101))
        XCTAssertNil(MusicMonitor.sampleTime(start: 100, end: 99, received: 101))
        XCTAssertNil(MusicMonitor.sampleTime(start: 100, end: 102, received: 101))
        XCTAssertNil(MusicMonitor.sampleTime(start: 100, end: 100.01, received: 110))
    }

    func testAllReadScriptsCompileWithoutExecutingMusic() {
        let sources = [MusicMonitor.stateScriptSource, MusicMonitor.metadataScriptSource(includeNext: true),
                       MusicMonitor.metadataScriptSource(includeNext: false), MusicArtwork.scriptSource, MusicArtwork.embeddedLyricsScriptSource]
        for source in sources {
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)?.compileAndReturnError(&error) == true)
            XCTAssertNil(error)
        }
    }

    func testInScriptClockAndHostClockHaveTheSameTimeBase() throws {
        let source = """
        use framework "Foundation"
        return (current application's NSProcessInfo's processInfo()'s systemUptime()) as real
        """
        let before = ProcessInfo.processInfo.systemUptime
        var error: NSDictionary?
        let result = try XCTUnwrap(NSAppleScript(source: source)?.executeAndReturnError(&error))
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(error)
        XCTAssertGreaterThanOrEqual(result.doubleValue, before)
        XCTAssertLessThanOrEqual(result.doubleValue, after)
    }

    func testConcurrentRequestsUseTheSerializedScriptRuntime() async {
        MusicMonitor.prepareScriptingRuntime()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let (result, error) = MusicMonitor.runScript("return 42")
                    return error == nil && result?.int32Value == 42
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 })
    }
}
