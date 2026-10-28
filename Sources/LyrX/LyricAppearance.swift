import AppKit
import SwiftUI

enum LyricFontStyle: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "系统字体"
        case .rounded: "圆体"
        case .serif: "衬线体"
        case .monospaced: "等宽字体"
        case .custom: "自选字体"
        }
    }
}

enum LyricHighlightStyle: String, CaseIterable, Identifiable {
    case music, simple
    var id: String { rawValue }
    var title: String { self == .music ? "柔和扫亮" : "简洁点亮" }
}

/// 使用明确的 sRGB 值保存颜色，避免依赖系统颜色面板的临时状态。
struct LyricRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let rgb = UInt32(value, radix: 16) else { return nil }
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
    }

    init?(color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB),
              [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].allSatisfy(\.isFinite) else { return nil }
        red = Double(min(max(rgb.redComponent, 0), 1))
        green = Double(min(max(rgb.greenComponent, 0), 1))
        blue = Double(min(max(rgb.blueComponent, 0), 1))
    }

    var hex: String { String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

enum LyricAccent: String, CaseIterable, Identifiable {
    // 保留旧版取值，使现有高亮颜色自动沿用。
    case primary, white, cream, rose, mint, blue, lavender, amber, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primary: "跟随外观"
        case .white: "纯白"
        case .cream: "奶油"
        case .rose: "玫瑰"
        case .mint: "薄荷"
        case .blue: "海蓝"
        case .lavender: "薰衣草"
        case .amber: "琥珀"
        case .custom: "自选颜色"
        }
    }
    var hex: String? {
        switch self {
        case .primary, .custom: nil
        case .white: "FFFFFF"
        case .cream: "FFE7BC"
        case .rose: "FF6F96"
        case .mint: "6BDCC0"
        case .blue: "75B6FF"
        case .lavender: "C6A8FF"
        case .amber: "FFD06F"
        }
    }
    func color(custom hex: String) -> Color {
        if self == .custom { return LyricRGB(hex: hex)?.color ?? .primary }
        return self.hex.flatMap { LyricRGB(hex: $0)?.color } ?? .primary
    }
}

@MainActor
extension OverlaySettings {
    var lyricColor: Color { lyricColorChoice.color(custom: lyricColorHex) }
    var highlightColor: Color { accent.color(custom: highlightColorHex) }
    var customFontAvailable: Bool { NSFont(name: customFontName, size: fontSize) != nil }
    var fontDisplayName: String { NSFont(name: customFontName, size: fontSize)?.displayName ?? "系统字体" }

    func nativeFont(emphasized: Bool = false) -> NSFont {
        let weight: NSFont.Weight = emphasized ? .bold : .medium
        let system = NSFont.systemFont(ofSize: fontSize, weight: weight)
        switch fontStyle {
        case .system: return system
        case .rounded, .serif, .monospaced:
            let design: NSFontDescriptor.SystemDesign = fontStyle == .rounded ? .rounded : fontStyle == .serif ? .serif : .monospaced
            return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? system
        case .custom:
            // 尊重所选字形和粗细；缺失的字体由系统字体接替，仍保留原选择。
            return NSFont(name: customFontName, size: fontSize) ?? system
        }
    }
}

/// 使用系统字体面板，字体只来自本机，不下载或上传字体。
@MainActor
final class LyricFontPanel: NSObject {
    static let shared = LyricFontPanel()
    private weak var settings: OverlaySettings?

    func show(for settings: OverlaySettings) {
        self.settings = settings
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(settings.nativeFont(), isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager) {
        guard let settings else { return }
        apply(sender.convert(settings.nativeFont()), to: settings)
    }

    func apply(_ font: NSFont, to settings: OverlaySettings) {
        settings.customFontName = font.fontName
        settings.fontStyle = .custom
        settings.fontSize = min(max(font.pointSize, 14), 28)
    }

    func close(for settings: OverlaySettings) {
        guard self.settings === settings else { return }
        NSFontManager.shared.fontPanel(false)?.close()
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
        self.settings = nil
    }
}
