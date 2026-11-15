import SwiftUI
import AppKit

/// 横向溢出只改变排版，不改变词源；播放时间驱动移动，暂停和跳转保持一致。
struct CompactLyricText: View {
    let line: LyricLine
    let end: Double
    @ObservedObject var clock: PlaybackClock
    let playing: Bool
    let font: NSFont
    let baseColor: Color
    let accent: Color
    let style: LyricHighlightStyle
    let karaoke: Bool
    let current: Bool
    let centered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            if playing && current {
                TimelineView(.periodic(from: .now, by: reduceMotion ? 0.1 : 1 / 30)) { _ in content(size: geometry.size) }
            } else { content(size: geometry.size) }
        }
        .frame(height: ceil(font.ascender - font.descender) + 8)
        .clipped()
        .accessibilityLabel(line.text)
    }
    private func content(size: CGSize) -> some View {
        let natural = ceil((line.text as NSString).size(withAttributes: [.font: font]).width) + 8
        let width = max(size.width, natural)
        let progress = Self.scrollProgress(position: clock.lyricPosition(), start: line.time, end: end)
        let shift = current ? max(0, width - size.width) * progress : 0
        return Group {
            if karaoke {
                LyricSweepText(plan: LyricHighlightPlan(line: line, end: end), position: clock.lyricPosition(),
                               font: font, baseColor: baseColor, highlightColor: accent, style: style,
                               centered: centered && natural <= size.width, compact: true)
            } else {
                Text(line.text).font(Font(font)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(current ? accent : baseColor.opacity(0.5))
                    .frame(width: width, alignment: centered && natural <= size.width ? .center : .leading)
            }
        }
        .frame(width: width, height: size.height)
        .offset(x: -shift)
        .animation(nil, value: shift)
    }
    static func scrollProgress(position: Double, start: Double, end: Double) -> Double {
        guard position.isFinite, start.isFinite, end.isFinite, end > start else { return 0 }
        // 句首/句尾各保留短暂停留，最后一个字不会停在裁切区域外。
        return min(1, max(0, ((position - start) / (end - start) - 0.08) / 0.84))
    }
}
