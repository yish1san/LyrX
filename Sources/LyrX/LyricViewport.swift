import AppKit

enum LyricViewport {
    static func resetOrigin(size: NSSize, screen: NSRect) -> NSPoint {
        NSPoint(x: screen.midX - size.width / 2,
                y: screen.minY + min(72, max(0, screen.height - size.height)))
    }
    static func focusedRow(lines: Int) -> Int { max(0, (lines - 1) / 2) }
    static func requiredWidth(lines: [LyricLine], font: NSFont, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let natural = lines.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(maximum, max(minimum, ceil(natural) + 56))
    }
}
