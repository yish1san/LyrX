import Foundation
import CryptoKit

/// 歌词缓存：内存 + 磁盘两级，避免重复网络请求。
/// - key 为曲目唯一标识（title|artist|album），文件名取 SHA-256；
/// - 正缓存 30 天（歌词内容几乎不变），负缓存（确认无歌词）6 小时（源可能后续收录）；
/// - 传输层错误不写缓存（下次重试）。
actor LyricsCache {
    static let shared = LyricsCache()

    struct Entry: Codable {
        var result: LyricsResult? // nil = 负缓存（确认未找到）
        var note: String?         // 展示层标注（如「歌词源为拼音版」）
        var fetchedAt: Date
        var negative: Bool
        var version: Int = 0      // 缓存格式/策略版本；与当前版本不符视为失效
    }

    /// 当前缓存版本：匹配策略或数据结构修正后递增，旧条目自动失效重取
    /// v6：停用酷狗，旧条目重新匹配，避免复用已移除来源。
    private static let currentVersion = 6

    private let positiveTTL: TimeInterval = 30 * 24 * 3600
    private let negativeTTL: TimeInterval = 6 * 3600
    private var memory: [String: Entry] = [:]
    private let dir: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = directory ?? base.appendingPathComponent("LyricsOverlay/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 命中（含未过期的负缓存）返回 Entry；未命中/已过期/版本不符返回 nil
    func entry(for key: String) -> Entry? {
        if let e = memory[key], e.version == Self.currentVersion, !expired(e) { return e }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if e.version != Self.currentVersion || expired(e) {
            try? FileManager.default.removeItem(at: url)
            memory[key] = nil
            return nil
        }
        memory[key] = e
        return e
    }

    /// 写入正缓存（找到歌词，含拼音兜底）
    func store(result: LyricsResult, note: String?, for key: String) {
        write(Entry(result: result, note: note, fetchedAt: Date(), negative: false,
                    version: Self.currentVersion), for: key)
    }

    /// 写入负缓存（全链路确认无歌词；错误不缓存）
    func storeNotFound(for key: String) {
        write(Entry(result: nil, note: nil, fetchedAt: Date(), negative: true,
                    version: Self.currentVersion), for: key)
    }

    func remove(for key: String) {
        memory[key] = nil
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func write(_ e: Entry, for key: String) {
        memory[key] = e
        guard let data = try? JSONEncoder().encode(e) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func expired(_ e: Entry) -> Bool {
        let ttl = e.negative ? negativeTTL : positiveTTL
        return Date().timeIntervalSince(e.fetchedAt) > ttl
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(name).json")
    }
}
