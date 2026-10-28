import AppKit
import SwiftUI

/// AppKit 排版保留中文替代字体、连字和换行，扫亮直接裁切实际字形。
struct LyricSweepText: NSViewRepresentable {
    let plan: LyricHighlightPlan
    let position: Double
    let font: NSFont
    let baseColor: Color
    let highlightColor: Color
    let style: LyricHighlightStyle
    let centered: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LyricDrawingView { LyricDrawingView() }
    func updateNSView(_ view: LyricDrawingView, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.configure(plan: plan, font: font, base: NSColor(baseColor), highlight: NSColor(highlightColor),
                       style: style, centered: centered, compact: compact, reduceMotion: reduceMotion)
        view.position = position
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LyricDrawingView, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width ?? 432)
    }
}

@MainActor
final class LyricDrawingView: NSView {
    private struct CharacterTiming {
        let range: NSRange
        let glyph: LyricHighlightPlan.Glyph
    }
    private struct Cluster {
        let range: NSRange
        let rect: CGRect
        let timings: [CharacterTiming]
        let rtl: Bool
        func progress(at position: Double) -> Double {
            let total = timings.reduce(0) { $0 + $1.range.length }
            guard total > 0 else { return 0 }
            return timings.reduce(0) { $0 + $1.glyph.progress(at: position) * Double($1.range.length) } / Double(total)
        }
    }
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 20, weight: .bold)
    private var base = NSColor.labelColor
    private var highlight = NSColor.labelColor
    private var style: LyricHighlightStyle = .music
    private var centered = true
    private var compact = false
    private var reduceMotion = false
    private var timings: [CharacterTiming] = []
    private var timedGlyphs: [LyricHighlightPlan.Glyph] = []
    private var clusters: [Cluster] = []
    private var layoutWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 30
    var position: Double = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(plan: LyricHighlightPlan, font: NSFont, base: NSColor, highlight: NSColor,
                   style: LyricHighlightStyle, centered: Bool, compact: Bool, reduceMotion: Bool) {
        let text = plan.glyphs.map(\.text).joined()
        let layoutChanged = self.text != text || self.font != font || self.centered != centered || self.compact != compact
        let timingChanged = timedGlyphs != plan.glyphs
        self.text = text; self.font = font; self.base = base; self.highlight = highlight
        self.style = style; self.centered = centered; self.compact = compact; self.reduceMotion = reduceMotion
        if timingChanged {
            timedGlyphs = plan.glyphs
            var offset = 0
            timings = plan.glyphs.map { glyph in
                let count = glyph.text.utf16.count
                defer { offset += count }
                return CharacterTiming(range: NSRange(location: offset, length: count), glyph: glyph)
            }
        }
        // 时间轴可能在重读后改变，即使歌词文字相同也重新绑定时间。
        if layoutChanged { layoutWidth = -1; invalidateIntrinsicContentSize() }
        else if timingChanged && layoutWidth >= 0 { rebuildClusters() }
        setAccessibilityValue(text)
        needsDisplay = true
    }

    func measuredSize(width: CGFloat) -> CGSize {
        let width = width.isFinite ? max(1, width) : 432
        prepareLayout(width: width)
        return CGSize(width: width, height: measuredHeight)
    }

    private func prepareLayout(width: CGFloat) {
        let width = max(1, width.isFinite ? width : 432)
        guard layoutWidth != width else { return }
        layoutWidth = width
        var drawingFont = font
        if compact {
            let first = text.components(separatedBy: "\n").first ?? text
            let naturalWidth = (first as NSString).size(withAttributes: [.font: font]).width
            let scale = min(1, max(0.65, width / max(1, naturalWidth)))
            drawingFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        container.containerSize = CGSize(width: width, height: 10_000)
        container.maximumNumberOfLines = compact ? 1 : 3
        container.lineBreakMode = .byTruncatingTail
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: drawingFont, .foregroundColor: base.withAlphaComponent(0.42), .paragraphStyle: paragraph
        ]))
        layoutManager.ensureLayout(for: container)
        measuredHeight = ceil(max(drawingFont.ascender - drawingFont.descender, layoutManager.usedRect(for: container).height)) + 6
        rebuildClusters()
    }

    private func rebuildClusters() {
        clusters = []
        var seen: Set<String> = []
        let visible = layoutManager.glyphRange(for: container)
        for timing in timings where timing.glyph.text != "\n" {
            var glyphs = layoutManager.glyphRange(forCharacterRange: timing.range, actualCharacterRange: nil)
            guard glyphs.length > 0, NSIntersectionRange(glyphs, visible).length > 0 else { continue }
            let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: &glyphs)
            let key = "\(glyphs.location):\(glyphs.length)"
            guard seen.insert(key).inserted else { continue }
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            guard rect.width > 0, rect.height > 0 else { continue }
            var bidi: UInt8 = 0
            layoutManager.getGlyphs(in: NSRange(location: glyphs.location, length: 1), glyphs: nil,
                                   properties: nil, characterIndexes: nil, bidiLevels: &bidi)
            let members = timings.filter { NSIntersectionRange($0.range, chars).length > 0 }
            clusters.append(Cluster(range: glyphs, rect: rect, timings: members, rtl: bidi % 2 == 1))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        prepareLayout(width: bounds.width)
        let all = NSRange(location: 0, length: storage.length)
        let visible = layoutManager.glyphRange(for: container)
        let origin = NSPoint(x: 0, y: 3)
        layoutManager.addTemporaryAttribute(.foregroundColor, value: base.withAlphaComponent(0.42), forCharacterRange: all)
        layoutManager.drawGlyphs(forGlyphRange: visible, at: origin)
        layoutManager.addTemporaryAttribute(.foregroundColor, value: highlight, forCharacterRange: all)
        for cluster in clusters {
            let progress = cluster.progress(at: position)
            guard progress > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            if style == .music && !reduceMotion {
                var clip = cluster.rect.offsetBy(dx: 0, dy: origin.y)
                clip.size.width *= progress
                if cluster.rtl { clip.origin.x = cluster.rect.maxX - clip.width }
                clip.origin.y -= 3; clip.size.height += 6
                if progress >= 1 { clip = clip.insetBy(dx: -2, dy: 0) }
                NSBezierPath(rect: clip).addClip()
                let shadow = NSShadow()
                shadow.shadowColor = highlight.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 1.8
                shadow.shadowOffset = .zero
                shadow.set()
            } else {
                NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(progress))
            }
            layoutManager.drawGlyphs(forGlyphRange: cluster.range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
    }
}

struct LyricAppearancePreview: View {
    @EnvironmentObject var settings: OverlaySettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    private let line = LyricLine(time: 0, text: "每一句，都刚好在眼前\nLet the music stay with you")

    var body: some View {
        let previewScheme = settings.appearance.colorScheme ?? scheme
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.2 : 1 / 30)) { context in
            let position = reduceMotion ? 2.7 : max(0, context.date.timeIntervalSince(started)).truncatingRemainder(dividingBy: 6)
            Group {
                if settings.karaoke {
                    LyricSweepText(plan: LyricHighlightPlan(line: line, end: 4.5), position: position,
                                   font: settings.nativeFont(emphasized: true), baseColor: settings.lyricColor,
                                   highlightColor: settings.highlightColor, style: settings.highlightStyle,
                                   centered: true, compact: false)
                } else {
                    Text(line.text).font(Font(settings.nativeFont(emphasized: true)))
                        .foregroundStyle(settings.highlightColor).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 88)
            .background(previewScheme == .dark ? Color(white: 0.12) : Color(white: 0.94), in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, previewScheme)
        }
        .accessibilityLabel("歌词外观预览")
    }
}
