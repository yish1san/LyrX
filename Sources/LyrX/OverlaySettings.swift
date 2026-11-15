import SwiftUI
import AppKit

enum SettingsTab: Hashable { case appearance, behavior, sources }

enum OverlayAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, transparent
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色"; case .transparent: "透明" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark, .transparent: .dark } }
}

@MainActor
final class OverlaySettings: ObservableObject {
    @Published var selectedTab: SettingsTab = .appearance
    private let defaults: UserDefaults
    private let temporary: Bool
    @Published var visibleLines: Int { didSet { save(visibleLines, "visibleLines"); onLayoutChange?() } }
    @Published var compactLines: Int { didSet { save(compactLines, "compactLines"); onLayoutChange?() } }
    @Published var automaticSourceFallback: Bool { didSet { save(automaticSourceFallback, "automaticSourceFallback"); onLyricsSourceChange?() } }
    @Published var autoFitWidth: Bool { didSet { save(autoFitWidth, "autoFitWidth"); onLayoutChange?() } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize"); onLayoutChange?() } }
    @Published var fontStyle: LyricFontStyle { didSet { save(fontStyle.rawValue, "fontStyle"); onLayoutChange?() } }
    @Published var customFontName: String { didSet { save(customFontName, "customFontName"); onLayoutChange?() } }
    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, "backgroundOpacity") } }
    @Published var appearance: OverlayAppearance { didSet { save(appearance.rawValue, "appearance"); onBehaviorChange?() } }
    @Published var accent: LyricAccent { didSet { save(accent.rawValue, "accent") } }
    @Published var lyricColorChoice: LyricAccent { didSet { save(lyricColorChoice.rawValue, "lyricColorChoice") } }
    @Published var lyricColorHex: String { didSet { if let rgb = LyricRGB(hex: lyricColorHex) { save(rgb.hex, "lyricColorHex") } } }
    @Published var highlightColorHex: String { didSet { if let rgb = LyricRGB(hex: highlightColorHex) { save(rgb.hex, "highlightColorHex") } } }
    @Published var highlightStyle: LyricHighlightStyle { didSet { save(highlightStyle.rawValue, "highlightStyle") } }
    @Published var centered: Bool { didSet { save(centered, "centered") } }
    @Published var compact: Bool { didSet { save(compact, "compact"); onLayoutChange?() } }
    @Published var karaoke: Bool { didSet { save(karaoke, "karaoke") } }
    @Published var followMusicLyrics: Bool { didSet { save(followMusicLyrics, "followMusicLyrics"); onLyricsSourceChange?() } }
    @Published var floating: Bool { didSet { save(floating, "floating"); onBehaviorChange?() } }
    @Published var allSpaces: Bool { didSet { save(allSpaces, "allSpaces"); onBehaviorChange?() } }
    @Published var clickThrough: Bool { didSet { save(clickThrough, "clickThrough"); onBehaviorChange?() } }
    @Published var hideWhenPaused: Bool { didSet { save(hideWhenPaused, "hideWhenPaused"); onBehaviorChange?() } }
    @Published var globalShortcutEnabled: Bool { didSet { save(globalShortcutEnabled, "globalShortcutEnabled"); onShortcutChange?() } }
    @Published var globalShortcutError: String?
    var onLayoutChange: (() -> Void)?
    var onBehaviorChange: (() -> Void)?
    var onLyricsSourceChange: (() -> Void)?
    var onResetSize: (() -> Void)?
    var onShortcutChange: (() -> Void)?
    static let minLines = 3
    static let maxLines = 7

    init(defaults: UserDefaults = .standard, temporary: Bool = false) {
        self.defaults = defaults
        self.temporary = temporary
        func number(_ key: String, _ fallback: Double) -> Double {
            if temporary { return fallback }
            let value = (defaults.object(forKey: "overlay.\(key)") as? NSNumber)?.doubleValue ?? fallback
            return value.isFinite ? value : fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            if temporary { return fallback }
            return defaults.object(forKey: "overlay.\(key)") as? Bool ?? fallback
        }
        visibleLines = Int(min(max(number("visibleLines", 5), Double(Self.minLines)), Double(Self.maxLines)))
        compactLines = Int(min(max(number("compactLines", 2), 1), 7))
        automaticSourceFallback = flag("automaticSourceFallback", false)
        autoFitWidth = flag("autoFitWidth", true)
        fontSize = min(max(number("fontSize", 20), 14), 28)
        fontStyle = temporary ? .system : (LyricFontStyle(rawValue: defaults.string(forKey: "overlay.fontStyle") ?? "") ?? .system)
        customFontName = temporary ? "" : defaults.string(forKey: "overlay.customFontName") ?? ""
        backgroundOpacity = min(max(number("backgroundOpacity", 0.62), 0), 1)
        appearance = temporary ? .system : (OverlayAppearance(rawValue: defaults.string(forKey: "overlay.appearance") ?? "") ?? .system)
        accent = temporary ? .primary : (LyricAccent(rawValue: defaults.string(forKey: "overlay.accent") ?? "") ?? .primary)
        lyricColorChoice = temporary ? .primary : (LyricAccent(rawValue: defaults.string(forKey: "overlay.lyricColorChoice") ?? "") ?? .primary)
        lyricColorHex = temporary ? "FFFFFF" : (defaults.string(forKey: "overlay.lyricColorHex").flatMap { LyricRGB(hex: $0)?.hex } ?? "FFFFFF")
        highlightColorHex = temporary ? "FFFFFF" : (defaults.string(forKey: "overlay.highlightColorHex").flatMap { LyricRGB(hex: $0)?.hex } ?? "FFFFFF")
        highlightStyle = temporary ? .music : (LyricHighlightStyle(rawValue: defaults.string(forKey: "overlay.highlightStyle") ?? "") ?? .music)
        centered = flag("centered", true)
        compact = flag("compact", false)
        karaoke = flag("karaoke", true)
        // 沿用上次选择；没有记录时仍默认使用自动匹配。临时预览不读取或写入偏好。
        followMusicLyrics = flag("followMusicLyrics", false)
        floating = flag("floating", true)
        allSpaces = flag("allSpaces", true)
        clickThrough = flag("clickThrough", false)
        hideWhenPaused = flag("hideWhenPaused", false)
        globalShortcutEnabled = flag("globalShortcutEnabled", false)
    }

    var rowHeight: CGFloat { CGFloat(fontSize) * 1.55 + 8 }
    var isTransparent: Bool { appearance == .transparent }
    var minimumWindowHeight: CGFloat { compact ? rowHeight * CGFloat(compactLines) + 16 : max(220, rowHeight * 2 + 122) }
    var minimumWindowSize: NSSize { NSSize(width: 380, height: minimumWindowHeight) }
    var windowHeight: CGFloat { max(minimumWindowHeight, compact ? rowHeight * CGFloat(compactLines) + 16 : rowHeight * CGFloat(visibleLines) + 122) }
    private func save(_ value: Any, _ key: String) { if !temporary { defaults.set(value, forKey: "overlay.\(key)") } }

    func resetAppearance() {
        visibleLines = 5; compactLines = 2; fontSize = 20; backgroundOpacity = 0.62
        fontStyle = .system; customFontName = ""
        appearance = .system; accent = .primary; centered = true; compact = false; karaoke = true
        lyricColorChoice = .primary; lyricColorHex = "FFFFFF"; highlightColorHex = "FFFFFF"; highlightStyle = .music
    }
}

struct SettingsView: View {
    var importLyrics: () -> Void
    @EnvironmentObject var settings: OverlaySettings
    @EnvironmentObject var store: LyricsStore
    var body: some View {
        TabView(selection: $settings.selectedTab) {
            VStack(spacing: 0) {
                LyricAppearancePreview().padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                Form {
                    Section("字体") {
                        Picker("歌词字体", selection: $settings.fontStyle) {
                            ForEach(LyricFontStyle.allCases) { Text($0.title).tag($0) }
                        }
                        HStack {
                            if settings.fontStyle == .custom {
                                Text(settings.fontDisplayName).foregroundStyle(.secondary).lineLimit(1)
                                if !settings.customFontAvailable {
                                    Text("原字体不可用，暂用系统字体").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("选择本机字体…") { LyricFontPanel.shared.show(for: settings) }
                        }
                        LabeledContent("歌词字号") {
                            Slider(value: $settings.fontSize, in: 14...28, step: 1).accessibilityLabel("歌词字号")
                            Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 24)
                        }
                    }
                    Section("颜色与高亮") {
                        LyricColorControl(title: "歌词颜色", choice: $settings.lyricColorChoice, hex: $settings.lyricColorHex)
                        LyricColorControl(title: "高亮颜色", choice: $settings.accent, hex: $settings.highlightColorHex)
                        Picker("高亮风格", selection: $settings.highlightStyle) {
                            ForEach(LyricHighlightStyle.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("随播放进度点亮歌词", isOn: $settings.karaoke)
                            .help(settings.followMusicLyrics ? store.musicHighlightDescription(progress: settings.karaoke) : "逐词歌词按词时间点亮，逐句歌词显示估算的句内进度。")
                    }
                    Section("显示") {
                        Picker("显示模式", selection: $settings.appearance) {
                            ForEach(OverlayAppearance.allCases) { Text($0.title).tag($0) }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("背景浓度")
                                Spacer()
                                Text(settings.backgroundOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            }
                            Slider(value: $settings.backgroundOpacity, in: 0...1).accessibilityLabel("背景浓度")
                        }.accessibilityElement(children: .contain).disabled(settings.isTransparent)
                        if settings.compact {
                            Stepper("显示 \(settings.compactLines) 行", value: $settings.compactLines, in: 1...7)
                        } else {
                            Stepper("显示 \(settings.visibleLines) 行", value: $settings.visibleLines, in: 3...7)
                        }
                        Toggle("歌词居中", isOn: $settings.centered)
                        Toggle("精简模式 · 只显示歌词", isOn: $settings.compact)
                            .help("只显示歌词，可选择 1–7 行；奇数行时当前句保持居中。")
                    }
                    Button("恢复默认外观") { settings.resetAppearance() }
                }
            }
            .onDisappear { LyricFontPanel.shared.close(for: settings) }
            .tabItem { Label("外观", systemImage: "textformat.size") }
            .tag(SettingsTab.appearance)
            Form {
                LoginItemSection()
                Section("悬浮窗") {
                    Toggle("根据歌词自动扩展宽度", isOn: $settings.autoFitWidth)
                        .help("按整首歌词调整一次，不超过屏幕和窗口上限；更长的歌词在行内滚动。")
                    Button("重置窗口大小") { settings.onResetSize?() }
                    Toggle("保持在其他窗口上方", isOn: $settings.floating)
                    Toggle("在所有桌面显示", isOn: $settings.allSpaces)
                    Toggle("暂停或停止时自动隐藏", isOn: $settings.hideWhenPaused)
                    Toggle("鼠标穿透", isOn: $settings.clickThrough)
                        .help("开启后可从菜单栏取消鼠标穿透。")
                    if settings.clickThrough {
                        Text("从菜单栏取消鼠标穿透后，可重新操作歌词窗口。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("快捷键") {
                    Toggle("启用全局快捷键", isOn: $settings.globalShortcutEnabled)
                    LabeledContent("显示／隐藏悬浮窗", value: "⌃⌥L")
                    if let error = settings.globalShortcutError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("开启后，在使用其他应用时也能显示或隐藏歌词。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tabItem { Label("窗口", systemImage: "macwindow") }
            .tag(SettingsTab.behavior)
            LyricsSourcesView(importLyrics: importLyrics)
                .tabItem { Label("词源", systemImage: "text.book.closed") }
                .tag(SettingsTab.sources)
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 560, height: 680)
    }
}

private struct LyricColorControl: View {
    let title: String
    @Binding var choice: LyricAccent
    @Binding var hex: String
    var body: some View {
        Picker(title, selection: $choice) {
            ForEach(LyricAccent.allCases) { color in Text(color.title).tag(color) }
        }
        if choice == .custom {
            ColorPicker("自选\(title)", selection: Binding(get: {
                LyricRGB(hex: hex)?.color ?? .white
            }, set: { color in
                if let rgb = LyricRGB(color: NSColor(color)) { hex = rgb.hex }
            }), supportsOpacity: false)
        }
    }
}

private struct LyricsSourcesView: View {
    var importLyrics: () -> Void
    @EnvironmentObject var settings: OverlaySettings
    @EnvironmentObject var store: LyricsStore

    var body: some View {
        Form {
            Section("歌词来源") {
                LabeledContent("当前词源", value: store.currentSourceTitle)
                Toggle("同步 Apple Music 歌词", isOn: $settings.followMusicLyrics)
                    .help("下次启动沿用当前选择。支持逐词、逐句和静态的 Music 本地歌词；名称不一致时查询 Apple 公开歌曲目录确认身份。")
                Toggle("自动匹配词源", isOn: $settings.automaticSourceFallback)
                    .help("优先使用 Music；无可用歌词、读取失败或只有静态歌词时，自动寻找其他词源。手动指定的单曲词源不自动切换。")
                if settings.automaticSourceFallback {
                    Text("回退时会向已启用的歌词服务查询歌名、歌手和专辑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("本首歌曲词源", selection: Binding(get: { store.selectedTrackSource }, set: { store.setTrackSource($0) })) {
                    ForEach(TrackLyricsSource.allCases) { Text($0.title).tag($0) }
                }.disabled(!store.hasTrack)
                Text(store.sourceSelectionHint).font(.caption).foregroundStyle(.secondary)
                if store.appleMusicSyncEnabled {
                    Picker("高亮方式", selection: $settings.karaoke) {
                        Text("逐句").tag(false)
                        Text("逐字").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(store.musicHighlightDescription(progress: settings.karaoke))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.appleMusicSyncEnabled {
                Section("本地歌词") {
                    if !store.musicCacheHint.isEmpty {
                        Text(store.musicCacheHint).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("授权读取歌词…") { store.chooseMusicLyricsCache() }
                            .disabled(store.selectingMusicCache)
                        Button("重新读取") { store.refreshLyrics() }
                            .disabled(!store.hasTrack || store.musicCacheChecking)
                        if store.musicCacheChecking { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                Section("歌词操作") {
                    HStack {
                        Button("重新匹配歌词") { store.refreshLyrics() }
                            .disabled(!store.hasTrack || store.phase == .loading)
                        Button("导入歌词…", action: importLyrics)
                            .disabled(!store.canImportLyrics)
                    }
                }
            }
            Section("歌词时间校准") {
                LabeledContent("当前歌曲", value: store.hasTrack ? store.title : "尚未播放")
                    .lineLimit(1)
                TimingCalibrationControls()
                Text(store.calibrationDescription).font(.caption).foregroundStyle(.secondary)
            }
            LyricsCredentialSection()
        }
    }
}
