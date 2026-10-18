import Foundation

/// 一个词（逐词歌词）
struct LyricWord: Equatable, Codable, Sendable {
    var text: String
    var start: Double // 秒（相对全曲）
    var end: Double
}

/// 一行带时间轴的歌词；逐词源附 words 与 endTime
struct LyricLine: Equatable, Codable, Sendable {
    var time: Double // 秒
    var text: String
    var endTime: Double? = nil
    var words: [LyricWord]? = nil
}

/// LRC 格式解析（支持一行多时间戳；过滤空行与网易云 credits 行）
enum LRCParser {
    private static let pattern = #"\[(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)\]"#
    // 网易云 LRC 开头的制作信息行（作词/作曲/编曲/弦乐编写等），不作为歌词行展示
    private static let creditsPattern = #"^(作词|作曲|编曲|制作人|监制|混音|母带|录音|和声|吉他|贝斯|鼓|键盘|弦乐编写|编写|配唱|弦乐|原唱|翻唱|音乐总监|总监|出品|企划|OP|SP|词|曲)\s*[:：]"#

    static func parse(_ lrc: String) -> [LyricLine] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let credits = try? NSRegularExpression(pattern: creditsPattern) else { return [] }
        let offsetRE = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive)
        let fullText = lrc as NSString
        let offset = offsetRE.firstMatch(in: lrc, range: NSRange(location: 0, length: fullText.length))
            .flatMap { Double(fullText.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var grouped: [Double: [String]] = [:]
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: raw, range: range)
            let text = re.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !matches.isEmpty, !text.isEmpty,
                  credits.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { continue }
            for m in matches {
                guard let minutes = Double(ns.substring(with: m.range(at: 1))),
                      let seconds = Double(ns.substring(with: m.range(at: 2))), seconds < 60 else { continue }
                let time = max(0, minutes * 60 + seconds + offset)
                if !(grouped[time] ?? []).contains(text) { grouped[time, default: []].append(text) }
            }
        }
        // 同一时间戳的原文与译文合为一行，避免二分查找只显示最后一条。
        return grouped.keys.sorted().map { LyricLine(time: $0, text: grouped[$0]!.joined(separator: "\n")) }
    }
}

enum TextNormalizer {
    static func normalizeTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(
            of: #"[\(（](?:feat\.?|ft\.?|with|live|remix|remaster(?:ed)?|acoustic|instrumental|version|现场|演唱会|伴奏|翻唱)[^\)）]*[\)）]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: #"\s*[-–—]\s*(?:live|remix|remaster(?:ed)?|acoustic|instrumental|version|现场|演唱会|伴奏|翻唱).*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func normalizeArtist(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func canonical(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s
        return simplified.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func looselyEqual(_ a: String, _ b: String) -> Bool {
        let x = canonical(normalizeTitle(a)), y = canonical(normalizeTitle(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        // 双标题只允许完整片段相等，不能用任意子串匹配“爱”和“爱情”。
        func parts(_ s: String) -> [String] {
            normalizeTitle(s).components(separatedBy: CharacterSet(charactersIn: "|｜/／–—"))
                .flatMap { $0.components(separatedBy: " - ") }.map(canonical).filter { !$0.isEmpty }
        }
        return parts(a).contains(y) || parts(b).contains(x)
    }
    /// 仅提取明确的“中文标题 English title”两段；是否采纳仍需艺人及近似时长校验。
    static func bilingualAliases(_ title: String) -> [String] {
        let normalized = normalizeTitle(title)
        guard let range = normalized.range(of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}])\s+(?=[A-Za-z])"#, options: .regularExpression) else { return [] }
        let first = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let second = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard first.count >= 2, second.count >= 3 else { return [] }
        return [first, second]
    }
    static func bilingualAliasMatches(_ a: String, _ b: String) -> Bool {
        let x = canonical(normalizeTitle(a)), y = canonical(normalizeTitle(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return bilingualAliases(a).map(canonical).contains(y) || bilingualAliases(b).map(canonical).contains(x)
    }
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let x = canonical(a), y = canonical(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        func names(_ s: String) -> Set<String> {
            let separated = s.replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?|with)\s+"#, with: "/", options: [.regularExpression, .caseInsensitive])
            return Set(separated.components(separatedBy: CharacterSet(charactersIn: ",，&/、;；")).map(canonical).filter { !$0.isEmpty })
        }
        return !names(a).intersection(names(b)).isEmpty
    }
    static func versionsCompatible(_ a: String, _ b: String) -> Bool {
        func versions(_ s: String) -> Set<String> {
            let text = s.lowercased()
            let groups = [["live", "现场", "演唱会"], ["remix", "混音"], ["acoustic", "不插电"],
                          ["instrumental", "伴奏"], ["cover", "翻唱"]]
            return Set(groups.enumerated().compactMap { index, words in
                words.contains { word in
                    if containsASCII(word) {
                        return text.range(of: #"\b"# + word + #"\b"#, options: .regularExpression) != nil
                    }
                    return text.contains(word)
                } ? String(index) : nil
            })
        }
        func containsASCII(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.isASCII } }
        return versions(a) == versions(b)
    }
}

struct LRCLibResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}

/// 歌词质量检测：识别罗马拼音版歌词（期望 CJK 但歌词纯拉丁字母）
enum LyricQuality {
    /// 含 CJK 字符（汉字或日文假名）
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }
    }

    /// 疑似罗马拼音版：歌名或艺人含 CJK（期望原文为 CJK），但歌词完全不含 CJK。
    /// 典型例：lrclib 上「All The Things You Never Knew / 王力宏」的歌词是拼音版。
    static func isLikelyRomanized(lyrics: String, track: String, artist: String) -> Bool {
        guard containsCJK(track) || containsCJK(artist) else { return false }
        return !containsCJK(lyrics)
    }
}

/// 传输层错误重试：指数退避 0.5s → 1.5s；取消时立即抛出
func withRetry<T>(attempts: Int, _ op: @escaping () async throws -> T) async throws -> T {
    var delay: UInt64 = 500_000_000
    var lastError: Error = CancellationError()
    for attempt in 0..<attempts {
        if Task.isCancelled { throw CancellationError() }
        do {
            return try await op()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            lastError = error
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 3
            }
        }
    }
    throw lastError
}

/// URLComponents.queryItems 会把空格编码为 "+"，而多数服务端只认 %20。
/// 统一用手动百分号编码（"+"、"&"、"=" 强制转义）构造 query。
extension URLComponents {
    mutating func setQuery(_ items: [URLQueryItem]) {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        percentEncodedQuery = items.map {
            "\($0.name)=\($0.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// 公共 HTTP GET（10s 超时；NetEase 需要 Referer 与浏览器 UA；5xx 视为可重试错误）
private func httpGet(_ comps: URLComponents, referer: String? = nil, browserUA: Bool = false) async throws -> (Data, HTTPURLResponse) {
    var req = URLRequest(url: comps.url!)
    req.setValue(browserUA ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" : "LyrX/1.0.0 (macOS)",
                forHTTPHeaderField: "User-Agent")
    if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
    req.timeoutInterval = 10
    let (data, resp) = try await LyricsHTTP.data(for: req)
    let http = resp
    if (500..<600).contains(http.statusCode) { throw URLError(.badServerResponse) }
    return (data, http)
}

/// 主歌词源：lrclib.net（免费、无需密钥）
/// 多级匹配：原始参数精确 → 归一化精确 → track+artist 搜索打分 → q 全文模糊 → 仅歌名兜底
enum LyricsService {
    /// 带重试的获取：传输层/5xx 错误重试 3 次；找不到返回 nil。
    /// strictDuration=true（别名路径）：专辑匹配或时长≤3s 二选一作为放行门槛，防止错配
    /// （时长在±5s内的同艺人异曲确实存在，单靠时长无法区分，专辑名是强信号）。
    static func fetchWithRetry(track: String, artist: String, album: String, duration: Double, strictDuration: Bool = false) async throws -> LRCLibResponse? {
        try await withRetry(attempts: 3) {
            try await fetchBest(track: track, artist: artist, album: album, duration: duration, strictDuration: strictDuration)
        }
    }

    private static func fetchBest(track: String, artist: String, album: String, duration: Double, strictDuration: Bool) async throws -> LRCLibResponse? {
        let normTrack = TextNormalizer.normalizeTitle(track)
        let normArtist = TextNormalizer.normalizeArtist(artist)

        // 1)+2) 精确匹配：原始参数与归一化参数并行发出（独立请求，延迟减半）
        let needNorm = (normTrack != track || normArtist != artist)
        async let g1 = get(track: track, artist: artist, album: album, duration: duration)
        async let g2 = needNorm ? get(track: normTrack, artist: normArtist, album: album, duration: duration) : nil
        if let r = try await g1, let best = pickBest([r], track: track, artist: artist, album: album, duration: duration, strictDuration: strictDuration) { return best }
        if let r = try await g2, let best = pickBest([r], track: track, artist: artist, album: album, duration: duration, strictDuration: strictDuration) { return best }

        // 3) 结构化搜索：原始与归一化标题并行各查一次，合并候选打分选优
        async let s1 = search(track: track, artist: artist)
        async let s2 = normTrack != track ? search(track: normTrack, artist: normArtist) : []
        let candidates = try await s1 + s2
        if let best = pickBest(candidates, track: track, artist: normArtist, album: album, duration: duration, strictDuration: strictDuration) { return best }

        // 4) 全文模糊搜索（歌名 + 艺人）
        let fuzzy = try await searchQuery("\(normTrack) \(normArtist)".trimmingCharacters(in: .whitespaces))
        if let best = pickBest(fuzzy, track: track, artist: normArtist, album: album, duration: duration, strictDuration: strictDuration) { return best }

        // 5) 双语标题跨库可能只保留一种语言；搜索别名，但仍以原始标题校验身份。
        for alias in TextNormalizer.bilingualAliases(track) {
            let candidates = try await search(track: alias, artist: normArtist)
            if let best = pickBest(candidates, track: track, artist: normArtist, album: album, duration: duration, strictDuration: strictDuration) { return best }
        }
        let titleOnly = try await searchQuery(normTrack)
        return pickBest(titleOnly, track: track, artist: normArtist, album: album, duration: duration, strictDuration: strictDuration)
    }

    private static func get(track: String, artist: String, album: String, duration: Double) async throws -> LRCLibResponse? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.setQuery([
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ])
        let (data, resp) = try await httpGet(comps)
        if resp.statusCode == 404 { return nil }
        guard (200..<300).contains(resp.statusCode) else { return nil }
        return try JSONDecoder().decode(LRCLibResponse.self, from: data)
    }

    private static func search(track: String, artist: String) async throws -> [LRCLibResponse] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.setQuery([
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ])
        let (data, resp) = try await httpGet(comps)
        guard (200..<300).contains(resp.statusCode) else { return [] }
        return (try? JSONDecoder().decode([LRCLibResponse].self, from: data)) ?? []
    }

    private static func searchQuery(_ q: String) async throws -> [LRCLibResponse] {
        guard !q.isEmpty else { return [] }
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.setQuery([URLQueryItem(name: "q", value: q)])
        let (data, resp) = try await httpGet(comps)
        guard (200..<300).contains(resp.statusCode) else { return [] }
        return (try? JSONDecoder().decode([LRCLibResponse].self, from: data)) ?? []
    }

    /// 标题完整匹配、版本一致、艺人可信且时长差不超过 6 秒，再按专辑与歌词质量排序。
    static func pickBest(_ candidates: [LRCLibResponse], track: String, artist: String, album: String, duration: Double, strictDuration: Bool = false) -> LRCLibResponse? {
        let expectCJK = LyricQuality.containsCJK(track) || LyricQuality.containsCJK(artist)
        var best: (result: LRCLibResponse, score: Int)?
        for c in candidates {
            guard let name = c.trackName,
                  TextNormalizer.versionsCompatible(name, track),
                  c.syncedLyrics?.isEmpty == false || c.plainLyrics?.isEmpty == false else { continue }
            let artistHit = TextNormalizer.artistsMatch(c.artistName ?? "", artist)
            let albumHit = !album.isEmpty && TextNormalizer.looselyEqual(c.albumName ?? "", album)
            let knownDuration = duration > 0 && (c.duration ?? 0) > 0
            let difference = abs((c.duration ?? 0) - duration)
            let titleHit = TextNormalizer.looselyEqual(name, track)
            let verifiedAlias = TextNormalizer.bilingualAliasMatches(name, track) && artistHit && knownDuration && difference <= 3
            guard titleHit || verifiedAlias else { continue }
            if knownDuration && difference > 6 { continue }
            // 已知艺人不同就拒绝；缺失艺人时须同时有专辑和时长支持。
            if !artist.isEmpty && !artistHit {
                guard (c.artistName ?? "").isEmpty, albumHit, knownDuration, difference <= 3 else { continue }
            }
            if strictDuration && !albumHit && !(knownDuration && difference <= 3) { continue }
            var score = artistHit ? 12 : 0
            if albumHit { score += 6 }
            if knownDuration && difference <= 3 { score += 3 }
            if c.syncedLyrics?.isEmpty == false { score += 4 }
            if expectCJK && LyricQuality.containsCJK((c.syncedLyrics ?? "") + (c.plainLyrics ?? "")) { score += 4 }
            if best == nil || score > best!.score { best = (c, score) }
        }
        return best?.result
    }

}

/// 备用歌词源：网易云音乐（中文曲库覆盖好，返回标准 LRC）
enum NetEaseLyricsService {
    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                let id: Int
                let name: String?
                let artists: [Artist]?
                let duration: Int?
                let dt: Int?
            }
            let songs: [Song]?
        }
        let result: Result?
    }
    private struct LyricResponse: Decodable {
        struct LRC: Decodable { let lyric: String? }
        let lrc: LRC?
        let yrc: LRC?
    }

    /// 搜索最佳匹配曲目并取回 LRC；找不到返回 nil，传输错误重试 2 次后抛出
    static func fetchLRC(track: String, artist: String) async throws -> String? {
        try await withRetry(attempts: 2) {
            if let lrc = try await fetchLRCOnce(track: track, artist: artist) { return lrc }
            // 归一化标题再试（去 （Live）/（现场版）等后缀）
            let norm = TextNormalizer.normalizeTitle(track)
            if norm != track && TextNormalizer.versionsCompatible(norm, track) { return try await fetchLRCOnce(track: norm, artist: artist) }
            return nil
        }
    }

    /// 别名解析：从搜索结果的双标题（如「你不知道的事 | All The Things You Never Knew」）
    /// 中提取含 CJK 的别名标题，供其他源用中文标题重新查询。
    /// 只使用标题元数据，不使用任何翻唱歌词。
    static func resolveAliasTitle(track: String, artist: String) async -> String? {
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.setQuery([
            URLQueryItem(name: "s", value: "\(track) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ])
        guard let (data, resp) = try? await httpGet(comps, referer: "https://music.163.com", browserUA: true),
              (200..<300).contains(resp.statusCode),
              let songs = try? JSONDecoder().decode(SearchResponse.self, from: data).result?.songs else { return nil }
        for s in songs {
            guard let rawName = s.name, LyricQuality.containsCJK(rawName),
                  (s.artists ?? []).contains(where: { TextNormalizer.artistsMatch($0.name ?? "", artist) }) else { continue }
            let name = TextNormalizer.normalizeTitle(rawName)
            // 整名需与原题宽松匹配（确保是同一首歌）
            guard TextNormalizer.looselyEqual(name, track) else { continue }
            // 按常见分隔符切段，取含 CJK 且与原题不同的段
            for part in name.split(whereSeparator: { "|｜-–—/／".contains($0) }) {
                let p = TextNormalizer.normalizeTitle(String(part))
                if !p.isEmpty, LyricQuality.containsCJK(p), !TextNormalizer.looselyEqual(p, track) {
                    return p
                }
            }
        }
        return nil
    }

    private static func fetchLRCOnce(track: String, artist: String) async throws -> String? {
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.setQuery([
            URLQueryItem(name: "s", value: "\(track) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ])
        let (data, resp) = try await httpGet(comps, referer: "https://music.163.com", browserUA: true)
        guard (200..<300).contains(resp.statusCode) else { return nil }
        let songs = try JSONDecoder().decode(SearchResponse.self, from: data).result?.songs ?? []
        guard !songs.isEmpty else { return nil }

        // 硬性要求标题宽松匹配（防止拿到同名异曲/翻唱的错误歌词）
        let titleMatched = songs.filter { s in
            s.name.map { TextNormalizer.looselyEqual($0, track) && TextNormalizer.versionsCompatible($0, track) } ?? false
        }
        guard !titleMatched.isEmpty else { return nil }
        func artistMatch(_ s: SearchResponse.Result.Song) -> Bool {
            (s.artists ?? []).contains {
                let n = ($0.name ?? "").lowercased()
                return TextNormalizer.artistsMatch(n, artist)
            }
        }
        // 已知艺人时必须匹配，避免自动选择同名翻唱。
        let artistMatched = titleMatched.filter(artistMatch)
        let pool = artist.isEmpty ? titleMatched : artistMatched
        for song in pool.prefix(3) {
            if let lrc = try await fetchLyric(id: song.id), !lrc.isEmpty {
                return lrc
            }
        }
        return nil
    }

    private static func fetchLyric(id: Int) async throws -> String? {
        var comps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comps.setQuery([
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ])
        let (data, resp) = try await httpGet(comps, referer: "https://music.163.com", browserUA: true)
        guard (200..<300).contains(resp.statusCode) else { return nil }
        return try JSONDecoder().decode(LyricResponse.self, from: data).lrc?.lyric
    }

    /// 取 LRC + YRC（逐词，若该曲有）；供适配层使用
    static func fetchLRCAndYRC(id: Int) async throws -> (lrc: String?, yrc: String?) {
        var comps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comps.setQuery([
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "yv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ])
        let (data, resp) = try await httpGet(comps, referer: "https://music.163.com", browserUA: true)
        guard (200..<300).contains(resp.statusCode) else { return (nil, nil) }
        let r = try JSONDecoder().decode(LyricResponse.self, from: data)
        return (r.lrc?.lyric, r.yrc?.lyric)
    }

    /// 返回标题匹配（艺人优先）的候选歌曲 ID 列表，供 AMLL 等外部源按 ID 取词
    /// 带 10 分钟内存缓存：AMLL 快路径与 NetEase 源会对同一曲目各调一次，缓存消除重复搜索
    static func resolveSongIDs(track: String, artist: String, duration: Double = 0) async -> [Int] {
        let cacheKey = "\(track)|\(artist)|\(Int(duration))".lowercased()
        if let hit = songIDCache.value(for: cacheKey) { return hit }
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.setQuery([
            URLQueryItem(name: "s", value: "\(track) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ])
        guard let (data, resp) = try? await httpGet(comps, referer: "https://music.163.com", browserUA: true),
              (200..<300).contains(resp.statusCode),
              let songs = try? JSONDecoder().decode(SearchResponse.self, from: data).result?.songs else { return [] }
        let titleMatched = songs.filter { s in
            guard let name = s.name, TextNormalizer.looselyEqual(name, track), TextNormalizer.versionsCompatible(name, track) else { return false }
            if duration > 0, let milliseconds = s.duration ?? s.dt, milliseconds > 0,
               abs(Double(milliseconds) / 1000 - duration) > 6 { return false }
            return true
        }
        // 已知艺人时必须匹配。
        func artistMatch(_ s: SearchResponse.Result.Song) -> Bool {
            (s.artists ?? []).contains {
                let n = ($0.name ?? "").lowercased()
                return TextNormalizer.artistsMatch(n, artist)
            }
        }
        let artistMatched = titleMatched.filter(artistMatch)
        let ids = (artist.isEmpty ? titleMatched : artistMatched).map(\.id)
        songIDCache.store(ids, for: cacheKey)
        return ids
    }

    /// 简易线程安全 TTL 缓存（搜索 ID 用）
    private final class SongIDCache: @unchecked Sendable {
        private var map: [String: (ids: [Int], at: Date)] = [:]
        private let lock = NSLock()
        private let ttl: TimeInterval = 600
        func value(for key: String) -> [Int]? {
            lock.lock(); defer { lock.unlock() }
            guard let e = map[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
            return e.ids
        }
        func store(_ ids: [Int], for key: String) {
            lock.lock(); defer { lock.unlock() }
            map[key] = (ids, Date())
        }
    }
    private static let songIDCache = SongIDCache()
}
