import XCTest
import Combine
@testable import LyrX

final class HighlightTests: XCTestCase {
    func testLineProgressLightsCharactersInOrderAndFollowsSeekingBackwards() {
        let plan = LyricHighlightPlan(line: LyricLine(time: 10, text: "你好世界"), end: 14)
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 9) }, [0, 0, 0, 0])
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 12.5) }, [1, 1, 0.5, 0])
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 15) }, [1, 1, 1, 1])
        XCTAssertEqual(plan.glyphs.map { $0.progress(at: 10.5) }, [0.5, 0, 0, 0])
    }

    func testWordTimingsPreserveGapsPunctuationAndTranslations() {
        let line = LyricLine(time: 10, text: "你好，世界！\nHello 👋🏽", words: [
            LyricWord(text: "你好", start: 10, end: 12),
            LyricWord(text: "世界", start: 14, end: 16)
        ])
        let plan = LyricHighlightPlan(line: line, end: 18)
        XCTAssertEqual(plan.glyphs.map(\.text).joined(), line.text)
        XCTAssertEqual(plan.glyphs[0].progress(at: 13), 1)
        XCTAssertEqual(plan.glyphs[1].progress(at: 13), 1)
        XCTAssertEqual(plan.glyphs[3].progress(at: 13), 0)
        XCTAssertEqual(plan.glyphs[3].progress(at: 14.5), 0.5)
        XCTAssertEqual(plan.glyphs.last?.text, "👋🏽")
    }

    func testMultilineLineProgressRunsTogetherAndMalformedWordsFallBack() {
        let line = LyricLine(time: 0, text: "你好\nHello", words: [
            LyricWord(text: "missing", start: 0, end: 1),
            LyricWord(text: "你好", start: .nan, end: 3)
        ])
        let plan = LyricHighlightPlan(line: line, end: 2)
        XCTAssertEqual(plan.glyphs.map(\.text).joined(), line.text)
        XCTAssertEqual(plan.glyphs[0].progress(at: 1), 1)
        XCTAssertEqual(plan.glyphs[1].progress(at: 1), 0)
        XCTAssertEqual(plan.glyphs[3].progress(at: 1), 1)
        XCTAssertEqual(plan.glyphs[5].progress(at: 1), 0.5, accuracy: 0.0001)
    }

    func testKnownEndsArePreferredAndTailDoesNotSpanLongOutro() {
        var line = LyricLine(time: 10, text: "End", endTime: 12)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 20, duration: 180), 12)
        line.endTime = nil
        line.words = [LyricWord(text: "End", start: 10, end: 13)]
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 20, duration: 180), 13)
        line.words = nil
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 20, duration: 180), 20)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: nil, duration: 180), 16)
    }

    func testPausedSeekOffsetAndResumePublishClockChangesWithoutLineChange() {
        let clock = PlaybackClock()
        let date = Date(timeIntervalSince1970: 1000)
        let plan = LyricHighlightPlan(line: LyricLine(time: 10, text: "ABCD"), end: 14)
        var changes = 0
        let subscription = clock.objectWillChange.sink { changes += 1 }
        clock.update(position: 10.5, duration: 20, playing: false, at: date)
        let first = plan.glyphs[0].progress(at: clock.lyricPosition(at: date))
        clock.update(position: 12.5, duration: 20, playing: false, at: date)
        XCTAssertGreaterThan(plan.glyphs[0].progress(at: clock.lyricPosition(at: date)), first)
        XCTAssertEqual(clock.position(at: date.addingTimeInterval(100)), 12.5)
        clock.offset = -2
        XCTAssertEqual(plan.glyphs[0].progress(at: clock.lyricPosition(at: date)), first)
        clock.update(position: 12.5, duration: 20, playing: true, at: date)
        XCTAssertEqual(clock.position(at: date.addingTimeInterval(1)), 13.5)
        XCTAssertEqual(changes, 4)
        withExtendedLifetime(subscription) {}
    }
}
