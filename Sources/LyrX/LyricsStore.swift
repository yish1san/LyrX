import Foundation
import Combine
import AppKit

final class PlaybackClock: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var basePosition: Double = 0
    private var baseTime = Date()
    private var duration: Double = 0
    private var playing = false
    var offset: Double = 0 { didSet { if oldValue != offset { revision &+= 1 } } }
    func update(position: Double, duration: Double, playing: Bool, at time: Date) {
        basePosition = max(0, position.isFinite ? position : 0)
        baseTime = time
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.playing = playing
        revision &+= 1
    }
    func position(at now: Date = Date()) -> Double {
        let p = max(0, basePosition + (playing ? now.timeIntervalSince(baseTime) : 0))
        return duration > 0 ? min(p, duration) : p
    }
    func lyricPosition(at now: Date = Date()) -> Double { position(at: now) + offset }
    func freeze() { basePosition = position(); baseTime = Date(); playing = false; revision &+= 1 }
}

enum LyricsPhase: Equatable { case idle, loading, ready, notFound, failed }

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage?
    private var lastArtworkData: Data?
    @Published private(set) var running = false
    @Published private(set) var playing = false
    @Published private(set) var hasTrack = false
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var synced = false
    @Published private(set) var statusText = ""
    @Published private(set) var wordSynced = false
    @Published private(set) var currentIndex = -1
    @Published private(set) var lyricsVersion = 0
    @Published private(set) var phase: LyricsPhase = .idle
    @Published private(set) var connectionError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var sourceID = ""
    @Published private(set) var timingOffset: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var appleMusicSyncEnabled = false
    @Published private(set) var musicCacheHint = ""
    @Published private(set) var musicCacheNeedsAccess = false
    @Published private(set) var musicCacheChecking = false
    @Published private(set) var selectingMusicCache = false
    private var musicSessionLyrics: [String: (result: LyricsResult, duration: Double)] = [:]
    private var musicSessionOrder: [String] = []
    private var musicCacheTimer: Timer?
    private var musicCacheTask: Task<Void, Never>?
    private var musicCacheGeneration = UUID()
    private var musicCacheDirectory: URL?
    private var musicCachePicker: NSOpenPanel?
    private var appleMusicReaderEnabled = false
    let clock = PlaybackClock()
    private let orchestrator = LyricsOrchestrator.makeDefault()
    private let cache: LyricsCache
    private let preferences: TrackPreferences
    private var monitor: MusicMonitor?
    private var boundaryTimer: Timer?
    private var lineStartTimes: [Double] = []
    private var lastTrackID = ""
    private var lastSnapshot: MusicState?
    private var fetchTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var lastNextID = ""
    private var isPreview = false
    private var started = false
    private let previewAppleLines = CommandLine.arguments.contains("--preview-apple-lines")
    var onPlaybackChange: (() -> Void)?
    var trackID: String { lastTrackID }
    var sourceTitle: String {
        switch sourceID {
        case "lrclib": "LRCLIB"
        case "netease": "网易云音乐"
        case "amll": "AMLL"
        case "qq": "QQ 音乐"
        case "musixmatch": "Musixmatch"
        case "local": "本地歌词"
        case "apple-cache": "Apple Music 本地歌词"
        case "apple-library": "Music 内嵌歌词"
        default: "自动匹配"
        }
    }
    var canControl: Bool { hasTrack && connectionError == nil }
    var currentSourceTitle: String {
        guard hasTrack else { return "暂无歌词" }
        if appleMusicSyncEnabled {
            if sourceID == "apple-cache", phase == .ready { return wordSynced ? "Apple Music（逐词）" : "Apple Music（逐句）" }
            return phase == .notFound || phase == .failed ? "暂无 Music 本地歌词" : "Apple Music（正在读取）"
        }
        return switch phase {
        case .ready: sourceTitle
        case .loading: "正在匹配…"
        case .notFound, .failed: "暂无可用歌词"
        case .idle: "暂无歌词"
        }
    }
    var canCalibrate: Bool { hasTrack && (!appleMusicSyncEnabled || hasAppleTimedLyrics) }
    var canImportLyrics: Bool { hasTrack && !appleMusicSyncEnabled }
    var hasAppleTimedLyrics: Bool { appleMusicSyncEnabled && sourceID == "apple-cache" && phase == .ready }
    var supportsProgressHighlight: Bool { !appleMusicSyncEnabled || hasAppleTimedLyrics }
    func musicHighlightDescription(progress: Bool) -> String {
        guard progress else { return "当前句整句高亮。" }
        if hasAppleTimedLyrics {
            return wordSynced ? "按 Apple Music 逐词时间点亮；未标记的字符使用句内进度。" : "按逐句时间估算逐字进度，并非原生逐词时间。"
        }
        return "已选择逐字；读到本地时间轴后启用。"
    }
    var overlayStatusText: String {
        if connectionError != nil { return "连接需要检查" }
        if appleMusicSyncEnabled && hasTrack {
            if hasAppleTimedLyrics { return playing ? "" : "已暂停" }
            return phase == .notFound || phase == .failed ? "暂无本地歌词" : "正在读取歌词…"
        }
        if phase == .loading { return "正在匹配歌词…" }
        if !hasTrack { return "" }
        if phase == .notFound { return "暂未收录" }
        if phase == .failed { return "获取失败" }
        return playing ? "" : "已暂停"
    }

    init(cache: LyricsCache = .shared, preferences: TrackPreferences? = nil) {
        self.cache = cache
        self.preferences = preferences ?? TrackPreferences()
    }

    func start(preview: Bool = false) {
        guard !started else { return }
        started = true
        isPreview = preview
        if preview { loadPreview() }
        else {
            monitor = MusicMonitor { [weak self] snapshot in
                Task { @MainActor in self?.handle(snapshot) }
            }
        }
        updateCurrentIndex()
    }
    func stop() {
        appleMusicReaderEnabled = false
        started = false
        boundaryTimer?.invalidate(); boundaryTimer = nil
        monitor = nil; fetchTask?.cancel(); prefetchTask?.cancel()
        musicCacheTimer?.invalidate(); musicCacheTimer = nil
        cancelMusicCacheRead()
    }

    // 内部入口同时供回归测试注入播放快照，不依赖 Music 或网络。
    func handle(_ s: MusicState) {
        if let error = s.scriptError {
            clock.freeze()
            boundaryTimer?.invalidate(); boundaryTimer = nil
            let message = error.contains("-1743")
                ? "请在系统设置 → 隐私与安全性 → 自动化中，允许 LyrX 控制 Music。"
                : "无法读取 Apple Music：\(error)"
            if connectionError != message { connectionError = message; onPlaybackChange?() }
            return
        }
        let recovered = connectionError != nil
        connectionError = nil
        clock.update(position: s.position, duration: s.duration, playing: s.playing, at: s.polledAt)
        lastSnapshot = s
        if s.trackID != lastTrackID || lastArtworkData != s.artworkData {
            lastArtworkData = s.artworkData
            artwork = s.artworkData.flatMap { NSImage(data: $0) }
        }
        if running != s.running { running = s.running }
        let playbackChanged = playing != s.playing
        if playbackChanged { playing = s.playing }
        if duration != s.duration { duration = s.duration }
        if hasTrack != !s.trackID.isEmpty { hasTrack = !s.trackID.isEmpty }
        if title != s.title { title = s.title }
        if artist != s.artist { artist = s.artist }
        let nextID = s.next?.trackID ?? ""
        if nextID != lastNextID { lastNextID = nextID; schedulePrefetch(next: s.next) }
        if playbackChanged || recovered { onPlaybackChange?() }
        guard s.trackID != lastTrackID else {
            if !appleMusicSyncEnabled, [.notFound, .failed].contains(phase) { _ = applyEmbeddedLyricsIfAvailable() }
            updateCurrentIndex(); return
        }
        lastTrackID = s.trackID
        fetchTask?.cancel()
        cancelMusicCacheRead()
        clearLyrics()
        actionError = nil
        if s.trackID.isEmpty { phase = .idle; return }
        if appleMusicSyncEnabled {
            waitForAppleMusicLyrics(); restoreMusicSessionLyrics(for: s); startAppleMusicReader(); return
        }
        loadAutomaticLyrics(for: s)
    }

    private func loadAutomaticLyrics(for s: MusicState) {
        let saved = preferences.entry(for: s.trackID)
        timingOffset = saved.offset.isFinite ? min(max(saved.offset, -10), 10) : 0
        clock.offset = timingOffset
        if let local = saved.lyrics { applyResult(local); return }
        phase = .loading; statusText = "正在匹配歌词…"
        fetchTask = Task { await loadLyrics(for: s) }
    }

    func setAppleMusicSyncEnabled(_ enabled: Bool, startReaders: Bool = true) {
        appleMusicReaderEnabled = startReaders
        let changed = appleMusicSyncEnabled != enabled
        appleMusicSyncEnabled = enabled
        if changed {
            fetchTask?.cancel(); prefetchTask?.cancel()
            cancelMusicCacheRead()
            clearLyrics()
            if enabled {
                waitForAppleMusicLyrics()
                if let snapshot = lastSnapshot { restoreMusicSessionLyrics(for: snapshot) }
            }
            else if isPreview { loadPreview() }
            else if let snapshot = lastSnapshot, hasTrack { loadAutomaticLyrics(for: snapshot) }
            else { phase = .idle }
        }
        if !enabled {
            musicCacheTimer?.invalidate(); musicCacheTimer = nil
            return
        }
        if isPreview, previewAppleLines { loadPreviewAppleLines() }
        startAppleMusicReader()
    }
    private func startAppleMusicReader() {
        guard appleMusicSyncEnabled, appleMusicReaderEnabled, !isPreview else { return }
        if musicCacheTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readMusicCache() }
            }
            musicCacheTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        readMusicCache()
    }
    private func cancelMusicCacheRead() {
        musicCacheGeneration = UUID()
        musicCacheTask?.cancel(); musicCacheTask = nil
        musicCacheChecking = false
    }
    private func readMusicCache(force: Bool = false) {
        guard appleMusicSyncEnabled, appleMusicReaderEnabled, !isPreview, hasTrack,
              (force || !(hasAppleTimedLyrics && wordSynced)), musicCacheTask == nil, let snapshot = lastSnapshot else { return }
        let query = LyricsQuery(track: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration)
        let directory = musicCacheDirectory ?? MusicLyricsCacheLocation.restored() ?? AppleMusicLyricsCache.defaultDirectory
        let generation = musicCacheGeneration
        musicCacheChecking = true
        musicCacheTask = Task { [weak self] in
            let lookup = await Task.detached(priority: .utility) {
                AppleMusicLyricsCache().lookup(query, directory: directory)
            }.value
            guard let self, !Task.isCancelled, generation == musicCacheGeneration else { return }
            musicCacheTask = nil
            musicCacheChecking = false
            handleMusicCacheLookup(lookup, trackID: snapshot.trackID)
        }
    }
    func handleMusicCacheLookup(_ lookup: AppleMusicCacheLookup, trackID: String) {
        guard appleMusicSyncEnabled, hasTrack, trackID == lastTrackID else { return }
        switch lookup {
        case .lyrics(let result):
            guard result.sourceID == "apple-cache", !result.lines.isEmpty, !result.isPlain else { return }
            musicCacheNeedsAccess = false
            musicCacheHint = result.isWordSynced ? "已读取 Apple Music 逐词时间。" : "已读取逐句时间，可选择估算的逐字高亮。"
            if let snapshot = lastSnapshot {
                musicSessionLyrics[trackID] = (result, snapshot.duration)
                musicSessionOrder.removeAll { $0 == trackID }; musicSessionOrder.append(trackID)
                while musicSessionOrder.count > 8 { musicSessionLyrics.removeValue(forKey: musicSessionOrder.removeFirst()) }
            }
            if hasAppleTimedLyrics, lines == result.lines, wordSynced == result.isWordSynced { return }
            applyResult(result)
        case .unavailable(let message, let needsAccess):
            musicCacheHint = message; musicCacheNeedsAccess = needsAccess
            if !hasAppleTimedLyrics {
                phase = needsAccess ? .failed : .notFound
                statusText = message
            }
        }
    }
    private func restoreMusicSessionLyrics(for snapshot: MusicState) {
        guard let saved = musicSessionLyrics[snapshot.trackID], snapshot.duration > 0,
              abs(saved.duration - snapshot.duration) <= 0.5 else { return }
        handleMusicCacheLookup(.lyrics(saved.result), trackID: snapshot.trackID)
    }
    func chooseMusicLyricsCache() {
        guard !selectingMusicCache else { return }
        let parent = NSApp.keyWindow
        let picker = NSOpenPanel()
        picker.title = "允许读取 Music 逐词歌词"
        picker.message = "请选择 ~/Library/Caches/com.apple.Music，可按 ⇧⌘G 输入路径。仅用于读取本地歌词。"
        picker.prompt = "允许读取"
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.directoryURL = AppleMusicLyricsCache.defaultDirectory.deletingLastPathComponent()
        musicCachePicker = picker; selectingMusicCache = true
        NSApp.activate(ignoringOtherApps: true)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            selectingMusicCache = false; musicCachePicker = nil
            guard response == .OK, let url = picker.url else { return }
            guard !isPreview else { musicCacheHint = "离线预览不读取或保存所选位置。"; return }
            guard url.lastPathComponent == "com.apple.Music" else {
                musicCacheHint = "请选择 com.apple.Music 文件夹。"; return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            musicCacheDirectory = url
            do {
                try MusicLyricsCacheLocation.save(url)
            } catch { musicCacheHint = "本次已使用所选位置，下次可能需要重新选择。" }
            cancelMusicCacheRead(); readMusicCache(force: true)
        }
        if let parent { picker.beginSheetModal(for: parent, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }
    private func waitForAppleMusicLyrics() {
        let value = isPreview ? 0 : (preferences.entry(for: lastTrackID).musicOffset ?? 0)
        timingOffset = value.isFinite ? min(max(value, -10), 10) : 0
        clock.offset = timingOffset
        sourceID = "apple-cache"
        phase = hasTrack ? .loading : .idle
        statusText = "正在读取 Music 本地歌词"
        musicCacheHint = isPreview ? "离线预览不读取本机 Music 缓存。" : "正在寻找本地逐词歌词…"
        musicCacheNeedsAccess = false
    }
    private func applyEmbeddedLyricsIfAvailable() -> Bool {
        guard !appleMusicSyncEnabled else { return false }
        guard let text = lastSnapshot?.embeddedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        let parsed = LRCParser.parse(text)
        applyResult(LyricsResult(lines: parsed.isEmpty ? [LyricLine(time: 0, text: text)] : parsed,
                                 sourceID: "apple-library", isWordSynced: false, isPlain: parsed.isEmpty))
        return true
    }

    func refreshLyrics() {
        if appleMusicSyncEnabled {
            cancelMusicCacheRead()
            musicSessionLyrics.removeValue(forKey: lastTrackID)
            musicSessionOrder.removeAll { $0 == lastTrackID }
            // 重新读取或重新授权不清空同曲已有的可用歌词。
            if phase != .ready { waitForAppleMusicLyrics() }
            musicCacheHint = isPreview ? "离线预览不读取本机 Music 缓存。" : "正在重新读取本地歌词…"
            startAppleMusicReader()
            readMusicCache(force: true)
            return
        }
        guard let snapshot = lastSnapshot, hasTrack, !isPreview else { return }
        var saved = preferences.entry(for: lastTrackID)
        saved.lyrics = nil
        do { try preferences.save(saved, for: lastTrackID) }
        catch { actionError = "无法移除手动歌词：\(error.localizedDescription)"; return }
        fetchTask?.cancel()
        clearLyrics()
        phase = .loading; statusText = "正在重新匹配…"; actionError = nil
        fetchTask = Task {
            await cache.remove(for: snapshot.trackID)
            guard !Task.isCancelled else { return }
            await loadLyrics(for: snapshot, bypassCache: true)
        }
    }

    func importLyrics(_ text: String) {
        guard hasTrack else { return }
        guard !appleMusicSyncEnabled else { actionError = "请先关闭 Apple Music 歌词同步，再导入本地歌词。"; return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { actionError = "歌词文件为空。"; return }
        let parsed = LRCParser.parse(text)
        // 带时间标签却没有可用歌词时，不把损坏文件当纯文本导入。
        if parsed.isEmpty && text.range(of: #"\[\d+:"#, options: .regularExpression) != nil {
            actionError = "没有解析到有效的 LRC 歌词，请检查时间标签。"; return
        }
        let result = LyricsResult(lines: parsed.isEmpty ? [LyricLine(time: 0, text: text)] : parsed,
                                  sourceID: "local", isWordSynced: false, isPlain: parsed.isEmpty)
        var saved = preferences.entry(for: lastTrackID)
        saved.lyrics = result
        do { if !isPreview { try preferences.save(saved, for: lastTrackID) } }
        catch { actionError = "无法保存歌词：\(error.localizedDescription)"; return }
        fetchTask?.cancel(); actionError = nil
        applyResult(result)
    }
    func setTimingOffset(_ value: Double) {
        guard canCalibrate, value.isFinite else { return }
        let value = (min(max(value, -10), 10) * 20).rounded() / 20
        var saved = preferences.entry(for: lastTrackID)
        if appleMusicSyncEnabled { saved.musicOffset = value }
        else { saved.offset = value }
        do { if !isPreview { try preferences.save(saved, for: lastTrackID) } }
        catch { actionError = "无法保存时间差：\(error.localizedDescription)"; return }
        timingOffset = value; clock.offset = value; updateCurrentIndex()
    }
    func reportActionError(_ text: String) { actionError = text }
    func dismissActionError() { actionError = nil }

    func control(_ command: MusicCommand) {
        guard canControl else { return }
        if isPreview {
            switch command {
            case .playPause:
                let position = clock.position()
                playing.toggle(); clock.update(position: position, duration: duration, playing: playing, at: Date())
            case .seek(let position): clock.update(position: position, duration: duration, playing: playing, at: Date())
            default: break
            }
            updateCurrentIndex(); onPlaybackChange?(); return
        }
        monitor?.perform(command) { [weak self] error in
            Task { @MainActor in if let error { self?.actionError = error } }
        }
    }

    private func clearLyrics() {
        boundaryTimer?.invalidate(); boundaryTimer = nil
        lines = []; lineStartTimes = []; plainLyrics = nil; synced = false
        wordSynced = false; currentIndex = -1; sourceID = ""; statusText = ""
    }
    private func loadLyrics(for snapshot: MusicState, bypassCache: Bool = false) async {
        guard !appleMusicSyncEnabled, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        if !bypassCache, let hit = await cache.entry(for: snapshot.trackID) {
            guard !appleMusicSyncEnabled, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
            if let result = hit.result { applyResult(result, note: hit.note) }
            else if !applyEmbeddedLyricsIfAvailable() { phase = .notFound; statusText = "未找到匹配的歌词" }
            return
        }
        guard !appleMusicSyncEnabled, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        let outcome = await fetchLyrics(for: snapshot)
        guard !appleMusicSyncEnabled, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        switch outcome {
        case .result(let result, let note):
            applyResult(result, note: note)
            await cache.store(result: result, note: note, for: snapshot.trackID)
        case .aliasSynced(let parsed, let source):
            let result = LyricsResult(lines: parsed, sourceID: source, isWordSynced: false)
            applyResult(result)
            await cache.store(result: result, note: nil, for: snapshot.trackID)
        case .notFound:
            if !applyEmbeddedLyricsIfAvailable() {
                phase = .notFound; statusText = "未找到匹配的歌词"
                await cache.storeNotFound(for: snapshot.trackID)
            }
        case .failed(let description):
            if !applyEmbeddedLyricsIfAvailable() { phase = .failed; statusText = description }
        }
    }
    private func schedulePrefetch(next: NextTrack?) {
        prefetchTask?.cancel()
        guard !appleMusicSyncEnabled, let next, !next.trackID.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            if await cache.entry(for: next.trackID) != nil { return }
            let query = LyricsQuery(track: next.title, artist: next.artist, album: next.album, duration: next.duration)
            guard let outcome = try? await orchestrator.fetch(query), !Task.isCancelled,
                  let result = outcome.result else { return }
            await cache.store(result: result, note: outcome.isRomanizedFallback ? "拼音歌词" : nil, for: next.trackID)
        }
    }
    func updateCurrentIndex(at now: Date = Date()) {
        let position = clock.lyricPosition(at: now)
        let index = Self.lineIndex(at: position, times: lineStartTimes)
        if currentIndex != index { currentIndex = index }
        boundaryTimer?.invalidate(); boundaryTimer = nil
        guard started, playing, connectionError == nil,
              let delay = Self.nextLineDelay(at: position, times: lineStartTimes) else { return }
        // 根据下一句的时间点唤醒，不再每隔 80ms 才检查一次。
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateCurrentIndex() }
        }
        timer.tolerance = 0.002
        boundaryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    nonisolated static func nextLineDelay(at position: Double, times: [Double]) -> Double? {
        guard position.isFinite else { return nil }
        let next = lineIndex(at: position, times: times) + 1
        guard times.indices.contains(next) else { return nil }
        let delay = times[next] - position
        return delay.isFinite && delay > 0 ? delay : nil
    }
    nonisolated static func lineIndex(at position: Double, times: [Double]) -> Int {
        guard position.isFinite else { return -1 }
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    private func applyResult(_ result: LyricsResult, note: String? = nil) {
        guard !appleMusicSyncEnabled || result.sourceID == "apple-cache" else { return }
        sourceID = result.sourceID; phase = .ready
        synced = !result.isPlain; wordSynced = result.isWordSynced && !result.isPlain
        if result.isPlain {
            plainLyrics = result.lines.map(\.text).joined(separator: "\n")
            lines = []; lineStartTimes = []
        } else {
            lines = result.lines.sorted { $0.time < $1.time }
            lineStartTimes = lines.map(\.time); plainLyrics = nil
        }
        statusText = note ?? (result.isPlain ? "静态歌词" : "")
        lyricsVersion += 1
        updateCurrentIndex()
    }

    private func loadPreview() {
        var snapshot = MusicState()
        snapshot.running = true; snapshot.playing = true; snapshot.title = "此刻，听见自己"
        snapshot.artist = "LyrX"; snapshot.trackID = "preview"; snapshot.duration = 240; snapshot.position = 20
        // 预览完全离线，不读取 Music，也不保存用户偏好。
        lastSnapshot = snapshot; lastTrackID = "preview"
        title = snapshot.title; artist = snapshot.artist; duration = 240; hasTrack = true; running = true; playing = true
        clock.update(position: 20, duration: 240, playing: true, at: Date())
        let text = ["让城市慢下来", "把喧嚣留在窗外", "此刻，只听见喜欢的声音", "每一句，都刚好在眼前", "陪你走过下一段旋律", "让音乐继续"]
        applyResult(LyricsResult(lines: text.enumerated().map { LyricLine(time: Double($0.offset) * 9, text: $0.element) },
                                 sourceID: "local", isWordSynced: false), note: "离线预览")
    }

    private func loadPreviewAppleLines() {
        let text = ["让城市慢下来", "把喧嚣留在窗外", "此刻，只听见喜欢的声音", "每一句，都刚好在眼前", "陪你走过下一段旋律", "让音乐继续"]
        handleMusicCacheLookup(.lyrics(LyricsResult(lines: text.enumerated().map {
            LyricLine(time: Double($0.offset) * 9, text: $0.element)
        }, sourceID: "apple-cache", isWordSynced: false)), trackID: "preview")
        musicCacheHint = "离线演示：仅含逐句时间，不读取本机歌词。"
    }

    private enum FetchOutcome {
        case result(LyricsResult, note: String?)  // 主链命中（含拼音兜底，note 标注）
        case aliasSynced([LyricLine], via: String) // 别名阶段行级命中
        case notFound                              // 全链路确认无歌词（可负缓存）
        case failed(String)                        // 传输层错误（不缓存）
    }

    /// 多源并发：LRCLIB、AMLL、网易云；Musixmatch 使用可选钥匙串密钥，
    /// 拼音版降级不直接采用；失败自动进入别名扩展阶段
    private func fetchLyrics(for snapshot: MusicState) async -> FetchOutcome {
        let query = LyricsQuery(track: snapshot.title, artist: snapshot.artist,
                                album: snapshot.album, duration: snapshot.duration)
        var transportError: Error?
        var romanizedBackup: LyricsResult?

        // 1) 多源降级链
        do {
            let outcome = try await orchestrator.fetch(query)
            guard !Task.isCancelled else { return .failed("") }
            if let r = outcome.result {
                if outcome.isRomanizedFallback {
                    romanizedBackup = r // 拼音版先存着，继续别名阶段找原文
                } else {
                    return .result(r, note: nil)
                }
            }
            transportError = outcome.lastError
        } catch {
            guard !Task.isCancelled else { return .failed("") }
            transportError = error
        }

        // 2) 由同艺人的网易双标题扩展别名，保留严格身份校验。
        var aliases: [String] = []
        if let alias = await NetEaseLyricsService.resolveAliasTitle(
            track: snapshot.title, artist: snapshot.artist) { aliases.append(alias) }
        for alias in aliases where TextNormalizer.versionsCompatible(alias, snapshot.title) {
            if Task.isCancelled { return .failed("") }
            // lrclib（别名，专辑/时长严格校验，防错配）
            if let r = try? await LyricsService.fetchWithRetry(
                track: alias, artist: snapshot.artist,
                album: snapshot.album, duration: snapshot.duration, strictDuration: true) {
                if Task.isCancelled { return .failed("") }
                if let syncedLRC = r.syncedLyrics, !syncedLRC.isEmpty,
                   !LyricQuality.isLikelyRomanized(lyrics: syncedLRC, track: snapshot.title, artist: snapshot.artist) {
                    let parsed = LRCParser.parse(syncedLRC)
                    if !parsed.isEmpty { return .aliasSynced(parsed, via: "lrclib") }
                }
                if let plain = r.plainLyrics, !plain.isEmpty,
                   !LyricQuality.isLikelyRomanized(lyrics: plain, track: snapshot.title, artist: snapshot.artist) {
                    return .result(LyricsResult(lines: [LyricLine(time: 0, text: plain)],
                                                sourceID: "lrclib", isWordSynced: false, isPlain: true),
                                   note: nil)
                }
            }

        }

        if Task.isCancelled { return .failed("") }
        // 原文歌词源全部失败时，才采用拼音版并明确标注
        if let backup = romanizedBackup {
            return .result(backup, note: backup.isPlain ? "静态歌词（拼音版）" : "歌词源为拼音版")
        }
        return transportError.map { .failed(Self.describe($0)) } ?? .notFound
    }

    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return "歌词获取失败：\(e.localizedDescription)" }
        switch e.code {
        case NSURLErrorTimedOut: return "歌词获取失败：请求超时 (-1001)"
        case NSURLErrorCannotFindHost: return "歌词获取失败：DNS 解析失败 (-1003)"
        case NSURLErrorCannotConnectToHost: return "歌词获取失败：无法连接服务器 (-1004)"
        case NSURLErrorNetworkConnectionLost: return "歌词获取失败：连接中断 (-1005)"
        case NSURLErrorNotConnectedToInternet: return "歌词获取失败：网络离线 (-1009)"
        case NSURLErrorSecureConnectionFailed: return "歌词获取失败：TLS 握手失败 (-1200)"
        default: return "歌词获取失败：网络错误 (\(e.code))"
        }
    }
}
