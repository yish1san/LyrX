import SwiftUI
import AppKit

struct OverlayActions {
    var settings: () -> Void
    var importLyrics: () -> Void
    var hide: () -> Void
    var resetPosition: () -> Void
    var timing: () -> Void
}

private struct NativeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 只把歌曲信息区作为拖动区域，按钮、歌词点击和滚动照常工作。
private struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct ScrollObserver: NSViewRepresentable {
    var onScroll: () -> Void
    final class ObserverView: NSView {
        var callback: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, let window = self.window, event.window === window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                   abs(event.scrollingDeltaY) > 0 { self.callback?() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> ObserverView { let view = ObserverView(); view.callback = onScroll; return view }
    func updateNSView(_ view: ObserverView, context: Context) { view.callback = onScroll }
}

private struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : 0.055), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LyricRow: View {
    let line: LyricLine
    let current: Bool
    let past: Bool
    let end: Double
    let clock: PlaybackClock
    let playing: Bool
    let fontSize: Double
    let accent: Color
    let karaoke: Bool
    let centered: Bool
    let compact: Bool
    let transparent: Bool
    var body: some View {
        Group {
            if current && karaoke {
                ProgressLyricText(plan: LyricHighlightPlan(line: line, end: end),
                                  clock: clock, playing: playing, accent: accent)
            } else {
                Text(line.text).foregroundStyle(current ? accent : .primary.opacity(transparent ? (past ? 0.7 : 0.6) : (past ? 0.48 : 0.34)))
            }
        }
        .font(.system(size: fontSize, weight: current ? .semibold : .medium, design: .rounded))
        .multilineTextAlignment(centered ? .center : .leading)
        .lineLimit(compact ? 1 : 3)
        .minimumScaleFactor(compact ? 0.65 : 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .accessibilityAddTraits(current ? .isSelected : [])
        .transaction { if !karaoke { $0.animation = nil } }
    }

}

private struct ProgressLyricText: View {
    let plan: LyricHighlightPlan
    @ObservedObject var clock: PlaybackClock
    let playing: Bool
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if playing {
                TimelineView(.periodic(from: .now, by: reduceMotion ? 0.1 : 1 / 30)) { context in
                    text(at: context.date)
                }
            } else { text(at: Date()) }
        }
        .transaction { $0.animation = nil }
    }

    private func text(at date: Date) -> Text {
        let position = clock.lyricPosition(at: date)
        let text = plan.glyphs.reduce(into: AttributedString()) { result, glyph in
            var fragment = AttributedString(glyph.text)
            fragment.foregroundColor = accent.opacity(0.28 + glyph.progress(at: position) * 0.72)
            result += fragment
        }
        return Text(text)
    }
}

struct LyricsView: View {
    @EnvironmentObject var store: LyricsStore
    @EnvironmentObject var settings: OverlaySettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    @State private var showTiming = false
    let actions: OverlayActions

    var body: some View {
        VStack(spacing: 0) {
            if !settings.compact {
                header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                Divider().overlay(.primary.opacity(0.035)).padding(.horizontal, 18)
            }
            if settings.compact {
                compactContent.padding(.vertical, 8)
            } else if let error = store.connectionError {
                connectionNotice(error)
            } else {
                lyricsArea.frame(maxHeight: .infinity)
            }
            if !settings.compact {
                footer.padding(.horizontal, 18).padding(.bottom, 12).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(settings.isTransparent ? 0.95 : 0), radius: 2, x: 0, y: 1)
        .background {
            if !settings.isTransparent {
                ZStack {
                    if !reduceTransparency { NativeMaterial() }
                    (scheme == .dark ? Color.black : Color.white)
                        .opacity(reduceTransparency ? 1 : settings.backgroundOpacity * 0.65)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if !settings.isTransparent {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(scheme == .dark ? 0.14 : 0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { overlayMenu }
        .tint(.pink)
        .alert("操作未完成", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.dismissActionError() } })) {
            Button("好") { store.dismissActionError() }
        } message: { Text(store.actionError ?? "") }
        .onChange(of: store.lyricsVersion) { _, _ in following = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 11) {
                if let artwork = store.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("\(store.title) 专辑封面")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.hasTrack ? store.title : "LyrX")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(store.hasTrack ? (store.artist.isEmpty ? "Apple Music" : store.artist) : "为 Apple Music 而生")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .overlay { WindowDragRegion() }
            .help("拖动歌曲信息以移动悬浮窗")
            HStack(spacing: 4) {
                Button { store.control(.previous) } label: { Image(systemName: "backward.end.fill") }
                    .help("上一首").accessibilityLabel("上一首")
                Button { store.control(.playPause) } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill") }
                    .help(store.playing ? "暂停" : "播放").accessibilityLabel(store.playing ? "暂停" : "播放")
                Button { store.control(.next) } label: { Image(systemName: "forward.end.fill") }
                    .help("下一首").accessibilityLabel("下一首")
            }
            .buttonStyle(OverlayButtonStyle()).disabled(!store.canControl)
        }
    }

    @ViewBuilder private var lyricsArea: some View {
        if store.synced && !store.lines.isEmpty {
            if settings.compact { compactLyrics }
            else { scrollingLyrics.id(store.lyricsVersion) }
        } else if let plain = store.plainLyrics {
            ScrollView {
                Text(plain).font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
                    .multilineTextAlignment(settings.centered ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: settings.centered ? .center : .leading)
                    .textSelection(.enabled).padding(20)
            }.scrollIndicators(.hidden)
        } else { emptyState }
    }

    private var scrollingLyrics: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if store.currentIndex < 0 {
                            intro.frame(height: settings.rowHeight).id(-1)
                        }
                        ForEach(Array(store.lines.enumerated()), id: \.offset) { index, line in
                            Button {
                                following = true
                                store.control(.seek(max(0, line.time - store.timingOffset)))
                            } label: {
                                row(line, at: index).padding(.vertical, 7)
                                    .frame(minHeight: settings.rowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(!store.canControl)
                            .help("跳到这一句").id(index)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, max(0, (geometry.size.height - settings.rowHeight) / 2))
                }
                .scrollIndicators(.hidden)
                .background(ScrollObserver { following = false })
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.13),
                                           .init(color: .black, location: 0.87), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(scrollIndex, anchor: .center) } }
                .onChange(of: store.currentIndex) { _, index in if following { scroll(proxy, to: index) } }
                .onChange(of: following) { _, value in if value { scroll(proxy, to: store.currentIndex) } }
                .onChange(of: geometry.size) { _, _ in if following { proxy.scrollTo(scrollIndex, anchor: .center) } }
            }
        }
    }
    private var scrollIndex: Int { max(-1, store.currentIndex) }
    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        let target = max(-1, index)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(target, anchor: .center) }
    }
    @ViewBuilder private var compactContent: some View {
        if let error = store.connectionError {
            Text("无法连接 Apple Music").font(.system(size: settings.fontSize)).help(error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.synced && !store.lines.isEmpty { compactLyrics }
        else if let plain = store.plainLyrics {
            Text(plain).font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
                .multilineTextAlignment(settings.centered ? .center : .leading).lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settings.centered ? .center : .leading)
                .padding(.horizontal, 24)
        } else {
            Text(store.appleMusicSyncEnabled && store.hasTrack ? (store.phase == .loading ? "正在读取本地歌词…" : "暂无 Music 本地歌词") : store.phase == .loading ? "正在匹配歌词…" : store.phase == .notFound ? "未找到歌词" : store.phase == .failed ? "歌词获取失败" : "播放音乐后显示歌词")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactLyrics: some View {
        VStack(spacing: 10) {
            if store.currentIndex < 0 { intro }
            else { row(store.lines[store.currentIndex], at: store.currentIndex) }
            let next = store.currentIndex + 1
            if next < store.lines.count { row(store.lines[next], at: next) }
        }
        .padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var intro: some View {
        HStack(spacing: 7) {
            ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.5)).frame(width: 5, height: 5) }
        }
        .frame(maxWidth: .infinity, alignment: settings.centered ? .center : .leading)
        .accessibilityLabel("前奏")
    }
    private func row(_ line: LyricLine, at index: Int) -> some View {
        LyricRow(line: line, current: index == store.currentIndex, past: index < store.currentIndex,
                 end: LyricHighlightPlan.end(of: line, nextTime: index + 1 < store.lines.count ? store.lines[index + 1].time : nil,
                                            duration: store.duration),
                 clock: store.clock, playing: store.playing && store.connectionError == nil,
                 fontSize: settings.fontSize, accent: settings.accent.color, karaoke: settings.karaoke && store.supportsProgressHighlight, centered: settings.centered,
                 compact: settings.compact, transparent: settings.isTransparent)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !following && store.synced && !settings.compact {
                Button { following = true } label: { Label("继续跟随", systemImage: "location.fill") }
                    .buttonStyle(.plain).foregroundStyle(.pink)
            } else {
                Circle().fill(store.playing ? Color.green.opacity(0.8) : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                    .help(store.playing ? "正在播放" : "已暂停")
                if !footerText.isEmpty { Text(footerText).lineLimit(1).truncationMode(.tail) }
            }
            Spacer(minLength: 4)
            Button { showTiming.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(store.timingOffset == 0 ? "校准" : String(format: "%+.2fs", store.timingOffset)).monospacedDigit()
                }
            }
            .buttonStyle(.plain).disabled(!store.canCalibrate)
            .help("调整本首歌的歌词时间差")
            .popover(isPresented: $showTiming, arrowEdge: .bottom) { timingPopover }
            Menu { overlayMenu } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作").accessibilityLabel("更多操作")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .frame(height: 20)
    }
    @ViewBuilder private var overlayMenu: some View {
        Toggle("精简模式 · 只显示歌词", isOn: $settings.compact)
        Toggle("透明主题", isOn: Binding(get: { settings.isTransparent }, set: { settings.appearance = $0 ? .transparent : .system }))
        Toggle("鼠标穿透", isOn: $settings.clickThrough)
        Toggle("同步 Apple Music 歌词", isOn: $settings.followMusicLyrics)
        Divider()
        Button("歌词时间校准…", systemImage: "timer") { actions.timing() }.disabled(!store.canCalibrate)
        Button(store.appleMusicSyncEnabled ? "重新读取 Music 歌词" : "重新匹配歌词", systemImage: "arrow.clockwise") { store.refreshLyrics() }
            .disabled(!store.hasTrack || (!store.appleMusicSyncEnabled && store.phase == .loading))
        Button("导入歌词…", systemImage: "doc.badge.plus") { actions.importLyrics() }.disabled(!store.canImportLyrics)
        Divider()
        Button("重置窗口位置") { actions.resetPosition() }
        Button("设置…", systemImage: "gearshape") { actions.settings() }
        Button("隐藏悬浮窗", systemImage: "eye.slash") { actions.hide() }
    }

    private var footerText: String {
        store.overlayStatusText
    }
    private var timingPopover: some View { TimingCalibrationView().environmentObject(store) }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.phase == .loading && !store.appleMusicSyncEnabled { ProgressView().controlSize(.small) }
            else { Image(systemName: emptyIcon).font(.system(size: 25, weight: .light)).foregroundStyle(.tertiary) }
            Text(emptyTitle).font(.system(size: 14, weight: .medium))
            Text(emptyDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(3)
            if store.appleMusicSyncEnabled && store.hasTrack {
                Button("同步设置…") { actions.settings() }.controlSize(.small)
            } else if store.phase == .failed || store.phase == .notFound {
                HStack {
                    Button("重试") { store.refreshLyrics() }
                    Button("导入歌词…") { actions.importLyrics() }
                }.controlSize(.small).padding(.top, 3)
            } else if !store.running {
                Button("打开 Apple Music") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")) }
                    .controlSize(.small).padding(.top, 3)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyIcon: String { store.phase == .failed ? "wifi.exclamationmark" : store.phase == .notFound ? "text.magnifyingglass" : "music.note" }
    private var emptyTitle: String {
        if store.appleMusicSyncEnabled && store.hasTrack {
            return store.phase == .loading ? "正在读取 Music 本地歌词" : "暂无 Music 本地歌词"
        }
        return switch store.phase {
        case .loading: "正在寻找这一首的歌词"
        case .notFound: "暂时没有找到歌词"
        case .failed: "歌词暂时无法获取"
        default: store.running ? "等一首喜欢的歌" : "让歌词陪你听歌"
        }
    }
    private var emptyDescription: String {
        if store.appleMusicSyncEnabled && store.hasTrack { return store.musicCacheHint }
        return switch store.phase {
        case .loading: "正在获取歌词…"
        case .failed: store.statusText
        case .notFound: "可以重新匹配，或为这首歌导入本地歌词。"
        default: "在 Apple Music 播放歌曲，歌词会自动出现在这里。"
        }
    }
    private func connectionNotice(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.secondary)
            Text("连接 Apple Music").font(.headline)
            Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("打开自动化设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
            }.controlSize(.small)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TimingCalibrationView: View {
    @EnvironmentObject var store: LyricsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("歌词时间校准").font(.headline)
            Text(store.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("此曲单独保存，Music 与其他词源分别校准。正数提前，负数延后。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { store.setTimingOffset(store.timingOffset - 0.05) } label: { Image(systemName: "minus") }
                    .disabled(store.timingOffset <= -10).accessibilityLabel("歌词延后 0.05 秒")
                Spacer()
                Text(String(format: "%+.2f 秒", store.timingOffset)).font(.title2.monospacedDigit())
                Spacer()
                Button { store.setTimingOffset(store.timingOffset + 0.05) } label: { Image(systemName: "plus") }
                    .disabled(store.timingOffset >= 10).accessibilityLabel("歌词提前 0.05 秒")
            }
            Slider(value: Binding(get: { store.timingOffset }, set: { store.setTimingOffset($0) }), in: -10...10, step: 0.05)
                .accessibilityLabel("歌词时间差")
            Button("重置为零") { store.setTimingOffset(0) }.disabled(store.timingOffset == 0)
        }.padding(20).frame(width: 280).disabled(!store.canCalibrate)
    }
}
