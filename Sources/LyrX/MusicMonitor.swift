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
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0  // 秒
    var position: Double = 0  // 秒
    var polledAt = Date()     // 本次轮询时间，用于本地插值
    var embeddedLyrics: String?
    var artworkData: Data? // 小尺寸 PNG；无封面时为 nil
    var next: NextTrack?      // 当前播放列表的下一首（用于后台预取歌词）
    /// AppleScript 执行失败时的诊断信息；非空表示本轮状态不可靠，
    /// 调用方应展示该信息而非「未运行/未在播放」之类的臆断状态
    var scriptError: String? = nil
}

/// 通过 AppleScript 轮询 Apple Music 播放状态
final class MusicMonitor {
    private let queue = DispatchQueue(label: "lyrics.music.monitor")
    private var timer: DispatchSourceTimer?
    private var script: NSAppleScript?
    private var lastLoggedError: String?
    private var artworkScript: NSAppleScript?
    private var artworkTrackID = ""
    private var artworkData: Data?
    private var embeddedLyrics: String?
    private var artworkAttempts = 0
    private var nextArtworkAttempt = Date.distantPast
    private let onUpdate: (MusicState) -> Void

    init(interval: TimeInterval = 0.3, onUpdate: @escaping (MusicState) -> Void) {
        self.onUpdate = onUpdate
        let source = #"""
        if application "Music" is not running then return "NOT_RUNNING"
        tell application "Music"
            if player state is stopped then return "STOPPED"
            set t to current track
            set dur to 0
            try
                set dur to duration of t
            end try
            set nm to ""
            set ar to ""
            set al to ""
            try
                set nm to (name of t) as text
                set ar to (artist of t) as text
                set al to (album of t) as text
            end try
            -- 顺带取当前播放列表的下一首（同一轮询，无额外进程开销）；
            -- 非播放列表上下文（如随机播放资料库）会抛错，兜底为空。
            -- 注意：变量名不可用 nd（AppleScript 保留字，编译报 -2741）
            set nextNm to ""
            set nextAr to ""
            set nextAl to ""
            set nextDur to 0
            try
                set nt to track ((index of t) + 1) of current playlist
                set nextNm to (name of nt) as text
                set nextAr to (artist of nt) as text
                set nextAl to (album of nt) as text
                set nextDur to duration of nt
            end try
            return {nm, ar, al, dur, player position, (player state as string), nextNm, nextAr, nextAl, nextDur}
        end tell
        """#
        queue.async { [weak self] in
            self?.script = NSAppleScript(source: source)
            self?.artworkScript = NSAppleScript(source: MusicArtwork.scriptSource)
            let timer = DispatchSource.makeTimerSource(queue: self?.queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self?.timer = timer
        }
    }

    deinit { timer?.cancel() }

    private func poll() {
        var state = MusicState()
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else {
            // 脚本编译/执行失败（语法错误、权限被拒 -1743 等）：
            // 不能臆断为「未运行」——用 NSWorkspace 独立判断进程状态，
            // 并附带诊断信息让 UI 显示真实原因，同时写日志便于定位
            let msg = error?[NSAppleScript.errorMessage] as? String ?? "未知脚本错误"
            let num = error?[NSAppleScript.errorNumber] as? Int ?? 0
            if lastLoggedError != msg {
                NSLog("[LyrX] AppleScript 轮询失败 (%d): %@", num, msg)
                lastLoggedError = msg
            }
            state.scriptError = "\(msg) (\(num))"
            state.running = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.apple.Music"
            }
            onUpdate(state)
            return
        }
        lastLoggedError = nil
        state.polledAt = Date()
        if let s = result.stringValue {
            if s == "NOT_RUNNING" { onUpdate(state); return }
            if s == "STOPPED" { state.running = true; onUpdate(state); return }
        }
        func text(at i: Int) -> String {
            guard let d = result.atIndex(i), d.descriptorType != typeNull else { return "" }
            return d.stringValue ?? ""
        }
        state.running = true
        state.title = text(at: 1)
        state.artist = text(at: 2)
        state.album = text(at: 3)
        state.duration = result.atIndex(4)?.doubleValue ?? 0
        state.position = result.atIndex(5)?.doubleValue ?? 0
        state.playing = (text(at: 6) == "playing")
        state.trackID = state.title.isEmpty ? "" : "\(state.title)|\(state.artist)|\(state.album)"
        let nextTitle = text(at: 7)
        if !nextTitle.isEmpty {
            state.next = NextTrack(title: nextTitle, artist: text(at: 8), album: text(at: 9),
                                   duration: result.atIndex(10)?.doubleValue ?? 0)
        }
        if artworkTrackID != state.trackID {
            artworkTrackID = state.trackID
            artworkData = nil; embeddedLyrics = nil; artworkAttempts = 0; nextArtworkAttempt = .distantPast
        }
        state.artworkData = artworkData
        state.embeddedLyrics = embeddedLyrics
        // 先发布播放状态，再读取封面；封面失败不会影响歌词同步。
        onUpdate(state)
        if !state.trackID.isEmpty, artworkData == nil, artworkAttempts < 3, Date() >= nextArtworkAttempt {
            artworkAttempts += 1
            nextArtworkAttempt = Date().addingTimeInterval(4)
            var artworkError: NSDictionary?
            if let result = artworkScript?.executeAndReturnError(&artworkError), artworkError == nil {
                let actualID = (1...3).map { result.atIndex($0)?.stringValue ?? "" }.joined(separator: "|")
                // 读取期间可能切歌，只有元数据与快照相符时才接收封面。
                if actualID == state.trackID {
                    if let raw = result.atIndex(4), raw.descriptorType != typeNull {
                        artworkData = MusicArtwork.thumbnailData(from: raw.data)
                    }
                    let text = result.atIndex(5)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    embeddedLyrics = text.isEmpty ? nil : text
                }
            }
        }
    }

    func perform(_ command: MusicCommand, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            // 控制按钮不隐式启动 Music；所有命令与轮询在同一队列执行。
            let source = """
            if application "Music" is running then
                tell application "Music"
                    \(command.script)
                end tell
            end if
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            completion(error.map { "操作失败：\($0[NSAppleScript.errorMessage] as? String ?? "请检查自动化权限")" })
            self?.poll()
        }
    }
}
