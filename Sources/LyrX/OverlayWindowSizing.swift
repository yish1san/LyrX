import AppKit

/// 不依赖 NSHostingView 可能重新计算的 minSize；所有调整窗口尺寸的入口共用此限制。
struct OverlayWindowSizing {
    var minimum: NSSize
    var maximum = NSSize(width: 1000, height: 900)

    func clamped(_ size: NSSize) -> NSSize {
        NSSize(width: dimension(size.width, minimum.width, maximum.width),
               height: dimension(size.height, minimum.height, maximum.height))
    }
    func clamped(_ frame: NSRect) -> NSRect {
        NSRect(origin: NSPoint(x: frame.origin.x.isFinite ? frame.origin.x : 0,
                               y: frame.origin.y.isFinite ? frame.origin.y : 0), size: clamped(frame.size))
    }
    private func dimension(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        let lower = lower.isFinite ? max(1, lower) : 1
        let upper = upper.isFinite ? max(lower, upper) : lower
        return min(max(value.isFinite ? value : lower, lower), upper)
    }
}
