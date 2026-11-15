import Foundation
import Combine
import AppKit

final class PlaybackClock: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var basePosition: Double = 0
    private var baseTime = Date()
    private var baseUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastSampleUptime: TimeInterval?
    private var correction: Double = 0
    private var correctionDuration: Double = 0.4
    private var duration: Double = 0
    private var playing = false
    var offset: Double = 0 { didSet { if oldValue != offset { revision &+= 1 } } }
    func update(position: Double, duration: Double, playing: Bool, at time: Date,
                sampledAtUptime: TimeInterval? = nil, reset: Bool = false) {
        let sample = sampledAtUptime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if !reset, let sample, let lastSampleUptime, sample <= lastSampleUptime { return }
        let raw = max(0, position.isFinite ? position : 0)
        let predicted = sample.map { self.position(atUptime: $0) } ?? raw
        let error = raw - predicted
        // 暂停、切歌或跳转立即定位；正常播放的小误差平滑校正，避免高亮反复回退。
        let smooth = !reset && sample != nil && lastSampleUptime != nil && self.playing && playing && abs(error) < 0.45
        basePosition = smooth ? predicted : raw
        correction = smooth ? error : 0
        correctionDuration = max(0.4, abs(correction) * 2)
        baseTime = time
        baseUptime = sample ?? ProcessInfo.processInfo.systemUptime
        lastSampleUptime = sample
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.playing = playing
        revision &+= 1
    }
    func position(at now: Date? = nil) -> Double {
        if let now { return projected(elapsed: now.timeIntervalSince(baseTime)) }
        return position(atUptime: ProcessInfo.processInfo.systemUptime)
    }
    func position(atUptime now: TimeInterval) -> Double { projected(elapsed: now - baseUptime) }
    private func projected(elapsed: Double) -> Double {
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let adjusted = elapsed + correction * min(elapsed / correctionDuration, 1)
        let p = max(0, basePosition + (playing ? adjusted : 0))
        return duration > 0 ? min(p, duration) : p
    }
    func lyricPosition(at now: Date? = nil) -> Double { position(at: now) + offset }
    func freeze() {
        basePosition = position(); baseTime = Date(); baseUptime = ProcessInfo.processInfo.systemUptime
        correction = 0; lastSampleUptime = nil; playing = false; revision &+= 1
    }
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
    @Published private(set) var connecting = false
    @Published private(set) var actionError: String?
    @Published private(set) var sourceID = ""
    @Published private(set) var timingOffset = TrackPreferences.defaultTimingOffset
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
    private var identityTask: Task<Void, Never>?
    private var identityAttempted = false
    private var resolvedIdentity: SongIdentity?
    private func resolveMusicIdentityIfNeeded() {
        guard monitor != nil, !isPreview, !identityAttempted, let snapshot = lastSnapshot,
              snapshot.duration > 0 else { return }
        identityAttempted = true
        let generation = musicCacheGeneration
        let query = LyricsQuery(track: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration)
        identityTask = Task { [weak self] in
            let identity = await SongIdentityResolver.shared.resolve(query)
            guard let self, !Task.isCancelled, generation == musicCacheGeneration, let identity else { return }
            resolvedIdentity = identity
            nextMusicCacheReadAt = 0
            readMusicCache()
        }
    }
    private var nextMusicCacheReadAt: TimeInterval = 0
    private var musicCacheMisses = 0
    private var musicCacheWaitStartedAt: TimeInterval = 0
    private var checkedMusicArchive = false
    private var musicCacheDirectory: URL?
    private var musicCachePicker: NSOpenPanel?
    private var appleMusicReaderEnabled = false
    let clock = PlaybackClock()
    private let orchestrator = LyricsOrchestrator.makeDefault()
    private let externalLookup: (@Sendable (LyricsQuery, TrackLyricsSource) async throws -> LyricsResult?)?
    @Published private(set) var selectedTrackSource: TrackLyricsSource = .followDefault
    @Published private(set) var fallbackActive = false
    private var globalMusicPreference = false
    private var automaticFallbackEnabled = false
    private var fallbackAttempted = false
    private var fallbackStaticBackup: LyricsResult?
    var onLyricsChange: (() -> Void)?
    var sourceSelectionHint: String {
        if selectedTrackSource != .followDefault { return "已为本首歌保存选择；不会自动切换到其他词源。" }
        if fallbackActive { return "Music 暂无可用的滚动歌词，正在使用其他词源匹配。" }
        return "单曲选择会保留；选择“跟随全局设置”可恢复自动策略。"
    }
    private var externalLyricsAllowed: Bool { !appleMusicSyncEnabled || fallbackActive }
    private func restoreOffset(forMusic: Bool) {
        let entry = preferences.entry(for: lastTrackID)
        let value = forMusic ? entry.musicOffset ?? TrackPreferences.defaultTimingOffset : entry.offset
        timingOffset = value.isFinite ? min(max(value, -10), 10) : TrackPreferences.defaultTimingOffset
        clock.offset = timingOffset
    }
    func configureSources(preferMusic: Bool, automaticFallback: Bool, startReaders: Bool = true) {
        let changed = globalMusicPreference != preferMusic || automaticFallbackEnabled != automaticFallback
        globalMusicPreference = preferMusic; automaticFallbackEnabled = automaticFallback
        if changed { reloadSelectedSource(startReaders: startReaders) }
        else { setAppleMusicSyncEnabled(selectedTrackSource.prefersMusic(global: preferMusic), startReaders: startReaders, updateGlobalPreference: false) }
    }
    func setTrackSource(_ selection: TrackLyricsSource) {
        guard hasTrack, selection != selectedTrackSource else { return }
        var entry = preferences.entry(for: lastTrackID); entry.source = selection
        do { if !isPreview { try preferences.save(entry, for: lastTrackID) } }
        catch { actionError = "无法保存单曲词源选择。"; return }
        selectedTrackSource = selection
        reloadSelectedSource(startReaders: appleMusicReaderEnabled)
    }
    private func reloadSelectedSource(startReaders: Bool) {
        fetchTask?.cancel(); prefetchTask?.cancel(); cancelMusicCacheRead()
        fallbackActive = false; fallbackAttempted = false; fallbackStaticBackup = nil
        appleMusicSyncEnabled = selectedTrackSource.prefersMusic(global: globalMusicPreference)
        appleMusicReaderEnabled = startReaders
        monitor?.setAutomaticLyricsEnabled(!appleMusicSyncEnabled)
        clearLyrics()
        guard hasTrack, let snapshot = lastSnapshot else { phase = .idle; return }
        if isPreview {
            if appleMusicSyncEnabled { waitForAppleMusicLyrics(); loadPreviewAppleLines() }
            else { loadPreview() }
            return
        }
        if appleMusicSyncEnabled {
            waitForAppleMusicLyrics(); restoreMusicSessionLyrics(for: snapshot)
            _ = applyEmbeddedLyricsIfAvailable(); startAppleMusicReader()
        } else {
            musicCacheTimer?.invalidate(); musicCacheTimer = nil
            loadAutomaticLyrics(for: snapshot)
        }
    }
    private func considerFallback(unavailable: Bool = false, staticResult: LyricsResult? = nil) {
        guard !isPreview, !fallbackAttempted, LyricsSourcePolicy.shouldFallback(enabled: automaticFallbackEnabled,
            selection: selectedTrackSource, musicPreferred: appleMusicSyncEnabled,
            hasTimedMusic: hasAppleTimedLyrics, unavailable: unavailable, staticLyrics: staticResult != nil),
            let snapshot = lastSnapshot else { return }
        fallbackAttempted = true; fallbackActive = true; fallbackStaticBackup = staticResult
        fetchTask?.cancel()
        restoreOffset(forMusic: false)
        if phase != .ready { phase = .loading }
        fetchTask = Task { await loadLyrics(for: snapshot) }
    }
    private func finishFallbackWithoutResult() -> Bool {
        guard fallbackActive else { return false }
        if let backup = fallbackStaticBackup {
            applyResult(backup); return true
        }
        return false
    }
    private let cache: LyricsCache
    private let preferences: TrackPreferences
    private let musicCacheLookup: @Sendable (LyricsQuery, URL) -> AppleMusicCacheLookup
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
        if appleMusicSyncEnabled && (!fallbackActive || hasAppleLyrics) {
            return "Apple Music"
        }
        return switch phase {
        case .ready: sourceTitle
        case .loading: "正在匹配…"
        case .notFound, .failed: "暂无可用歌词"
        case .idle: "暂无歌词"
        }
    }
    var canCalibrate: Bool { hasTrack && synced }
    var calibrationDescription: String {
        guard hasTrack else { return "播放带时间轴的歌词后可调整。默认提前 0.20 秒。" }
        if plainLyrics != nil { return "静态歌词没有时间轴，暂不需要校准。" }
        guard canCalibrate else { return "读取到歌词时间轴后可调整。默认提前 0.20 秒。" }
        return "正数提前，负数延后。按歌曲自动保存；Apple Music 与其他词源分别保存。"
    }
    var canImportLyrics: Bool { hasTrack && !appleMusicSyncEnabled }
    var hasAppleLyrics: Bool { appleMusicSyncEnabled && ["apple-cache", "apple-library"].contains(sourceID) && phase == .ready }
    var hasAppleTimedLyrics: Bool { hasAppleLyrics && synced }
    var supportsProgressHighlight: Bool { synced }
    var musicEmptyTitle: String {
        if musicCacheNeedsAccess { return "需要允许读取 Music 歌词" }
        if phase == .failed { return "暂时无法读取 Music 歌词" }
        return phase == .loading ? "正在读取 Music 歌词…" : "Music 歌词尚未就绪"
    }
    func musicHighlightDescription(progress: Bool) -> String {
        guard progress else { return "当前句整句高亮。" }
        if hasAppleLyrics && !synced { return "这首歌提供静态歌词，没有可用于高亮的时间轴。" }
        if synced {
            return wordSynced ? "按 Apple Music 逐词时间点亮；未标记的字符使用句内进度。" : "按逐句时间估算逐字进度，并非原生逐词时间。"
        }
        return "已选择逐字；读到时间轴后启用。"
    }
    var overlayStatusText: String {
        if connectionError != nil { return "连接需要检查" }
        if connecting && !hasTrack { return "正在连接 Apple Music…" }
        if appleMusicSyncEnabled && !fallbackActive && hasTrack {
            if hasAppleLyrics { return !synced ? "静态歌词" : playing ? "" : "已暂停" }
            if musicCacheNeedsAccess { return "需要读取权限" }
            if phase == .failed { return "歌词读取异常" }
            return phase == .notFound ? "本地歌词尚未就绪" : "正在读取歌词…"
        }
        if phase == .loading { return "正在匹配歌词…" }
        if !hasTrack { return "" }
        if phase == .notFound { return "暂未收录" }
        if phase == .failed { return "获取失败" }
        return playing ? "" : "已暂停"
    }

    init(cache: LyricsCache = .shared, preferences: TrackPreferences? = nil,
         externalLookup: (@Sendable (LyricsQuery, TrackLyricsSource) async throws -> LyricsResult?)? = nil,
         musicCacheLookup: @escaping @Sendable (LyricsQuery, URL) -> AppleMusicCacheLookup = {
             AppleMusicLyricsCache().lookup($0, directory: $1)
         }) {
        self.externalLookup = externalLookup
        self.cache = cache
        self.preferences = preferences ?? TrackPreferences()
        self.musicCacheLookup = musicCacheLookup
    }

    func start(preview: Bool = false, appleMusicSync: Bool? = nil) {
        guard !started else { return }
        started = true
        isPreview = preview
        // 启动时先恢复词源，让读取器一开始就采用对应的轻量策略。
        if let appleMusicSync { appleMusicSyncEnabled = appleMusicSync; globalMusicPreference = appleMusicSync }
        if preview { loadPreview() }
        else {
            connecting = true
            monitor = MusicMonitor(automaticLyrics: !appleMusicSyncEnabled) { [weak self] snapshot in
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
        if s.readPending {
            // 短暂读取失败不重复应用旧快照，也不打断已建立的歌词时钟。
            connecting = true
            return
        }
        connecting = false
        if let error = s.scriptError {
            clock.freeze()
            boundaryTimer?.invalidate(); boundaryTimer = nil
            let message = s.scriptErrorCode == -1743 || error.contains("-1743")
                ? "请在系统设置 → 隐私与安全性 → 自动化中，允许 LyrX 控制 Music。"
                : "无法读取 Apple Music：\(error)"
            if connectionError != message { connectionError = message; onPlaybackChange?() }
            return
        }
        let recovered = connectionError != nil
        connectionError = nil
        clock.update(position: s.position, duration: s.duration, playing: s.playing, at: s.polledAt,
                     sampledAtUptime: s.sampledAtUptime, reset: s.trackID != lastTrackID || s.resetPlaybackClock)
        let previousDuration = lastSnapshot?.duration ?? 0
        let previousPlaybackToken = lastSnapshot?.playbackToken
        lastSnapshot = s
        if s.trackID != lastTrackID || previousPlaybackToken != s.playbackToken || lastArtworkData != s.artworkData {
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
        let recordingChanged = appleMusicSyncEnabled && previousDuration > 0 && s.duration > 0 && abs(previousDuration - s.duration) > 0.5
        guard s.trackID != lastTrackID || recordingChanged else {
            if appleMusicSyncEnabled, !hasAppleTimedLyrics, !fallbackActive { _ = applyEmbeddedLyricsIfAvailable() }
            else if [.notFound, .failed].contains(phase) { _ = applyEmbeddedLyricsIfAvailable() }
            if appleMusicSyncEnabled, previousDuration <= 0, s.duration > 0 { readMusicCache(force: true) }
            updateCurrentIndex(); return
        }
        lastTrackID = s.trackID
        fallbackActive = false; fallbackAttempted = false; fallbackStaticBackup = nil
        selectedTrackSource = isPreview ? .followDefault : preferences.entry(for: s.trackID).source
        appleMusicSyncEnabled = selectedTrackSource.prefersMusic(global: globalMusicPreference)
        monitor?.setAutomaticLyricsEnabled(!appleMusicSyncEnabled)
        fetchTask?.cancel()
        cancelMusicCacheRead()
        clearLyrics()
        actionError = nil
        if s.trackID.isEmpty { phase = .idle; return }
        if appleMusicSyncEnabled {
            waitForAppleMusicLyrics(); restoreMusicSessionLyrics(for: s)
            _ = applyEmbeddedLyricsIfAvailable()
            startAppleMusicReader(); return
        }
        loadAutomaticLyrics(for: s)
    }

    private func loadAutomaticLyrics(for s: MusicState) {
        let saved = preferences.entry(for: s.trackID)
        timingOffset = saved.offset.isFinite ? min(max(saved.offset, -10), 10) : TrackPreferences.defaultTimingOffset
        clock.offset = timingOffset
        if selectedTrackSource.providerID == nil, let local = saved.lyrics { applyResult(local); return }
        phase = .loading; statusText = "正在匹配歌词…"
        fetchTask = Task { await loadLyrics(for: s) }
    }

    func setAppleMusicSyncEnabled(_ enabled: Bool, startReaders: Bool = true, updateGlobalPreference: Bool = true) {
        if updateGlobalPreference { globalMusicPreference = enabled }
        appleMusicReaderEnabled = startReaders
        let changed = appleMusicSyncEnabled != enabled
        appleMusicSyncEnabled = enabled
        monitor?.setAutomaticLyricsEnabled(!enabled)
        if changed {
            fallbackActive = false; fallbackAttempted = false; fallbackStaticBackup = nil
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
        if isPreview, CommandLine.arguments.contains("--preview-apple-static") {
            handleMusicCacheLookup(.lyrics(LyricsResult(lines: [LyricLine(time: 0, text: "让城市慢下来\n把喧嚣留在窗外\n此刻，只听见喜欢的声音\n每一句，都刚好在眼前\n陪你走过下一段旋律\n让音乐继续")],
                                                        sourceID: "apple-cache", isWordSynced: false, isPlain: true)), trackID: "preview")
        }
        startAppleMusicReader()
    }
    private func startAppleMusicReader(readImmediately: Bool = true) {
        guard appleMusicSyncEnabled, appleMusicReaderEnabled, !isPreview else { return }
        if musicCacheTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readMusicCache() }
            }
            musicCacheTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        if readImmediately { readMusicCache() }
    }
    private func cancelMusicCacheRead() {
        musicCacheGeneration = UUID()
        identityTask?.cancel(); identityTask = nil; identityAttempted = false; resolvedIdentity = nil
        nextMusicCacheReadAt = 0; musicCacheMisses = 0
        checkedMusicArchive = false
        musicCacheTask?.cancel(); musicCacheTask = nil
        musicCacheChecking = false
    }
    private func readMusicCache(force: Bool = false) {
        guard appleMusicSyncEnabled, appleMusicReaderEnabled, !isPreview, hasTrack,
              (force || !(hasAppleTimedLyrics && wordSynced)), musicCacheTask == nil, let snapshot = lastSnapshot else { return }
        guard force || ProcessInfo.processInfo.systemUptime >= nextMusicCacheReadAt else { return }
        let query = LyricsQuery(track: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration, identity: resolvedIdentity)
        let directory = musicCacheDirectory ?? MusicLyricsCacheLocation.restored() ?? AppleMusicLyricsCache.defaultDirectory
        let generation = musicCacheGeneration
        musicCacheChecking = true
        musicCacheTask = Task { [weak self] in
            guard let self else { return }
            let archiveKey = Self.musicArchiveKey(for: snapshot)
            if force, let archiveKey { await cache.remove(for: archiveKey) }
            else if !checkedMusicArchive, let archiveKey {
                let saved = await cache.entry(for: archiveKey)
                guard !Task.isCancelled, generation == musicCacheGeneration else { return }
                checkedMusicArchive = true
                if let result = saved?.result, ["apple-cache", "apple-library"].contains(result.sourceID) {
                    handleMusicCacheLookup(.lyrics(result), trackID: snapshot.trackID)
                }
                if hasAppleTimedLyrics && wordSynced { musicCacheTask = nil; musicCacheChecking = false; return }
            }
            guard !Task.isCancelled, generation == musicCacheGeneration else { return }
            let reader = musicCacheLookup
            let lookup = await Task.detached(priority: .utility) {
                reader(query, directory)
            }.value
            guard !Task.isCancelled, generation == musicCacheGeneration else { return }
            musicCacheTask = nil
            musicCacheChecking = false
            handleMusicCacheLookup(lookup, trackID: snapshot.trackID)
        }
    }
    nonisolated static func musicArchiveKey(for snapshot: MusicState) -> String? {
        guard !snapshot.trackID.isEmpty, snapshot.duration.isFinite, snapshot.duration > 0 else { return nil }
        return "music-local-v1|\(snapshot.trackID)|\(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), snapshot.duration))"
    }
    func handleMusicCacheLookup(_ lookup: AppleMusicCacheLookup, trackID: String,
                                atUptime now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard appleMusicSyncEnabled, hasTrack, trackID == lastTrackID else { return }
        switch lookup {
        case .lyrics(var result):
            if !result.isPlain, result.lines.count > 1, result.lines.allSatisfy({ $0.time == 0 && ($0.words ?? []).allSatisfy { $0.start == 0 } }) {
                result.isPlain = true; result.isWordSynced = false
            }
            guard ["apple-cache", "apple-library"].contains(result.sourceID), !result.lines.isEmpty else { return }
            musicCacheNeedsAccess = false
            // 一次静态兜底或旧缓存不能覆盖已经取得的更精确时间轴。
            if hasAppleLyrics, (wordSynced && !result.isWordSynced || synced && result.isPlain) { return }
            let unchanged = hasAppleLyrics && sourceID == result.sourceID && wordSynced == result.isWordSynced &&
                (result.isPlain ? plainLyrics == result.lines.map(\.text).joined(separator: "\n") : lines == result.lines)
            musicCacheMisses = 0
            nextMusicCacheReadAt = result.isWordSynced ? .infinity : ProcessInfo.processInfo.systemUptime + (unchanged ? 30 : 4)
            musicCacheNeedsAccess = false
            musicCacheHint = result.isPlain ? "已读取静态歌词；这份歌词没有时间轴。" : result.isWordSynced ? "已读取 Apple Music 逐词时间。" : "已读取逐句时间，可选择估算的逐字高亮。"
            if result.isPlain, fallbackActive, phase == .ready, synced {
                fallbackStaticBackup = result
                nextMusicCacheReadAt = now + 30
                return
            }
            if let snapshot = lastSnapshot {
                musicSessionLyrics[trackID] = (result, snapshot.duration)
                musicSessionOrder.removeAll { $0 == trackID }; musicSessionOrder.append(trackID)
                while musicSessionOrder.count > 8 { musicSessionLyrics.removeValue(forKey: musicSessionOrder.removeFirst()) }
                if !isPreview, !unchanged, let key = Self.musicArchiveKey(for: snapshot) {
                    Task { await cache.store(result: result, note: nil, for: key) }
                }
            }
            if !result.isPlain, fallbackActive {
                fetchTask?.cancel(); fallbackActive = false; fallbackStaticBackup = nil
            }
            if !unchanged { applyResult(result) }
            if result.isPlain { considerFallback(staticResult: result) }
        case .busy:
            nextMusicCacheReadAt = now + 2
            musicCacheNeedsAccess = false
            musicCacheHint = "Music 正在更新歌词缓存，稍后自动重试。"
            if !hasAppleLyrics && !fallbackActive { phase = .loading; statusText = musicCacheHint }
            considerFallback(unavailable: now - musicCacheWaitStartedAt >= LyricsSourcePolicy.musicGracePeriod)
        case .incompatible:
            nextMusicCacheReadAt = now + 60
            musicCacheNeedsAccess = false
            musicCacheHint = "当前 Music 的缓存格式暂不兼容，可关闭 Music 同步后使用自动匹配。"
            if !hasAppleLyrics && !fallbackActive { phase = .failed; statusText = musicCacheHint }
            considerFallback(unavailable: true)
        case .unavailable(let message, let needsAccess):
            if !needsAccess { resolveMusicIdentityIfNeeded() }
            musicCacheMisses += 1
            // 切歌后给 Music 建立缓存的时间，初期至多间隔两秒；长期缺失时降低读取频率。
            let retryDelay = now - musicCacheWaitStartedAt < 12 ? min(2, Double(musicCacheMisses)) : 6
            nextMusicCacheReadAt = needsAccess ? .infinity : now + retryDelay
            musicCacheHint = message; musicCacheNeedsAccess = needsAccess
            if !hasAppleLyrics && !fallbackActive {
                phase = needsAccess ? .failed : now - musicCacheWaitStartedAt < 12 ? .loading : .notFound
                statusText = message
                if musicCacheMisses == 1 { monitor?.requestEmbeddedLyrics(for: trackID) }
            }
            considerFallback(unavailable: needsAccess || now - musicCacheWaitStartedAt >= LyricsSourcePolicy.musicGracePeriod)
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
        picker.title = "允许读取 Music 本地歌词"
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
        let value = isPreview ? TrackPreferences.defaultTimingOffset : (preferences.entry(for: lastTrackID).musicOffset ?? TrackPreferences.defaultTimingOffset)
        timingOffset = value.isFinite ? min(max(value, -10), 10) : TrackPreferences.defaultTimingOffset
        clock.offset = timingOffset
        sourceID = "apple-cache"
        phase = hasTrack ? .loading : .idle
        musicCacheWaitStartedAt = ProcessInfo.processInfo.systemUptime
        statusText = "正在读取 Music 本地歌词"
        musicCacheHint = isPreview ? "离线预览不读取本机 Music 缓存。" : "正在读取本地歌词…"
        musicCacheNeedsAccess = false
    }
    private func applyEmbeddedLyricsIfAvailable() -> Bool {
        guard let text = lastSnapshot?.embeddedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        if selectedTrackSource.providerID != nil || fallbackActive { return false }
        if appleMusicSyncEnabled && hasAppleLyrics { return true }
        let parsed = LRCParser.parse(text)
        let result = LyricsResult(lines: parsed.isEmpty ? [LyricLine(time: 0, text: text)] : parsed,
                                  sourceID: "apple-library", isWordSynced: false, isPlain: parsed.isEmpty)
        if appleMusicSyncEnabled { handleMusicCacheLookup(.lyrics(result), trackID: lastTrackID) }
        else { applyResult(result) }
        return true
    }

    func refreshLyrics() {
        if appleMusicSyncEnabled {
            fallbackAttempted = false
            cancelMusicCacheRead()
            musicSessionLyrics.removeValue(forKey: lastTrackID)
            musicSessionOrder.removeAll { $0 == lastTrackID }
            // 重新读取或重新授权不清空同曲已有的可用歌词。
            if phase != .ready { waitForAppleMusicLyrics() }
            musicCacheHint = isPreview ? "离线预览不读取本机 Music 缓存。" : "正在重新读取本地歌词…"
            startAppleMusicReader(readImmediately: false)
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
            await cache.remove(for: selectedTrackSource.providerID.map { "provider-\($0)|\(snapshot.trackID)" } ?? snapshot.trackID)
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
        if ["apple-cache", "apple-library"].contains(sourceID) { saved.musicOffset = value }
        else { saved.offset = value }
        do { if !isPreview { try preferences.save(saved, for: lastTrackID) } }
        catch { actionError = "无法保存时间差：\(error.localizedDescription)"; return }
        timingOffset = value; clock.offset = value; updateCurrentIndex()
    }
    func resetTimingOffset() { setTimingOffset(TrackPreferences.defaultTimingOffset) }
    func reportActionError(_ text: String) { actionError = text }
    func dismissActionError() { actionError = nil }
    func retryConnection() {
        connectionError = nil; connecting = true
        monitor?.retry()
    }

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
        guard externalLyricsAllowed, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        let cacheKey = selectedTrackSource.providerID.map { "provider-\($0)|\(snapshot.trackID)" } ?? snapshot.trackID
        if !bypassCache, let hit = await cache.entry(for: cacheKey),
           !fallbackActive || hit.result?.isPlain == false {
            guard externalLyricsAllowed, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
            if let result = hit.result { applyResult(result, note: hit.note) }
            else if !finishFallbackWithoutResult() && !applyEmbeddedLyricsIfAvailable() {
                monitor?.requestEmbeddedLyrics(for: snapshot.trackID)
                phase = .notFound; statusText = "未找到匹配的歌词"
            }
            return
        }
        guard externalLyricsAllowed, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        let outcome = await fetchLyrics(for: snapshot)
        guard externalLyricsAllowed, !Task.isCancelled, lastTrackID == snapshot.trackID else { return }
        switch outcome {
        case .result(let result, let note):
            if result.isPlain, finishFallbackWithoutResult() { return }
            applyResult(result, note: note)
            await cache.store(result: result, note: note, for: cacheKey)
        case .aliasSynced(let parsed, let source):
            let result = LyricsResult(lines: parsed, sourceID: source, isWordSynced: false)
            applyResult(result)
            await cache.store(result: result, note: nil, for: cacheKey)
        case .notFound:
            if !finishFallbackWithoutResult() && !applyEmbeddedLyricsIfAvailable() {
                monitor?.requestEmbeddedLyrics(for: snapshot.trackID)
                phase = .notFound; statusText = "未找到匹配的歌词"
                await cache.storeNotFound(for: cacheKey)
            }
        case .failed(let description):
            if !finishFallbackWithoutResult() && !applyEmbeddedLyricsIfAvailable() {
                monitor?.requestEmbeddedLyrics(for: snapshot.trackID)
                phase = .failed; statusText = description
            }
        }
    }
    private func schedulePrefetch(next: NextTrack?) {
        prefetchTask?.cancel()
        guard !appleMusicSyncEnabled, selectedTrackSource == .followDefault, let next, !next.trackID.isEmpty else { return }
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
    func updateCurrentIndex(at now: Date? = nil) {
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
        guard externalLyricsAllowed || ["apple-cache", "apple-library"].contains(result.sourceID) else { return }
        restoreOffset(forMusic: ["apple-cache", "apple-library"].contains(result.sourceID))
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
        onLyricsChange?()
    }

    private func loadPreview() {
        var snapshot = MusicState()
        snapshot.running = true; snapshot.playing = true; snapshot.title = "此刻，听见自己"
        snapshot.artist = "LyrX"; snapshot.trackID = "preview"; snapshot.duration = 240; snapshot.position = 20
        let introPreview = CommandLine.arguments.contains("--preview-intro")
        if introPreview { snapshot.position = 4.5; snapshot.playing = false }
        // 预览完全离线，不读取 Music，也不保存用户偏好。
        lastSnapshot = snapshot; lastTrackID = "preview"
        title = snapshot.title; artist = snapshot.artist; duration = 240; hasTrack = true; running = true; playing = snapshot.playing
        clock.update(position: snapshot.position, duration: 240, playing: snapshot.playing, at: Date())
        timingOffset = TrackPreferences.defaultTimingOffset; clock.offset = timingOffset
        var text = ["让城市慢下来", "把喧嚣留在窗外", "此刻，只听见喜欢的声音", "每一句，都刚好在眼前", "陪你走过下一段旋律", "让音乐继续"]
        if CommandLine.arguments.contains("--preview-long-line") {
            text[2] = "此刻，只听见喜欢的声音，长长的一句歌词也能随着音乐继续向前，把每一个字都留在眼前，陪你走过这一段旋律"
        }
        applyResult(LyricsResult(lines: text.enumerated().map { LyricLine(time: Double($0.offset) * 9 + (introPreview ? 9 : 0), text: $0.element) },
                                 sourceID: "local", isWordSynced: false), note: "离线预览")
    }

    private func loadPreviewAppleLines() {
        var text = ["让城市慢下来", "把喧嚣留在窗外", "此刻，只听见喜欢的声音", "每一句，都刚好在眼前", "陪你走过下一段旋律", "让音乐继续"]
        if CommandLine.arguments.contains("--preview-long-line") {
            text[2] = "此刻，只听见喜欢的声音，长长的一句歌词也能随着音乐继续向前，把每一个字都留在眼前，陪你走过这一段旋律"
        }
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
        if let externalLookup {
            do { return try await externalLookup(query, selectedTrackSource).map { .result($0, note: nil) } ?? .notFound }
            catch { return .failed(Self.describe(error)) }
        }
        let identity = await SongIdentityResolver.shared.resolve(query)
        guard !Task.isCancelled else { return .failed("") }
        let sources = orchestrator.sources.filter { selectedTrackSource.providerID == nil || $0.id == selectedTrackSource.providerID }
        let matching = LyricsOrchestrator(sources: sources.map { source -> any LyricsSource in
            if let identity { return IdentityLyricsSource(base: source, identity: identity) }
            return source
        })
        var transportError: Error?
        var romanizedBackup: LyricsResult?

        // 1) 多源降级链
        do {
            let outcome = try await matching.fetch(query)
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

        if selectedTrackSource.providerID != nil { return transportError.map { .failed(Self.describe($0)) } ?? .notFound }

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
