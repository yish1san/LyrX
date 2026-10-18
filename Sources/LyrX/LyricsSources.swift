import Foundation

// MARK: - 标准化数据结构

/// 统一查询参数
struct LyricsQuery: Sendable {
    var track: String
    var artist: String
    var album: String
    var duration: Double // 秒
}

/// 标准化歌词结果：行级必有，逐词可选；isPlain=true 表示无时间轴的静态歌词
struct LyricsResult: Codable, Sendable {
    var lines: [LyricLine]
    var sourceID: String
    var isWordSynced: Bool
    var isPlain: Bool = false
}

/// 统一歌词源接口
protocol LyricsSource {
    var id: String { get }
    var isEnabled: Bool { get }
    /// 命中返回标准化歌词；找不到返回 nil；传输层错误抛出（编排层负责重试/降级）
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult?
}

// MARK: - 逐词格式解析

/// TTML（AMLL）：<p begin end><span begin end>词</span>…</p>，时间格式 "mm:ss.mmm" 或 "12.3s"
enum TTMLParser {
    private final class Node {
        enum Content { case text(String), node(Node) }
        let name: String
        let attributes: [String: String]
        var content: [Content] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        var excluded: Bool {
            attributes.contains { $0.key.hasSuffix("role") && ["x-translation", "x-roman"].contains($0.value) }
        }
        var text: String {
            guard !excluded else { return "" }
            if name == "br" { return "\n" }
            return content.map { switch $0 { case .text(let text): text; case .node(let node): node.text } }.joined()
        }
        var children: [Node] { content.compactMap { if case .node(let node) = $0 { node } else { nil } } }
        var hasTimedDescendant: Bool {
            children.contains { !$0.excluded && (($0.name == "span" && $0.attributes["begin"] != nil) || $0.hasTimedDescendant) }
        }
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var stack: [Node] = []
        var lines: [LyricLine] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let node = Node(name.split(separator: ":").last.map(String.init) ?? name, attributes)
            stack.last?.content.append(.node(node)); stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.content.append(.text(text)) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let node = stack.popLast(), node.name == "p", !node.excluded else { return }
            let plain = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }
            var spans: [(text: String, start: Double, end: Double?)] = []
            func collect(_ node: Node) {
                guard !node.excluded else { return }
                if node.name == "span", !node.hasTimedDescendant,
                   let begin = parseTime(node.attributes["begin"] ?? "") {
                    let end = parseTime(node.attributes["end"] ?? "")
                        ?? parseTime(node.attributes["dur"] ?? "").map { begin + $0 }
                    spans.append((node.text, begin, end))
                    return
                }
                for content in node.content {
                    switch content {
                    case .node(let child): collect(child)
                    case .text: break
                    }
                }
            }
            collect(node)
            guard let start = parseTime(node.attributes["begin"] ?? "") ?? spans.first?.start else { return }
            let lineEnd = parseTime(node.attributes["end"] ?? "")
                ?? parseTime(node.attributes["dur"] ?? "").map { start + $0 }
            var words: [LyricWord] = []
            var cursor = plain.startIndex
            for (index, span) in spans.enumerated() {
                let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 未计时的标点、空格或和声不应导致整句丢失已有词时间。
                guard !text.isEmpty, let range = plain.range(of: text, range: cursor..<plain.endIndex),
                      let end = span.end ?? spans.dropFirst(index + 1).first(where: { $0.start > span.start })?.start ?? lineEnd,
                      end.isFinite, end >= span.start else { continue }
                var wordText = String(plain[range])
                var next = range.upperBound
                while next < plain.endIndex, plain[next].isWhitespace {
                    wordText.append(plain[next]); next = plain.index(after: next)
                }
                if next == plain.endIndex { wordText = wordText.trimmingCharacters(in: .whitespacesAndNewlines) }
                words.append(LyricWord(text: wordText, start: span.start, end: end))
                cursor = next
            }
            lines.append(LyricLine(time: start, text: plain, endTime: lineEnd, words: words.isEmpty ? nil : words))
        }
    }
    static func parse(_ xml: String) -> [LyricLine] {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        let reader = Reader(); parser.delegate = reader
        guard parser.parse() else { return [] }
        return reader.lines.sorted { $0.time < $1.time }
    }
    private static func parseTime(_ value: String) -> Double? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Double?
        if value.hasSuffix("ms") { result = Double(value.dropLast(2)).map { $0 / 1000 } }
        else if value.hasSuffix("s") { result = Double(value.dropLast()) }
        else {
            let parts = value.split(separator: ":")
            guard (1...3).contains(parts.count) else { return nil }
            var total: Double = 0
            for part in parts { guard let number = Double(part) else { return nil }; total = total * 60 + number }
            result = total
        }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
    }
}

/// YRC（网易云逐词）：行格式 [行始,行长](词绝对始,词长,0)词（词时间为绝对毫秒）
enum YRCParser {
    // 制作信息行不作为歌词展示
    private static let creditsPattern = #"^(作词|作曲|编曲|制作人|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐编写|编写|配唱|弦乐|原唱|翻唱|音乐总监|总监|出品|企划|OP|SP|词|曲)\s*[:：]"#

    static func parse(_ yrc: String) -> [LyricLine] {
        guard let lineRe = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]\s?(.*)$"#),
              let wordRe = try? NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)\s?([^()\[]*)"#),
              let credits = try? NSRegularExpression(pattern: creditsPattern) else { return [] }
        var out: [LyricLine] = []
        for raw in yrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = lineRe.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let body = ns.substring(with: m.range(at: 3))
            let bns = body as NSString
            var words: [LyricWord] = []
            var plain = ""
            for wm in wordRe.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let ws = Double(bns.substring(with: wm.range(at: 1))) ?? 0
                let dur = Double(bns.substring(with: wm.range(at: 2))) ?? 0
                let t = bns.substring(with: wm.range(at: 3))
                plain += t
                if !t.isEmpty {
                    words.append(LyricWord(text: t, start: ws / 1000, end: (ws + dur) / 1000))
                }
            }
            plain = plain.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }
            let pns = plain as NSString
            guard credits.firstMatch(in: plain, range: NSRange(location: 0, length: pns.length)) == nil else { continue }
            let startMs = words.first.map { $0.start * 1000 } ?? (Double(ns.substring(with: m.range(at: 1))) ?? 0)
            out.append(LyricLine(time: startMs / 1000, text: plain, words: words.isEmpty ? nil : words))
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - 源 1：LRCLIB（免费兜底）

struct LRCLibSource: LyricsSource {
    let id = "lrclib"
    var isEnabled: Bool { true }

    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        guard let r = try await LyricsService.fetchWithRetry(
            track: query.track, artist: query.artist, album: query.album, duration: query.duration) else { return nil }
        if let synced = r.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return LyricsResult(lines: lines, sourceID: id, isWordSynced: false) }
        }
        if let plain = r.plainLyrics, !plain.isEmpty {
            return LyricsResult(lines: [LyricLine(time: 0, text: plain)], sourceID: id, isWordSynced: false, isPlain: true)
        }
        return nil
    }
}

// MARK: - 源 2：AMLL TTML DB（逐词首选）

/// amll-dev/amll-ttml-db：ncm-lyrics/<ncmId>.ttml 直达；索引匹配走 raw-lyrics/<file>
struct AMLLSource: LyricsSource {
    let id = "amll"
    var isEnabled: Bool { true }

    private static let rawBase = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"
    private static let indexURL = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl"
    private static let indexTTL: TimeInterval = 24 * 3600

    // 索引缓存（内存 + 磁盘，24h 过期）
    private struct IndexEntry { var names: [String]; var artists: [String]; var album: String?; var file: String }
    private actor IndexCache {
        var entries: [IndexEntry]?
        var date: Date?
        func value() -> [IndexEntry]? {
            guard let date, Date().timeIntervalSince(date) < AMLLSource.indexTTL else { return nil }
            return entries
        }
        func store(_ entries: [IndexEntry], at date: Date) { self.entries = entries; self.date = date }
    }
    private static let indexCache = IndexCache()

    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        // 快路径：经网易云搜索拿 NCM ID，直接取 ncm-lyrics/<id>.ttml
        for ncmID in await NetEaseLyricsService.resolveSongIDs(track: query.track, artist: query.artist, duration: query.duration).prefix(2) {
            if let lines = try await fetchTTML("\(Self.rawBase)/ncm-lyrics/\(ncmID).ttml") {
                return LyricsResult(lines: lines, sourceID: id, isWordSynced: lines.contains { $0.words != nil })
            }
        }
        // 索引路径：musicName + artists 匹配
        if let file = try await matchInIndex(query) {
            if let lines = try await fetchTTML("\(Self.rawBase)/raw-lyrics/\(file)") {
                return LyricsResult(lines: lines, sourceID: id, isWordSynced: lines.contains { $0.words != nil })
            }
        }
        return nil
    }

    private func fetchTTML(_ urlString: String) async throws -> [LyricLine]? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        let (data, resp) = try await AMLLSource.http(comps)
        guard (200..<300).contains(resp.statusCode), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = TTMLParser.parse(text)
        return lines.isEmpty ? nil : lines
    }

    private func matchInIndex(_ query: LyricsQuery) async throws -> String? {
        let entries = try await Self.loadIndex()
        let normTrack = TextNormalizer.normalizeTitle(query.track)
        let loweredArtist = query.artist.lowercased()
        for e in entries {
            guard e.names.contains(where: { TextNormalizer.looselyEqual($0, normTrack) && TextNormalizer.versionsCompatible($0, query.track) }) else { continue }
            let artistHit = loweredArtist.isEmpty || e.artists.contains {
                let a = $0.lowercased()
                return TextNormalizer.artistsMatch(a, query.artist)
            }
            if artistHit { return e.file }
        }
        return nil
    }

    private static func loadIndex() async throws -> [IndexEntry] {
        if let index = await indexCache.value() { return index }
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amll-index.jsonl")
        // 磁盘缓存未过期则直接用
        if let attr = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let mtime = attr[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < indexTTL,
           let data = try? Data(contentsOf: cacheURL) {
            let idx = parseIndex(data)
            if !idx.isEmpty { await indexCache.store(idx, at: mtime); return idx }
        }
        guard let comps = URLComponents(string: indexURL) else { return await indexCache.value() ?? [] }
        let (data, resp) = try await http(comps)
        guard (200..<300).contains(resp.statusCode) else { return await indexCache.value() ?? [] }
        try? data.write(to: cacheURL)
        let idx = parseIndex(data)
        await indexCache.store(idx, at: Date())
        return idx
    }

    private static func parseIndex(_ data: Data) -> [IndexEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [IndexEntry] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let meta = obj["metadata"] as? [[Any]],
                  let file = obj["rawLyricFile"] as? String else { continue }
            var names: [String] = []
            var artists: [String] = []
            var album: String?
            for pair in meta {
                guard pair.count == 2, let key = pair[0] as? String, let vals = pair[1] as? [String] else { continue }
                switch key {
                case "musicName": names = vals
                case "artists": artists = vals
                case "album": album = vals.first
                default: break
                }
            }
            if !names.isEmpty { out.append(IndexEntry(names: names, artists: artists, album: album, file: file)) }
        }
        return out
    }

    private static func http(_ comps: URLComponents) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: comps.url!)
        req.setValue("LyrX/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await LyricsHTTP.data(for: req)
        let http = resp
        if (500..<600).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - 源 3：网易云（行级 LRC + 逐词 YRC）

struct NetEaseSource: LyricsSource {
    let id = "netease"
    /// 无版权艺人黑名单：搜索结果全为翻唱，时间轴对不上原曲
    static let blockedArtists = ["周杰伦", "jay chou"]

    var isEnabled: Bool { true }

    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        let a = query.artist.lowercased()
        if Self.blockedArtists.contains(where: { a.contains($0) }) { return nil }
        // 逐词 YRC 优先，LRC 兜底
        for ncmID in await NetEaseLyricsService.resolveSongIDs(track: query.track, artist: query.artist, duration: query.duration).prefix(3) {
            let (lrc, yrc) = try await NetEaseLyricsService.fetchLRCAndYRC(id: ncmID)
            if let yrc, !yrc.isEmpty {
                let lines = YRCParser.parse(yrc)
                if !lines.isEmpty { return LyricsResult(lines: lines, sourceID: id, isWordSynced: true) }
            }
            if let lrc, !lrc.isEmpty {
                let lines = LRCParser.parse(lrc)
                if !lines.isEmpty { return LyricsResult(lines: lines, sourceID: id, isWordSynced: false) }
            }
        }
        return nil
    }
}

// MARK: - 源 4：QQ 音乐 QRC（当前不可用：搜索接口已被反爬）

/// 2026-09 实测：u.y.qq.com/cgi-bin/musicu.fcg 对所有查询返回空列表（需登录态/签名），
/// c.y.qq.com 旧搜索接口已下线。无搜索则无法定位 songmid，QRC 解密无从谈起。
/// 保留适配器骨架：一旦搜索恢复或取得有效 Cookie，补 fetchLRCOnce 即可启用。
struct QQMusicSource: LyricsSource {
    let id = "qq"
    var isEnabled: Bool { false } // 搜索被封，禁用
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? { nil }
}

// MARK: - 源 7：Musixmatch 官方 API（需 apikey；未配置则禁用）

/// 密钥通过设置保存在系统钥匙串中。
/// 说明：官方免费层仅返回 30% 歌词且通常无同步轴；subtitle（逐句）需付费计划。
struct MusixmatchSource: LyricsSource {
    let id = "musixmatch"
    var isEnabled: Bool { LyricsCredentials.musixmatchAPIKey != nil }

    private struct TrackSearchResponse: Decodable {
        struct Message: Decodable {
            struct Body: Decodable {
                struct TrackItem: Decodable {
                    struct TrackInfo: Decodable { let track_id: Int }
                    let track: TrackInfo
                }
                let track_list: [TrackItem]?
            }
            let body: Body
        }
    }
    private struct LyricsResponse: Decodable {
        struct Message: Decodable {
            struct Body: Decodable {
                struct Lyrics: Decodable { let lyrics_body: String? }
                let lyrics: Lyrics?
            }
            let body: Body
        }
    }

    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        guard let key = LyricsCredentials.musixmatchAPIKey else { return nil }
        var comps = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.search")!
        comps.setQuery([
            URLQueryItem(name: "q_track", value: query.track),
            URLQueryItem(name: "q_artist", value: query.artist),
            URLQueryItem(name: "page_size", value: "3"),
            URLQueryItem(name: "apikey", value: key)
        ])
        let (data, resp) = try await Self.http(comps)
        guard (200..<300).contains(resp.statusCode) else { return nil }
        let tracks = try JSONDecoder().decode(TrackSearchResponse.Message.self, from: data).body.track_list ?? []
        guard let trackID = tracks.first?.track.track_id else { return nil }
        var lcomps = URLComponents(string: "https://api.musixmatch.com/ws/1.1/track.lyrics.get")!
        lcomps.setQuery([
            URLQueryItem(name: "track_id", value: String(trackID)),
            URLQueryItem(name: "apikey", value: key)
        ])
        let (ldata, lresp) = try await Self.http(lcomps)
        guard (200..<300).contains(lresp.statusCode) else { return nil }
        guard let body = try JSONDecoder().decode(LyricsResponse.Message.self, from: ldata).body.lyrics?.lyrics_body,
              !body.isEmpty else { return nil }
        // 官方 API 为静态文本（含 "******* This Lyrics is NOT for Commercial use *******" 尾注）
        let cleaned = body.components(separatedBy: "*******").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? body
        guard !cleaned.isEmpty else { return nil }
        return LyricsResult(lines: [LyricLine(time: 0, text: cleaned)], sourceID: id, isWordSynced: false, isPlain: true)
    }

    private static func http(_ comps: URLComponents) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: comps.url!)
        req.setValue("LyrX/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await LyricsHTTP.data(for: req)
        let http = resp
        if (500..<600).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - 并发编排：优先可靠同步歌词，静态和拼音结果用于兜底

struct LyricsFetchOutcome {
    var result: LyricsResult?        // 最终采用（含拼音兜底）
    var isRomanizedFallback: Bool    // 采用的是拼音兜底版
    var lastError: Error?
}

struct LyricsOrchestrator {
    var sources: [any LyricsSource]

    static func makeDefault() -> LyricsOrchestrator {
        LyricsOrchestrator(sources: [
            LRCLibSource(),
            AMLLSource(),
            NetEaseSource(),
            QQMusicSource(),     // disabled
            MusixmatchSource()   // 需凭据
        ])
    }

    /// 源之间并发，原文同步优先于原文静态，最后采用拼音。
    func fetch(_ query: LyricsQuery) async throws -> LyricsFetchOutcome {
        let expectCJK = LyricQuality.containsCJK(query.track) || LyricQuality.containsCJK(query.artist)
        // 独立歌词源并发查询，慢源不阻塞可用结果；拿到可靠同步歌词后取消其余请求。
        return try await withThrowingTaskGroup(of: LyricsFetchOutcome.self) { group in
            for source in sources where source.isEnabled {
                group.addTask {
                    do {
                        let result = try await source.fetch(query)
                        try Task.checkCancellation()
                        return LyricsFetchOutcome(result: result, isRomanizedFallback: false, lastError: nil)
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return LyricsFetchOutcome(result: nil, isRomanizedFallback: false, lastError: error)
                    }
                }
            }
            var plain: LyricsResult?
            var romanized: LyricsResult?
            var lastError: Error?
            for try await outcome in group {
                try Task.checkCancellation()
                if let error = outcome.lastError { lastError = error }
                guard let result = outcome.result, !result.lines.isEmpty else { continue }
                let isRomanized = expectCJK && LyricQuality.isLikelyRomanized(
                    lyrics: result.lines.map(\.text).joined(separator: "\n"), track: query.track, artist: query.artist)
                if isRomanized { if romanized == nil { romanized = result }; continue }
                if result.isPlain { if plain == nil { plain = result }; continue }
                group.cancelAll()
                return LyricsFetchOutcome(result: result, isRomanizedFallback: false, lastError: lastError)
            }
            return LyricsFetchOutcome(result: plain ?? romanized, isRomanizedFallback: plain == nil && romanized != nil, lastError: lastError)
        }
    }
}
