import SwiftUI

enum SettingsTab: Hashable { case appearance, behavior, sources }

enum OverlayAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, transparent
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色"; case .transparent: "透明" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark, .transparent: .dark } }
}

enum LyricAccent: String, CaseIterable, Identifiable {
    case primary, rose, mint, blue
    var id: String { rawValue }
    var title: String { switch self { case .primary: "原色"; case .rose: "玫瑰"; case .mint: "薄荷"; case .blue: "海蓝" } }
    var color: Color { switch self { case .primary: .primary; case .rose: .pink; case .mint: .mint; case .blue: .blue } }
}

@MainActor
final class OverlaySettings: ObservableObject {
    @Published var selectedTab: SettingsTab = .appearance
    private let defaults: UserDefaults
    private let temporary: Bool
    @Published var visibleLines: Int { didSet { save(visibleLines, "visibleLines"); onLayoutChange?() } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize"); onLayoutChange?() } }
    @Published var backgroundOpacity: Double { didSet { save(backgroundOpacity, "backgroundOpacity") } }
    @Published var appearance: OverlayAppearance { didSet { save(appearance.rawValue, "appearance"); onBehaviorChange?() } }
    @Published var accent: LyricAccent { didSet { save(accent.rawValue, "accent") } }
    @Published var centered: Bool { didSet { save(centered, "centered") } }
    @Published var compact: Bool { didSet { save(compact, "compact"); onLayoutChange?() } }
    @Published var karaoke: Bool { didSet { save(karaoke, "karaoke") } }
    @Published var followMusicLyrics: Bool { didSet { onLyricsSourceChange?() } }
    @Published var floating: Bool { didSet { save(floating, "floating"); onBehaviorChange?() } }
    @Published var allSpaces: Bool { didSet { save(allSpaces, "allSpaces"); onBehaviorChange?() } }
    @Published var clickThrough: Bool { didSet { save(clickThrough, "clickThrough"); onBehaviorChange?() } }
    @Published var hideWhenPaused: Bool { didSet { save(hideWhenPaused, "hideWhenPaused"); onBehaviorChange?() } }
    @Published var globalShortcutEnabled: Bool { didSet { save(globalShortcutEnabled, "globalShortcutEnabled"); onShortcutChange?() } }
    @Published var globalShortcutError: String?
    var onLayoutChange: (() -> Void)?
    var onBehaviorChange: (() -> Void)?
    var onLyricsSourceChange: (() -> Void)?
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
        fontSize = min(max(number("fontSize", 20), 14), 28)
        backgroundOpacity = min(max(number("backgroundOpacity", 0.62), 0), 1)
        appearance = temporary ? .system : (OverlayAppearance(rawValue: defaults.string(forKey: "overlay.appearance") ?? "") ?? .system)
        accent = temporary ? .primary : (LyricAccent(rawValue: defaults.string(forKey: "overlay.accent") ?? "") ?? .primary)
        centered = flag("centered", true)
        compact = flag("compact", false)
        karaoke = flag("karaoke", true)
        // Music 本地歌词按次启用，不沿用上一轮运行或旧版保存的开关。
        followMusicLyrics = false
        floating = flag("floating", true)
        allSpaces = flag("allSpaces", true)
        clickThrough = flag("clickThrough", false)
        hideWhenPaused = flag("hideWhenPaused", false)
        globalShortcutEnabled = flag("globalShortcutEnabled", false)
    }

    var rowHeight: CGFloat { CGFloat(fontSize) * 1.55 + 8 }
    var isTransparent: Bool { appearance == .transparent }
    var minimumWindowHeight: CGFloat { compact ? 72 : 180 }
    var windowHeight: CGFloat { compact ? rowHeight * 2 + 16 : rowHeight * CGFloat(visibleLines) + 122 }
    private func save(_ value: Any, _ key: String) { if !temporary { defaults.set(value, forKey: "overlay.\(key)") } }

    func resetAppearance() {
        visibleLines = 5; fontSize = 20; backgroundOpacity = 0.62
        appearance = .system; accent = .primary; centered = true; compact = false; karaoke = true
    }
}

struct SettingsView: View {
    var importLyrics: () -> Void
    @EnvironmentObject var settings: OverlaySettings
    @EnvironmentObject var store: LyricsStore
    var body: some View {
        TabView(selection: $settings.selectedTab) {
            Form {
                Section("外观") {
                    Picker("显示模式", selection: $settings.appearance) {
                        ForEach(OverlayAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("当前句颜色", selection: $settings.accent) {
                        ForEach(LyricAccent.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("背景浓度")
                            Spacer()
                            Text(settings.backgroundOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                        Slider(value: $settings.backgroundOpacity, in: 0...1).accessibilityLabel("背景浓度")
                    }.accessibilityElement(children: .contain).disabled(settings.isTransparent)
                }
                Section("排版") {
                    LabeledContent("歌词字号") {
                        Slider(value: $settings.fontSize, in: 14...28, step: 1).accessibilityLabel("歌词字号")
                        Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 24)
                    }
                    Stepper("显示 \(settings.visibleLines) 行", value: $settings.visibleLines, in: 3...7)
                        .disabled(settings.compact)
                    Toggle("歌词居中", isOn: $settings.centered)
                    Toggle("精简模式 · 只显示歌词", isOn: $settings.compact)
                        .help("仅显示两行歌词，可直接拖动；从菜单栏恢复完整模式。")
                    Toggle("随播放进度点亮歌词", isOn: $settings.karaoke)
                        .help(settings.followMusicLyrics ? store.musicHighlightDescription(progress: settings.karaoke) : "逐词歌词按词时间点亮，逐句歌词显示估算的句内进度。")
                }
                Button("恢复默认外观") { settings.resetAppearance() }
            }
            .tabItem { Label("外观", systemImage: "textformat.size") }
            .tag(SettingsTab.appearance)
            Form {
                LoginItemSection()
                Section("悬浮窗") {
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
        .frame(width: 520, height: 550)
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
                    .help("每次启动默认关闭。读取 Music 本地歌词时间轴，无需辅助功能权限。")
                if settings.followMusicLyrics {
                    Picker("高亮方式", selection: $settings.karaoke) {
                        Text("逐句").tag(false)
                        Text("逐字").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(store.musicHighlightDescription(progress: settings.karaoke))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.followMusicLyrics {
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
            LyricsCredentialSection()
        }
    }
}
