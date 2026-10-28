import Foundation

/// 保留原始排版；逐词源使用真实词时间，逐句源仅估算句内显示进度。
struct LyricHighlightPlan {
    struct Glyph: Equatable {
        var text: String
        var start: Double
        var end: Double

        func progress(at position: Double) -> Double {
            guard position.isFinite else { return 0 }
            if end <= start { return position >= start ? 1 : 0 }
            return min(max((position - start) / (end - start), 0), 1)
        }
    }

    let glyphs: [Glyph]

    init(line: LyricLine, end: Double) {
        let start = line.time.isFinite ? line.time : 0
        let finish = end.isFinite && end > start ? end : start + 4
        let rows = line.text.components(separatedBy: "\n")
        var glyphs: [Glyph] = []
        for (rowIndex, row) in rows.enumerated() {
            let count = max(1, row.count)
            for (index, character) in row.enumerated() {
                glyphs.append(Glyph(text: String(character),
                    start: start + (finish - start) * Double(index) / Double(count),
                    end: start + (finish - start) * Double(index + 1) / Double(count)))
            }
            if rowIndex < rows.count - 1 { glyphs.append(Glyph(text: "\n", start: start, end: finish)) }
        }

        var cursor = line.text.startIndex
        for word in line.words ?? [] where word.start.isFinite && word.end.isFinite && word.end >= word.start {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let remaining = cursor..<line.text.endIndex
            guard let range = line.text.range(of: word.text, range: remaining)
                    ?? line.text.range(of: trimmed, range: remaining) else { continue }
            let offset = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let count = line.text.distance(from: range.lowerBound, to: range.upperBound)
            guard count > 0 else { continue }
            for index in 0..<count {
                glyphs[offset + index].start = word.start + (word.end - word.start) * Double(index) / Double(count)
                glyphs[offset + index].end = word.start + (word.end - word.start) * Double(index + 1) / Double(count)
            }
            cursor = range.upperBound
        }
        self.glyphs = glyphs
    }

    /// 演唱进度的终点与下一句切换时间分开；真实时间不裁短，缺失时仅估算长间隔。
    static func end(of line: LyricLine, nextTime: Double?, duration: Double, context: [LyricLine] = []) -> Double {
        if let end = knownEnd(of: line) { return end }
        let estimate = estimatedDuration(of: line, context: context)
        let boundary = [nextTime, duration].compactMap { $0 }
            .filter { $0.isFinite && $0 > line.time }.min()
        guard let boundary else { return line.time + estimate }
        let interval = boundary - line.time
        // 连续演唱保持原时间轴；只有显著偏长的空档才停止摊分给歌词。
        return interval > max(8, estimate * 1.8) ? line.time + estimate : boundary
    }

    private static func knownEnd(of line: LyricLine) -> Double? {
        // 段落结束可能晚于最后一个词，未计时的标点也应随演唱完成。
        let words = (line.words ?? []).filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
        }
        let timedText = vocalText(words.map(\.text).joined())
        let original = vocalText(line.text.components(separatedBy: "\n").first ?? line.text)
        if !original.isEmpty, (timedText == original || timedText == vocalText(line.text)),
           let end = words.map(\.end).max(), end > line.time { return end }
        if let end = line.endTime, end.isFinite, end > line.time { return end }
        return nil
    }

    private static func estimatedDuration(of line: LyricLine, context: [LyricLine]) -> Double {
        let units = vocalUnits(in: line.text)
        // 用附近歌词的典型速度适应快慢曲；中位数降低间奏对估计的影响。
        // 字数只取第一行，译文和标点不增加演唱时长；拉丁字母按平均词长折算。
        let rates = context.enumerated().compactMap { index, sample -> (distance: Double, rate: Double)? in
            guard sample.time != line.time, sample.time.isFinite else { return nil }
            let next = index + 1 < context.count ? context[index + 1].time : nil
            guard let end = knownEnd(of: sample) ?? next,
                  end.isFinite, end > sample.time else { return nil }
            let interval = end - sample.time
            guard interval >= 0.5, interval <= 20 else { return nil }
            let rate = interval / vocalUnits(in: sample.text)
            guard rate >= 0.08, rate <= 4 else { return nil }
            return (abs(sample.time - line.time), rate)
        }.sorted { $0.distance < $1.distance }.prefix(12).map(\.rate).sorted()
        let rate = rates.isEmpty ? 0.42 : rates[(rates.count - 1) / 2]
        let estimate = max(2.5, units * rate + 0.6)
        return rates.isEmpty ? min(8, estimate) : estimate
    }

    private static func vocalUnits(in text: String) -> Double {
        let first = text.components(separatedBy: "\n").first ?? text
        return max(1, first.unicodeScalars.reduce(0) { total, scalar in
            guard CharacterSet.alphanumerics.contains(scalar) else { return total }
            return total + (scalar.isASCII ? 0.25 : 1)
        })
    }

    private static func vocalText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
