import Foundation

/// 保留原始排版；逐词源使用真实词时间，逐句源仅估算句内显示进度。
struct LyricHighlightPlan {
    struct Glyph {
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

    static func end(of line: LyricLine, nextTime: Double?, duration: Double) -> Double {
        if let end = line.endTime, end.isFinite, end > line.time { return end }
        if let end = line.words?.map(\.end).filter({ $0.isFinite }).max(), end > line.time { return end }
        if let nextTime, nextTime.isFinite, nextTime > line.time { return nextTime }
        // 尾句没有结束时间时，避免把整段尾奏当作一句的演唱时长。
        return duration.isFinite && duration > line.time ? min(duration, line.time + 6) : line.time + 6
    }
}
