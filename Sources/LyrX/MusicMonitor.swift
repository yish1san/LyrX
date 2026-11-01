import Foundation
import AppKit

enum MusicCommand {
    case playPause, previous, next, seek(Double)
    var script: String {
        switch self {
        case .playPause: "playpause"
        case .previous: "previous track"
        case .next: "next track"
        case .seek(let position): "set player position to \(max(0, position.isFinite ? position : 0))"
        }
    }
}

/// 播放列表中「下一首」的元数据（供歌词预取；非播放列表上下文时为空）
struct NextTrack: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    var trackID: String { title.isEmpty ? "" : "\(title)|\(artist)|\(album)" }
}

/// 一次轮询得到的播放状态快照
struct MusicState {
    var running = false       // Music 是否在运行
    var playing = false       // 是否正在播放（false = 暂停/停止）
    var trackID = ""          // 曲目唯一标识（title|artist|album）
    var playbackToken = ""    // Music 内部曲目标识，用于拒绝切歌期间的过期封面。
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0  // 秒
    var position: Double = 0  // 秒
    var polledAt = Date()     // 兼容没有单调时间的快照
    var sampledAtUptime: TimeInterval? = nil // 进度实际读取时刻，不包含传输和界面排队耗时
    var resetPlaybackClock = false
    var embeddedLyrics: String?
    var artworkData: Data? // 小尺寸 PNG；无封面时为 nil
    var next: NextTrack?      // 当前播放列表的下一首（用于后台预取歌词）
    /// AppleScript 执行失败时的诊断信息；非空表示本轮状态不可靠，
    /// 调用方应展示该信息而非「未运行/未在播放」之类的臆断状态
    var scriptError: String? = nil
    var scriptErrorCode: Int? = nil
    var readPending = false // 启动、切歌或短时超时；不把瞬时未就绪当成连接失败。
}

struct MusicReadRecovery {
    struct Decision {
        var showError: Bool
        var retryDelay: TimeInterval
    }
    private var firstFailure: TimeInterval?
    private var failures = 0
    mutating func failed(code: Int, at now: TimeInterval) -> Decision {
        if firstFailure == nil { firstFailure = now }
        failures += 1
        return Decision(showError: code == -1743 || now - (firstFailure ?? now) >= 6,
                        retryDelay: min(4, 0.4 * pow(2, Double(min(failures - 1, 4)))))
    }
    mutating func recovered() { firstFailure = nil; failures = 0 }
}

/// 轻量读取进度；歌曲元数据与下一首仅在切歌时读取，封面另队列按需读取。
final class MusicMonitor {
    static let pollInterval: TimeInterval = 0.8
    static let stateScriptSource = #"""
    use framework "Foundation"
    if application "Music" is not running then return "NOT_RUNNING"
    with timeout of 2 seconds
        tell application "Music"
            set playbackState to player state as string
            if playbackState is "stopped" then return "STOPPED"
            set trackToken to ""
            try
                set trackToken to persistent ID of current track as text
            end try
            if trackToken is "" or trackToken is "missing value" or trackToken is "0" or trackToken is "0000000000000000" then
                set t to current track
                set trackToken to (name of t as text) & "|" & (artist of t as text) & "|" & (album of t as text)
            end if
        end tell
        set sampleStart to (current application's NSProcessInfo's processInfo()'s systemUptime()) as real
        tell application "Music" to set playbackPosition to player position
        set sampleEnd to (current application's NSProcessInfo's processInfo()'s systemUptime()) as real
        return {trackToken, playbackPosition, playbackState, sampleStart, sampleEnd}
    end timeout
    """#

    static func metadataScriptSource(includeNext: Bool) -> String {
        """
        if application "Music" is not running then return {}
        with timeout of 2 seconds
            tell application "Music"
                set t to current track
                set nm to name of t as text
                set ar to artist of t as text
                set al to album of t as text
                set dur to duration of t
                set trackToken to ""
                try
                    set trackToken to persistent ID of t as text
                end try
                if trackToken is "" or trackToken is "missing value" or trackToken is "0" or trackToken is "0000000000000000" then set trackToken to nm & "|" & ar & "|" & al
                set nextNm to ""
                set nextAr to ""
                set nextAl to ""
                set nextDur to 0
                if \(includeNext ? "true" : "false") then
                    try
                        set nt to track ((index of t) + 1) of current playlist
                        set nextNm to name of nt as text
                        set nextAr to artist of nt as text
                        set nextAl to album of nt as text
                        set nextDur to duration of nt
                    end try
                end if
                return {nm, ar, al, dur, nextNm, nextAr, nextAl, nextDur, trackToken}
            end tell
        end timeout
        """
    }

    // NSAppleScript 的后台工作统一串行执行（Apple DTS: forums/thread/759287）。
    private static let scriptingQueue = DispatchQueue(label: "lyrx.apple-events", qos: .userInitiated)
    private static var scriptCache: [String: NSAppleScript] = [:]
    private static let runtimePrepared: Void = {
        let warmUp: () -> Void = {
            let source = #"""
            use framework "Foundation"
            return (current application's NSProcessInfo's processInfo()'s systemUptime()) as real
            """#
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
        // 先在主线程完成系统脚本引擎的初始化；不访问 Music。
        if Thread.isMainThread { warmUp() } else { DispatchQueue.main.sync(execute: warmUp) }
    }()

    static func prepareScriptingRuntime() { _ = runtimePrepared }

    static func runScript(_ source: String, cache: Bool = true) -> (NSAppleEventDescriptor?, NSDictionary?) {
        prepareScriptingRuntime()
        return scriptingQueue.sync {
            var error: NSDictionary?
            guard let script = (cache ? scriptCache[source] : nil) ?? NSAppleScript(source: source) else {
                return (nil, [NSAppleScript.errorNumber: -2741] as NSDictionary)
            }
            if cache && scriptCache.count < 8 { scriptCache[source] = script }
            return (script.executeAndReturnError(&error), error)
        }
    }

    private let queue = DispatchQueue(label: "lyrx.music.progress", qos: .userInitiated)
    private let extrasQueue = DispatchQueue(label: "lyrx.music.extras", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var eventPoll: DispatchWorkItem?
    private var lastPoll = -Double.infinity
    private var nextAllowedPoll: TimeInterval = 0
    private var recovery = MusicReadRecovery()
    private var automaticLyrics: Bool
    private var metadataToken = ""
    private var artworkGeneration = UUID()
    private var cachedState = MusicState()
    private var embeddedRequestedFor = ""
    private var hasSnapshot = false
    private let onUpdate: (MusicState) -> Void

    init(interval: TimeInterval = MusicMonitor.pollInterval, automaticLyrics: Bool = true,
         onUpdate: @escaping (MusicState) -> Void) {
        self.onUpdate = onUpdate
        self.automaticLyrics = automaticLyrics
        Self.prepareScriptingRuntime()
        // 通知只负责提前唤醒轻量读取；不依赖通知载荷，不记录歌曲信息。
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in self?.requestPoll() }
            observers.append(observer)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: max(0.5, interval), leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume(); self.timer = timer
        }
    }

    deinit {
        timer?.cancel(); eventPoll?.cancel()
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    func setAutomaticLyricsEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, automaticLyrics != enabled else { return }
            automaticLyrics = enabled
            metadataToken = "" // 下次读取时重新生成符合当前模式的元数据。
        }
    }
    func retry() {
        queue.async { [weak self] in
            guard let self else { return }
            recovery.recovered(); nextAllowedPoll = 0
            poll(force: true)
        }
    }

    private func requestPoll() {
        queue.async { [weak self] in
            guard let self, eventPoll == nil else { return }
            let delay = max(0, lastPoll + 0.15 - ProcessInfo.processInfo.systemUptime)
            let work = DispatchWorkItem { [weak self] in
                self?.eventPoll = nil; self?.poll()
            }
            eventPoll = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func poll(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now >= nextAllowedPoll && now - lastPoll >= 0.1) else { return }
        lastPoll = now
        let (readResult, error) = Self.runScript(Self.stateScriptSource)
        guard let result = readResult, error == nil else {
            let number = error?[NSAppleScript.errorNumber] as? Int ?? 0
            reportReadFailure(code: number, detail: "无法读取 Music 播放进度")
            return
        }
        if let value = result.stringValue, ["NOT_RUNNING", "STOPPED"].contains(value) {
            recovery.recovered(); nextAllowedPoll = 0
            cachedState = MusicState(); cachedState.running = value == "STOPPED"
            metadataToken = ""; embeddedRequestedFor = ""; hasSnapshot = false
            artworkGeneration = UUID()
            onUpdate(cachedState); return
        }
        let token = Self.text(result, 1)
        guard !token.isEmpty else {
            reportReadFailure(code: -1728, detail: "Music 的当前歌曲尚未就绪"); return
        }
        var state = cachedState
        let metadataChanged = metadataToken != token
        if metadataChanged {
            let (metadataResult, metadataError) = Self.runScript(Self.metadataScriptSource(includeNext: automaticLyrics))
            guard let metadata = metadataResult, metadataError == nil,
                  Self.text(metadata, 9) == token else {
                reportReadFailure(code: metadataError?[NSAppleScript.errorNumber] as? Int ?? -1728,
                                  detail: "Music 的歌曲信息正在更新")
                return
            }
            state = MusicState()
            state.title = Self.text(metadata, 1); state.artist = Self.text(metadata, 2); state.album = Self.text(metadata, 3)
            state.duration = metadata.atIndex(4)?.doubleValue ?? 0
            guard !state.title.isEmpty else {
                reportReadFailure(code: -1728, detail: "Music 的歌曲信息尚未就绪"); return
            }
            state.trackID = state.title.isEmpty ? "" : "\(state.title)|\(state.artist)|\(state.album)"
            state.playbackToken = token
            if cachedState.playbackToken == token, cachedState.trackID == state.trackID {
                state.artworkData = cachedState.artworkData
                state.embeddedLyrics = cachedState.embeddedLyrics
            }
            if !Self.text(metadata, 5).isEmpty {
                state.next = NextTrack(title: Self.text(metadata, 5), artist: Self.text(metadata, 6), album: Self.text(metadata, 7),
                                       duration: metadata.atIndex(8)?.doubleValue ?? 0)
            }
            // Music 刚开始播放时偶尔先返回 0 时长；下一轮补读，不能永久缓存这个空值。
            metadataToken = state.duration > 0 ? token : ""
            embeddedRequestedFor = ""
            if metadataToken == token, cachedState.playbackToken != token || state.artworkData == nil {
                artworkGeneration = UUID()
                scheduleArtwork(for: state.trackID, token: token, generation: artworkGeneration)
            }
        }
        state.running = true; state.playing = Self.text(result, 3) == "playing"
        state.position = result.atIndex(2)?.doubleValue ?? 0
        let start = result.atIndex(4)?.doubleValue ?? .nan
        let end = result.atIndex(5)?.doubleValue ?? .nan
        let received = ProcessInfo.processInfo.systemUptime
        state.sampledAtUptime = Self.sampleTime(start: start, end: end, received: received)
        state.polledAt = Date().addingTimeInterval((state.sampledAtUptime ?? received) - received)
        state.scriptError = nil
        state.scriptErrorCode = nil; state.readPending = false
        state.resetPlaybackClock = force || metadataChanged
        recovery.recovered(); nextAllowedPoll = 0
        cachedState = state; hasSnapshot = true
        onUpdate(state)
    }

    private func reportReadFailure(code: Int, detail: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let decision = recovery.failed(code: code, at: now)
        nextAllowedPoll = now + decision.retryDelay
        var state = cachedState
        state.resetPlaybackClock = false
        state.readPending = !decision.showError
        state.scriptError = decision.showError ? "\(detail) (\(code))" : nil
        state.scriptErrorCode = decision.showError ? code : nil
        onUpdate(state)
    }

    static func sampleTime(start: TimeInterval, end: TimeInterval, received: TimeInterval) -> TimeInterval? {
        guard start.isFinite, end.isFinite, received.isFinite, start >= 0, end >= start,
              end <= received + 0.01, received - start <= 5 else { return nil }
        // 响应很慢时，耗时可能来自 Music 排队；不把整段等待算作对称传输延迟。
        return end - start <= 0.15 ? start + (end - start) / 2 : end
    }

    private static func text(_ result: NSAppleEventDescriptor, _ index: Int) -> String {
        guard let value = result.atIndex(index), value.descriptorType != typeNull else { return "" }
        return value.stringValue ?? ""
    }

    private func scheduleArtwork(for trackID: String, token: String, generation: UUID,
                                 attempt: Int = 1, delay: TimeInterval = 0.6) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, metadataToken == token, artworkGeneration == generation else { return }
            extrasQueue.async { [weak self] in
                guard let self, queue.sync(execute: {
                    self.metadataToken == token && self.artworkGeneration == generation && self.cachedState.trackID == trackID
                }) else { return }
                let (result, error) = Self.runScript(MusicArtwork.scriptSource)
                let valid = error == nil && result.map { MusicArtwork.isCurrentResponse($0, trackID: trackID, token: token) } == true
                let data = valid ? result?.atIndex(4).flatMap {
                    $0.descriptorType == typeNull ? nil : MusicArtwork.thumbnailData(from: $0.data)
                } : nil
                queue.async { [weak self] in
                    guard let self, metadataToken == token, artworkGeneration == generation,
                          cachedState.playbackToken == token, cachedState.trackID == trackID, hasSnapshot else { return }
                    if let data, cachedState.artworkData != data {
                        cachedState.artworkData = data
                        var update = cachedState; update.resetPlaybackClock = false
                        onUpdate(update)
                    }
                    // 同一首歌的暂时空响应保留已经核对过的封面；切歌时旧图已随新快照清空。
                    if let nextDelay = MusicArtwork.refreshDelay(afterAttempt: attempt, receivedImage: data != nil) {
                        scheduleArtwork(for: trackID, token: token, generation: generation, attempt: attempt + 1, delay: nextDelay)
                    }
                }
            }
        }
    }

    /// 每首歌只请求一次静态内嵌歌词；Music 缓存暂缺时也可使用，不操作歌词窗口。
    func requestEmbeddedLyrics(for trackID: String) {
        queue.async { [weak self] in
            guard let self, cachedState.trackID == trackID,
                  embeddedRequestedFor != trackID else { return }
            embeddedRequestedFor = trackID
            extrasQueue.async { [weak self] in
                guard let self, queue.sync(execute: { self.cachedState.trackID == trackID }) else { return }
                let (result, error) = Self.runScript(MusicArtwork.embeddedLyricsScriptSource)
                guard error == nil, let result,
                      (1...3).map({ Self.text(result, $0) }).joined(separator: "|") == trackID else { return }
                let lyricText = Self.text(result, 4).trimmingCharacters(in: .whitespacesAndNewlines)
                queue.async { [weak self] in
                    guard let self, cachedState.trackID == trackID, hasSnapshot else { return }
                    cachedState.embeddedLyrics = lyricText.isEmpty ? nil : lyricText
                    var update = cachedState; update.resetPlaybackClock = false
                    onUpdate(update)
                }
            }
        }
    }

    func perform(_ command: MusicCommand, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            let source = """
            if application "Music" is running then
                tell application "Music"
                    \(command.script)
                end tell
            end if
            """
            let (_, error) = Self.runScript(source, cache: false)
            completion(error.map { "操作失败：\($0[NSAppleScript.errorMessage] as? String ?? "请检查自动化权限")" })
            self?.poll(force: true)
        }
    }
}
