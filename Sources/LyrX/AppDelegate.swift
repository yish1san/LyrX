import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 透明悬浮面板：无边框、置顶、全 Space 可见、可拖拽移动、可调整大小、不抢焦点。
/// 不使用 .titled：标题栏会在窗口顶部产生约 28pt 的不可见区域（SwiftUI 按
/// contentLayoutRect 内缩根视图），导致窗口实际范围大于可见内容。
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 边缘 8pt 缩放；其余点击正常交给 SwiftUI 控件。
    private let edgeMargin: CGFloat = 8
    var lyricsOnly = false

    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left   = ResizeEdges(rawValue: 1 << 0)
        static let right  = ResizeEdges(rawValue: 1 << 1)
        static let top    = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    /// 无边框窗口自行处理边缘缩放，不能吞掉按钮、滚动和歌词点击事件。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let edges = resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty {
                runResizeSession(edges: edges)
                return
            }
            if lyricsOnly { performDrag(with: event); return }
        }
        super.sendEvent(event)
    }

    private func resizeEdges(at loc: NSPoint) -> ResizeEdges {
        var edges: ResizeEdges = []
        if loc.x < edgeMargin { edges.insert(.left) }
        if loc.x > frame.width - edgeMargin { edges.insert(.right) }
        if loc.y < edgeMargin { edges.insert(.bottom) } // AppKit 坐标系 y 向上
        if loc.y > frame.height - edgeMargin { edges.insert(.top) }
        return edges
    }

    /// 模态事件循环实现边缘缩放，含 min/max 尺寸约束。
    private func runResizeSession(edges: ResizeEdges) {
        let initialFrame = frame
        let initialMouse = NSEvent.mouseLocation
        while true {
            guard let ev = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .default, dequeue: true
            ) else { continue }
            if ev.type == .leftMouseUp { break }

            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - initialMouse.x
            let dy = mouse.y - initialMouse.y
            var f = initialFrame

            if edges.contains(.right) {
                f.size.width = (initialFrame.width + dx)
                    .clamped(to: minSize.width...maxSize.width)
            }
            if edges.contains(.left) {
                f.size.width = (initialFrame.width - dx)
                    .clamped(to: minSize.width...maxSize.width)
                f.origin.x = initialFrame.maxX - f.size.width
            }
            if edges.contains(.top) {
                f.size.height = (initialFrame.height + dy)
                    .clamped(to: minSize.height...maxSize.height)
            }
            if edges.contains(.bottom) {
                f.size.height = (initialFrame.height - dy)
                    .clamped(to: minSize.height...maxSize.height)
                f.origin.y = initialFrame.maxY - f.size.height
            }
            setFrame(f, display: true, animate: false)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var visibilityMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var timingWindow: NSWindow?
    private let globalShortcut = GlobalShortcut()
    private var wantsVisible = UserDefaults.standard.object(forKey: "overlay.isVisible") as? Bool ?? true
    private var screenObserver: NSObjectProtocol?
    private let preview = AppIdentity.isPreview
    let store = LyricsStore()
    let settings: OverlaySettings = {
        if AppIdentity.isPreview {
            let settings = OverlaySettings(temporary: true)
            settings.followMusicLyrics = CommandLine.arguments.contains("--preview-apple-lines")
            return settings
        }
        return OverlaySettings()
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIdentity.applicationIcon { NSApp.applicationIconImage = icon }
        let actions = OverlayActions(settings: { [weak self] in
                                         guard let self else { return }
                                         if store.appleMusicSyncEnabled { settings.selectedTab = .sources }
                                         openSettings()
                                     },
                                     importLyrics: { [weak self] in self?.importLyrics() },
                                     hide: { [weak self] in self?.setVisible(false) },
                                     resetPosition: { [weak self] in self?.resetPosition() },
                                     timing: { [weak self] in self?.openTiming() })
        let content = LyricsView(actions: actions).environmentObject(store).environmentObject(settings)

        // 根视图订阅设置，保证系统、浅色、深色选择即时生效。
        let hosting = InteractiveHostingView(rootView: AppearanceRoot(content: content).environmentObject(settings))
        // 窗口大小由面板管理，避免 SwiftUI 根据旧布局提高 minSize，卡住精简模式高度。
        hosting.sizingOptions = []
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: settings.windowHeight),
                             styleMask: [.nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "LyrX"
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 380, height: settings.minimumWindowHeight)
        panel.maxSize = NSSize(width: 1000, height: 900)
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        if !preview, let saved = UserDefaults.standard.string(forKey: "overlay.windowFrame") {
            var frame = NSRectFromString(saved)
            if settings.compact { frame.size.height = settings.windowHeight }
            if frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
               frame.width >= 380, frame.height >= settings.minimumWindowHeight { panel.setFrame(frame, display: true) }
            else { resetPosition() }
        } else { resetPosition() }
        constrainToScreen()
        panel.delegate = self
        settings.onLayoutChange = { [weak self] in self?.applyWindowHeight(); self?.applyBehavior() }
        settings.onBehaviorChange = { [weak self] in self?.applyBehavior() }
        settings.onLyricsSourceChange = { [weak self] in
            guard let self else { return }
            store.setAppleMusicSyncEnabled(settings.followMusicLyrics)
        }
        store.onPlaybackChange = { [weak self] in self?.updateVisibility() }
        setupMenu()
        settings.onShortcutChange = { [weak self] in self?.updateGlobalShortcut() }
        updateGlobalShortcut()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.constrainToScreen() }
        }
        if preview { wantsVisible = true }
        store.start(preview: preview)
        store.setAppleMusicSyncEnabled(settings.followMusicLyrics)
        applyBehavior()
    }

    func applicationWillTerminate(_ notification: Notification) { globalShortcut.stop(); store.stop(); saveFrame() }
    func windowDidMove(_ notification: Notification) { if notification.object as? NSWindow === panel { saveFrame() } }
    func windowDidResize(_ notification: Notification) { if notification.object as? NSWindow === panel { saveFrame() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { setVisible(false); return false }
        return true
    }
    private func saveFrame() {
        if !preview, let panel { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "overlay.windowFrame") }
    }
    private func applyWindowHeight() {
        guard let panel else { return }
        panel.minSize = NSSize(width: 380, height: settings.minimumWindowHeight)
        var frame = panel.frame
        if let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(settings.windowHeight, bounds.height)
            frame.origin.y = min(max(frame.origin.y, bounds.minY), bounds.maxY - frame.height)
        } else { frame.size.height = settings.windowHeight }
        // 先算好最终边界再动画，动画之后立即读 frame 会取到中间尺寸并中断动画。
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func applyBehavior() {
        guard let panel else { return }
        panel.hasShadow = !settings.isTransparent
        panel.lyricsOnly = settings.compact
        panel.invalidateShadow()
        panel.level = settings.floating ? .floating : .normal
        panel.collectionBehavior = settings.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = settings.clickThrough
        updateVisibility()
    }
    private func updateVisibility() {
        let autoHidden = settings.hideWhenPaused && !store.playing && store.connectionError == nil
        if wantsVisible && !autoHidden { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
        visibilityMenuItem?.title = panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗"
    }
    private func setVisible(_ value: Bool) {
        wantsVisible = value
        if value && settings.hideWhenPaused && !store.playing { settings.hideWhenPaused = false }
        if !preview { UserDefaults.standard.set(value, forKey: "overlay.isVisible") }
        updateVisibility()
    }
    private func constrainToScreen() {
        guard let panel, let fallback = NSScreen.main else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? fallback
        let bounds = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(max(frame.width, panel.minSize.width), min(1000, bounds.width))
        frame.size.height = min(max(frame.height, panel.minSize.height), min(900, bounds.height))
        frame.origin.x = min(max(frame.origin.x, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, bounds.minY), bounds.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }
    private func resetPosition() {
        guard let panel, let screen = NSScreen.main else { return }
        let bounds = screen.visibleFrame
        let width: CGFloat = min(480, bounds.width)
        let height = min(settings.windowHeight, bounds.height)
        panel.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.minY + min(72, max(0, bounds.height - height)),
                              width: width, height: height), display: true)
        saveFrame()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "LyrX 歌词")
        image?.isTemplate = true
        statusItem.button?.image = image; statusItem.button?.toolTip = "LyrX · Apple Music 歌词"
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        let main = NSMenu()
        let root = NSMenuItem(title: "LyrX", action: nil, keyEquivalent: ""); let appMenu = NSMenu(title: "LyrX")
        root.submenu = appMenu; main.addItem(root)
        appMenu.addItem(item("关于 LyrX", #selector(showAbout)))
        appMenu.addItem(.separator())
        let visibility = item("显示悬浮窗", #selector(togglePanel), "l")
        visibilityMenuItem = visibility; appMenu.addItem(visibility)
        appMenu.addItem(item("设置…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出 LyrX", #selector(quitApp), "q"))
        // 标准编辑命令走响应链，确保设置输入框和文件选择器能复制、粘贴和撤销。
        let edit = NSMenu(title: "编辑")
        for (title, action, key, shifted) in [
            ("撤销", "undo:", "z", false), ("重做", "redo:", "z", true),
            ("剪切", "cut:", "x", false), ("复制", "copy:", "c", false),
            ("粘贴", "paste:", "v", false), ("全选", "selectAll:", "a", false)
        ] {
            if title == "剪切" { edit.addItem(.separator()) }
            let command = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            command.keyEquivalentModifierMask = shifted ? [.command, .shift] : [.command]
            edit.addItem(command)
        }
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editRoot.submenu = edit; main.addItem(editRoot)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(item("关闭窗口", #selector(closeCurrentWindow), "w"))
        let windowRoot = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowRoot.submenu = windowMenu; main.addItem(windowRoot)
        NSApp.mainMenu = main
    }
    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command]
        return item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = NSMenuItem(title: store.hasTrack ? "\(store.title) · \(store.artist)" : "LyrX · Apple Music", action: nil, keyEquivalent: "")
        now.isEnabled = false; menu.addItem(now); menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗", #selector(togglePanel), "l"))
        let lock = item("鼠标穿透", #selector(toggleClickThrough)); lock.state = settings.clickThrough ? .on : .off; menu.addItem(lock)
        let compact = item("精简模式", #selector(toggleCompact)); compact.state = settings.compact ? .on : .off; menu.addItem(compact)
        let mirror = item("同步 Apple Music 歌词", #selector(toggleMusicLyrics)); mirror.state = settings.followMusicLyrics ? .on : .off; menu.addItem(mirror)
        let transparent = item("透明主题", #selector(toggleTransparent)); transparent.state = settings.isTransparent ? .on : .off; menu.addItem(transparent)
        menu.addItem(item("重置窗口位置", #selector(resetWindow)))
        let timing = item("歌词时间校准…", #selector(openTiming)); timing.isEnabled = store.canCalibrate; menu.addItem(timing)
        menu.addItem(.separator())
        menu.addItem(item("打开 Apple Music", #selector(openMusic)))
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(item("关于 LyrX", #selector(showAbout)))
        menu.addItem(item("退出 LyrX", #selector(quitApp), "q"))
        menu.autoenablesItems = false
    }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 550),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "LyrX 设置"; window.titlebarSeparatorStyle = .none
            window.contentView = NSHostingView(rootView: SettingsView(importLyrics: { [weak self] in self?.importLyrics() })
                .environmentObject(settings).environmentObject(store))
            window.delegate = self
            window.level = .floating; window.isReleasedWhenClosed = false; window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: AppIdentity.aboutPanelOptions)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func updateGlobalShortcut() {
        globalShortcut.stop()
        settings.globalShortcutError = nil
        guard settings.globalShortcutEnabled else { return }
        if !globalShortcut.start(action: { [weak self] in self?.togglePanel() }) {
            settings.globalShortcutError = "⌃⌥L 当前不可用，可能已被其他应用占用。请关闭后重试。"
        }
    }
    @objc private func closeCurrentWindow() {
        guard let window = NSApp.keyWindow else { return }
        if window === panel { setVisible(false) }
        else { window.performClose(nil) }
    }
    @objc private func openTiming() {
        guard store.canCalibrate else { return }
        if timingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "歌词时间校准"
            window.contentView = NSHostingView(rootView: TimingCalibrationView().environmentObject(store))
            window.level = .floating; window.isReleasedWhenClosed = false; window.center()
            timingWindow = window
        }
        timingWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func importLyrics() {
        guard store.canImportLyrics else { return }
        let trackID = store.trackID
        let picker = NSOpenPanel()
        picker.title = "为“\(store.title)”导入歌词"
        picker.message = "支持 UTF-8 / UTF-16 的 .lrc 时间轴歌词或 .txt 纯文本（最大 2 MB）。"
        picker.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        picker.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            guard self.store.trackID == trackID else { self.store.reportActionError("歌曲已切换，请为当前歌曲重新导入。"); return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { self.store.reportActionError("文件超过 2 MB，请选择歌词文本文件。"); return }
                var encoding = String.Encoding.utf8
                self.store.importLyrics(try String(contentsOf: url, usedEncoding: &encoding))
            } catch { self.store.reportActionError("无法读取歌词文件：\(error.localizedDescription)") }
        }
    }
    @objc private func togglePanel() { setVisible(!panel.isVisible) }
    @objc private func toggleClickThrough() { settings.clickThrough.toggle() }
    @objc private func toggleTransparent() { settings.appearance = settings.isTransparent ? .system : .transparent }
    @objc private func toggleMusicLyrics() { settings.followMusicLyrics.toggle() }
    @objc private func toggleCompact() { settings.compact.toggle() }
    @objc private func resetWindow() { resetPosition(); setVisible(true) }
    @objc private func openMusic() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

private struct AppearanceRoot<Content: View>: View {
    @EnvironmentObject var settings: OverlaySettings
    var content: Content
    var body: some View { content.preferredColorScheme(settings.appearance.colorScheme) }
}
