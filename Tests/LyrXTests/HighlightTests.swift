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

    func testKnownEndsArePreferredAndUnknownLongGapsDoNotSpanInstrumentals() {
        var line = LyricLine(time: 10, text: "End", endTime: 12)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 20, duration: 180), 12)
        line.endTime = nil
        line.words = [LyricWord(text: "End", start: 10, end: 13)]
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 20, duration: 180), 13)
        line.words = nil
        let end = LyricHighlightPlan.end(of: line, nextTime: 40, duration: 180)
        XCTAssertLessThan(end, 20)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: nil, duration: 180), end)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: 12, duration: 180), 12)
    }

    func testLastTimedWordFinishesPunctuationAndTranslationBeforeParagraphEnds() throws {
        let line = try XCTUnwrap(TTMLParser.parse("<tt><p begin='10s' end='40s'><span begin='10s' end='11s'>你</span><span begin='11s' end='14s'>好</span>！</p></tt>").first)
        let end = LyricHighlightPlan.end(of: line, nextTime: 45, duration: 180)
        XCTAssertEqual(end, 14)
        let translated = LyricLine(time: line.time, text: line.text + "\nHello!", endTime: line.endTime, words: line.words)
        let plan = LyricHighlightPlan(line: translated, end: LyricHighlightPlan.end(of: translated, nextTime: 45, duration: 180))
        XCTAssertTrue(plan.glyphs.allSatisfy { $0.progress(at: 14) == 1 })
        XCTAssertEqual(plan.glyphs[1].progress(at: 12.5), 0.5)
    }

    func testRealSustainedNotesAndUntimedTextAreNotCutToHeuristicEnd() {
        let held = LyricLine(time: 10, text: "啊", endTime: 40, words: [LyricWord(text: "啊", start: 10, end: 38)])
        XCTAssertEqual(LyricHighlightPlan.end(of: held, nextTime: 45, duration: 180), 38)
        let partial = LyricLine(time: 10, text: "你和我", endTime: 20, words: [LyricWord(text: "你", start: 10, end: 12)])
        XCTAssertEqual(LyricHighlightPlan.end(of: partial, nextTime: 40, duration: 180), 20)
        let lineOnly = LyricLine(time: 10, text: "啊", endTime: 30)
        XCTAssertEqual(LyricHighlightPlan.end(of: lineOnly, nextTime: 40, duration: 180), 30)
    }

    func testLongGapUsesSurroundingCadenceWithoutAdvancingNextLine() {
        let lines = [0.0, 4, 8, 32, 36, 40].map { LyricLine(time: $0, text: "你好世界") }
        let end = LyricHighlightPlan.end(of: lines[2], nextTime: 32, duration: 100, context: lines)
        XCTAssertEqual(end, 12.6, accuracy: 0.001)
        let plan = LyricHighlightPlan(line: lines[2], end: end)
        XCTAssertTrue(plan.glyphs.allSatisfy { $0.progress(at: 15) == 1 })
        XCTAssertEqual(LyricsStore.lineIndex(at: 20, times: lines.map(\.time)), 2)
        XCTAssertEqual(LyricsStore.lineIndex(at: 32, times: lines.map(\.time)), 3)
    }

    func testSlowContinuousSingingKeepsExistingBoundariesAndTranslationDoesNotAddDuration() {
        let lines = [0.0, 10, 20, 30, 40].map { LyricLine(time: $0, text: "你好世界") }
        XCTAssertEqual(LyricHighlightPlan.end(of: lines[2], nextTime: 30, duration: 100, context: lines), 30)
        let plain = LyricLine(time: 50, text: "你好世界")
        let translated = LyricLine(time: 50, text: plain.text + "\nThis is a much longer translation of the original lyric")
        XCTAssertEqual(LyricHighlightPlan.end(of: plain, nextTime: 90, duration: 100, context: lines),
                       LyricHighlightPlan.end(of: translated, nextTime: 90, duration: 100, context: lines))
    }

    func testFallbackBoundsStayFiniteAndWithinTrack() {
        let line = LyricLine(time: 10, text: "最后一句")
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: nil, duration: 11), 11)
        XCTAssertEqual(LyricHighlightPlan.end(of: line, nextTime: .nan, duration: .infinity),
                       LyricHighlightPlan.end(of: line, nextTime: nil, duration: 180))
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
