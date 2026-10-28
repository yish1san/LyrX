import AppKit
import SwiftUI
import XCTest
@testable import LyrX

@MainActor
final class AppearanceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "LyrXTests.appearance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testFontBothCustomColorsAndHighlightStyleRestoreAcrossSessions() throws {
        let settings = OverlaySettings(defaults: defaults)
        let font = try XCTUnwrap(NSFont(name: "Georgia-BoldItalic", size: 24))
        LyricFontPanel.shared.apply(font, to: settings)
        settings.lyricColorChoice = .custom; settings.lyricColorHex = "#91aBcD"
        settings.accent = .custom; settings.highlightColorHex = "FF80B0"
        settings.highlightStyle = .simple; settings.followMusicLyrics = true
        let restored = OverlaySettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restored.fontStyle, .custom)
        XCTAssertEqual(restored.nativeFont().fontName, font.fontName)
        XCTAssertEqual(restored.nativeFont(emphasized: true).fontName, font.fontName)
        XCTAssertEqual(restored.fontSize, 24)
        XCTAssertEqual(restored.lyricColorChoice, .custom)
        XCTAssertEqual(restored.lyricColorHex, "91ABCD")
        XCTAssertEqual(restored.accent, .custom)
        XCTAssertEqual(restored.highlightColorHex, "FF80B0")
        XCTAssertEqual(LyricRGB(color: NSColor(restored.lyricColor))?.hex, "91ABCD")
        XCTAssertEqual(LyricRGB(color: NSColor(restored.highlightColor))?.hex, "FF80B0")
        XCTAssertEqual(restored.highlightStyle, .simple)
        XCTAssertTrue(restored.followMusicLyrics)
    }

    func testSystemFontStylesAndColorChoicesRemainIndependent() {
        let settings = OverlaySettings(defaults: defaults)
        for font in LyricFontStyle.allCases where font != .custom {
            settings.fontStyle = font
            let next = OverlaySettings(defaults: UserDefaults(suiteName: suite)!)
            XCTAssertEqual(next.fontStyle, font)
            XCTAssertEqual(next.nativeFont().pointSize, settings.fontSize)
        }
        settings.accent = .rose
        settings.lyricColorChoice = .blue
        let restored = OverlaySettings(defaults: defaults)
        XCTAssertEqual(restored.accent, .rose)
        XCTAssertEqual(restored.lyricColorChoice, .blue)
        XCTAssertNotEqual(LyricRGB(color: NSColor(restored.highlightColor)), LyricRGB(color: NSColor(restored.lyricColor)))
    }

    func testOldAccentMigratesAndMissingFontOrInvalidPreferencesFallBackSafely() {
        defaults.set("mint", forKey: "overlay.accent")
        defaults.set("removed-style", forKey: "overlay.highlightStyle")
        defaults.set("custom", forKey: "overlay.fontStyle")
        defaults.set("LyrX-Test-Font-That-Does-Not-Exist", forKey: "overlay.customFontName")
        defaults.set("not-a-color", forKey: "overlay.lyricColorHex")
        defaults.set("12345Z", forKey: "overlay.highlightColorHex")
        let settings = OverlaySettings(defaults: defaults)
        XCTAssertEqual(settings.accent, .mint)
        XCTAssertEqual(settings.lyricColorChoice, .primary)
        XCTAssertEqual(settings.highlightStyle, .music)
        XCTAssertEqual(settings.lyricColorHex, "FFFFFF")
        XCTAssertEqual(settings.highlightColorHex, "FFFFFF")
        XCTAssertFalse(settings.customFontAvailable)
        XCTAssertEqual(settings.nativeFont().fontName, NSFont.systemFont(ofSize: 20, weight: .medium).fontName)
        XCTAssertEqual(settings.customFontName, "LyrX-Test-Font-That-Does-Not-Exist")
        defaults.set("invalid", forKey: "overlay.fontStyle")
        XCTAssertEqual(OverlaySettings(defaults: defaults).fontStyle, .system)
    }

    func testPreviewDoesNotReadOrOverwriteAppearancePreferences() {
        let saved = OverlaySettings(defaults: defaults)
        saved.fontStyle = .serif; saved.accent = .custom; saved.highlightColorHex = "123456"
        saved.lyricColorChoice = .cream; saved.highlightStyle = .simple
        let preview = OverlaySettings(defaults: defaults, temporary: true)
        XCTAssertEqual(preview.fontStyle, .system)
        XCTAssertEqual(preview.highlightColorHex, "FFFFFF")
        preview.fontStyle = .monospaced; preview.highlightColorHex = "ABCDEF"
        preview.lyricColorChoice = .white; preview.highlightStyle = .music
        let restored = OverlaySettings(defaults: defaults)
        XCTAssertEqual(restored.fontStyle, .serif)
        XCTAssertEqual(restored.highlightColorHex, "123456")
        XCTAssertEqual(restored.lyricColorChoice, .cream)
        XCTAssertEqual(restored.highlightStyle, .simple)
    }

    func testAppearanceResetPersistsAndKeepsMusicSourcePreference() {
        let settings = OverlaySettings(defaults: defaults)
        settings.followMusicLyrics = true; settings.fontStyle = .serif
        settings.lyricColorChoice = .custom; settings.lyricColorHex = "123456"
        settings.accent = .amber; settings.highlightStyle = .simple
        settings.resetAppearance()
        let restored = OverlaySettings(defaults: defaults)
        XCTAssertEqual(restored.fontStyle, .system)
        XCTAssertEqual(restored.customFontName, "")
        XCTAssertEqual(restored.lyricColorChoice, .primary)
        XCTAssertEqual(restored.accent, .primary)
        XCTAssertEqual(restored.highlightStyle, .music)
        XCTAssertEqual(restored.lyricColorHex, "FFFFFF")
        XCTAssertTrue(restored.followMusicLyrics)
    }

    func testColorPanelValuesRoundTripWithoutStoringMalformedColors() throws {
        for hex in ["000000", "FFFFFF", "12AB90", "FF80B0"] {
            let rgb = try XCTUnwrap(LyricRGB(hex: hex))
            XCTAssertEqual(LyricRGB(color: NSColor(rgb.color))?.hex, hex)
        }
        for bad in ["", "12#3456", "##123456", "12345G", "FFFFFFFF", "123", "+FFFFF", "-00000"] { XCTAssertNil(LyricRGB(hex: bad)) }
        let settings = OverlaySettings(defaults: defaults)
        settings.highlightColorHex = "123456"
        settings.highlightColorHex = "bad"
        XCTAssertEqual(OverlaySettings(defaults: defaults).highlightColorHex, "123456")
    }

    private func drawing(_ text: String = "MMMM", style: LyricHighlightStyle = .music, width: CGFloat = 360,
                         font: NSFont = .monospacedSystemFont(ofSize: 40, weight: .bold), compact: Bool = false) -> LyricDrawingView {
        let view = LyricDrawingView()
        view.configure(plan: LyricHighlightPlan(line: LyricLine(time: 0, text: text), end: 4), font: font,
                       base: NSColor(srgbRed: 0.1, green: 0.65, blue: 0.7, alpha: 1),
                       highlight: NSColor(srgbRed: 1, green: 0.2, blue: 0.1, alpha: 1),
                       style: style, centered: false, compact: compact, reduceMotion: false)
        view.frame = CGRect(origin: .zero, size: view.measuredSize(width: width))
        return view
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func redPixels(_ bitmap: NSBitmapImageRep, xRange: Range<Int>? = nil) -> Int {
        var count = 0
        for x in xRange ?? 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.2 && color.redComponent > color.greenComponent * 2 && color.redComponent > color.blueComponent * 2 { count += 1 }
            }
        }
        return count
    }

    func testActualRenderingFillsContinuouslyInSelectedColorAndRespondsToSeeking() throws {
        let view = drawing()
        view.position = 0
        XCTAssertEqual(redPixels(try snapshot(view)), 0)
        view.position = 0.5
        let first = try snapshot(view)
        let firstCount = redPixels(first)
        XCTAssertGreaterThan(firstCount, 10)
        view.position = 4
        let full = redPixels(try snapshot(view))
        XCTAssertGreaterThan(full, firstCount * 3)
        view.position = 0.5
        XCTAssertEqual(redPixels(try snapshot(view)), firstCount)
        view.position = .nan
        XCTAssertEqual(redPixels(try snapshot(view)), 0)
    }

    func testSweepAndSimpleStylesHaveDifferentPartialGlyphAppearance() throws {
        let music = drawing("M")
        let simple = drawing("M", style: .simple)
        music.position = 2; simple.position = 2
        let a = try snapshot(music), b = try snapshot(simple)
        XCTAssertNotEqual(a.representation(using: .png, properties: [:]), b.representation(using: .png, properties: [:]))
    }

    func testNativeLayoutHandlesMixedScriptsEmojiAndCompactResizing() throws {
        let text = "你好，世界 👋🏽 ffi\nHello music مرحبا"
        let view = drawing(text, width: 230)
        XCTAssertGreaterThan(view.frame.height, drawing("你好").frame.height)
        XCTAssertLessThan(view.frame.height, 200)
        view.position = 4
        XCTAssertGreaterThan(redPixels(try snapshot(view)), 10)
        let compact = drawing(text, width: 140, compact: true)
        XCTAssertLessThan(compact.frame.height, view.frame.height)
        compact.position = 4
        XCTAssertGreaterThan(redPixels(try snapshot(compact)), 10)
        XCTAssertTrue(compact.measuredSize(width: .infinity).width.isFinite)
        try saveVisualPreviewsIfRequested()
    }

    private func saveVisualPreviewsIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LYRX_PREVIEW_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = OverlaySettings(defaults: defaults, temporary: true)
        settings.appearance = .dark
        settings.accent = .rose
        let store = LyricsStore(cache: LyricsCache(directory: dir.appendingPathComponent("temporary-cache")),
                                preferences: TrackPreferences(directory: dir.appendingPathComponent("temporary-tracks")))
        let host = NSHostingView(rootView: SettingsView(importLyrics: {}).environmentObject(settings).environmentObject(store)
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        try snapshot(host).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
        for style in [LyricFontStyle.system, .rounded, .serif, .monospaced] {
            settings.fontStyle = style
            let view = drawing("每一句，都刚好在眼前\nLet the music stay with you", width: 560, font: settings.nativeFont(emphasized: true))
            view.position = 2
            try snapshot(view).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("font-\(style.rawValue).png"))
        }
        settings.fontStyle = .system; settings.accent = .white
        store.start(preview: true)
        let actions = OverlayActions(settings: {}, importLyrics: {}, hide: {}, resetPosition: {}, timing: {})
        let overlay = NSHostingView(rootView: LyricsView(actions: actions).environmentObject(settings).environmentObject(store)
            .environment(\.colorScheme, .dark))
        overlay.frame = CGRect(x: 0, y: 0, width: 480, height: settings.windowHeight)
        let overlayWindow = NSWindow(contentRect: overlay.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        overlayWindow.contentView = overlay
        try snapshot(overlay).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("overlay.png"))
        settings.fontStyle = .serif; settings.accent = .lavender; settings.lyricColorChoice = .cream
        try snapshot(overlay).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("overlay-serif.png"))
        store.stop()
    }
}
