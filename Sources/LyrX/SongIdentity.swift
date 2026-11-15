import Foundation
import CryptoKit

/// 由 Apple 同一歌曲/艺人 ID 证实的名称。保留成组元数据，避免任意拼接不同歌曲的标题与专辑。
struct SongIdentity: Codable, Sendable {
    struct Variant: Codable, Sendable, Equatable {
        var catalogID: String
        var artistID: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }
    var variants: [Variant]
    var catalogIDs: Set<String> { Set(variants.map(\.catalogID)) }
    func queries(for query: LyricsQuery, provider: String) -> [LyricsQuery] {
        let prefersChinese = ["netease", "amll"].contains(provider)
        var candidates = variants.map { LyricsQuery(track: $0.title, artist: $0.artist, album: $0.album, duration: query.duration) }
        candidates.append(query)
        candidates.sort {
            let a = LyricQuality.containsCJK($0.track + $0.artist) == prefersChinese
            let b = LyricQuality.containsCJK($1.track + $1.artist) == prefersChinese
            return a && !b
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert([TextNormalizer.canonical($0.track), TextNormalizer.canonical($0.artist), TextNormalizer.canonical($0.album)].joined(separator: "|")).inserted }.prefix(3).map { $0 }
    }
    func accepts(id: String, duration: Double) -> Bool {
        duration.isFinite && duration > 0 && variants.contains { $0.catalogID == id && abs($0.duration - duration) <= 3 }
    }
}

/// 无账户、无令牌的公开目录查询。只保存 ID 和名称；不保存响应中的图片、价格或其他字段。
actor SongIdentityResolver {
    typealias Transport = @Sendable (URL) async throws -> Data
    static let shared = SongIdentityResolver()
    struct CatalogResponse: Decodable {
        struct Item: Decodable, Sendable {
            var kind: String?
            var trackId: Int64?
            var artistId: Int64?
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var trackTimeMillis: Double?
            var variant: SongIdentity.Variant? {
                guard kind == "song", let trackId, let artistId, let trackName, let artistName,
                      let collectionName, let trackTimeMillis, trackTimeMillis > 0 else { return nil }
                return .init(catalogID: String(trackId), artistID: String(artistId), title: trackName,
                             artist: artistName, album: collectionName, duration: trackTimeMillis / 1000)
            }
        }
        var results: [Item]
    }
    private struct Entry: Codable { var identity: SongIdentity; var savedAt: Date }
    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<SongIdentity?, Never>] = [:]
    private let directory: URL?
    private let transport: Transport
    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("LyricsOverlay/song-identities-v1"),
         transport: @escaping Transport = { url in
             var request = URLRequest(url: url); request.timeoutInterval = 5
             let (data, response) = try await LyricsHTTP.data(for: request)
             guard response.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
             return data
         }) {
        self.directory = directory; self.transport = transport
    }
    func resolve(_ query: LyricsQuery) async -> SongIdentity? {
        guard !Task.isCancelled, !query.track.isEmpty, !query.artist.isEmpty,
              query.duration.isFinite, query.duration > 0 else { return nil }
        let key = SHA256.hash(data: Data("\(query.track)|\(query.artist)|\(query.album)|\(query.duration)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = memory[key], Date().timeIntervalSince(cached.savedAt) < 30 * 86400 { return cached.identity }
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
           let cached = try? JSONDecoder().decode(Entry.self, from: data), Date().timeIntervalSince(cached.savedAt) < 30 * 86400 {
            memory[key] = cached; return cached.identity
        }
        if let task = inFlight[key] { return await task.value }
        let transport = transport
        let task = Task { await Self.lookup(query, transport: transport) }
        inFlight[key] = task
        let identity = await task.value
        inFlight[key] = nil
        if let identity {
            let entry = Entry(identity: identity, savedAt: Date()); memory[key] = entry
            if memory.count > 64, let oldest = memory.min(by: { $0.value.savedAt < $1.value.savedAt })?.key { memory[oldest] = nil }
            if let directory, let data = try? JSONEncoder().encode(entry) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
            }
        }
        return Task.isCancelled ? nil : identity
    }
    nonisolated static func url(path: String, values: [String: String]) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/" + path)!
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    private nonisolated static func request(_ url: URL, transport: Transport) async -> [CatalogResponse.Item] {
        guard !Task.isCancelled, let data = try? await transport(url), data.count <= 2_000_000 else { return [] }
        return (try? JSONDecoder().decode(CatalogResponse.self, from: data).results) ?? []
    }
    nonisolated static func seeds(_ candidates: [SongIdentity.Variant], for query: LyricsQuery) -> [SongIdentity.Variant] {
        let compatible = candidates.filter {
            abs($0.duration - query.duration) <= 3 && TextNormalizer.versionsCompatible($0.title, query.track)
        }
        func title(_ item: SongIdentity.Variant) -> Bool {
            TextNormalizer.looselyEqual(item.title, query.track) || TextNormalizer.bilingualAliasMatches(item.title, query.track)
        }
        func artist(_ item: SongIdentity.Variant) -> Bool { TextNormalizer.artistsMatch(item.artist, query.artist) }
        let direct = compatible.filter { title($0) && artist($0) }
        let pool: [SongIdentity.Variant]
        if !direct.isEmpty { pool = direct }
        else {
            // 初次身份锚点至少要有标题/艺人之一、专辑和亚秒级时长同时吻合。
            // 搜索排名本身、单独相近的时长都不构成身份依据。
            pool = compatible.filter {
                (title($0) || artist($0)) && !query.album.isEmpty && TextNormalizer.looselyEqual($0.album, query.album) && abs($0.duration - query.duration) <= 0.75
            }
        }
        guard Set(pool.map(\.artistID)).count == 1 else { return [] }
        let albumMatches = pool.filter { TextNormalizer.looselyEqual($0.album, query.album) }
        let preferred = albumMatches.isEmpty ? pool : albumMatches
        // 标题不相同且没有相同 catalog ID 的多个候选，不能用时长猜是哪首歌。
        let titles = Set(preferred.map { TextNormalizer.canonical(TextNormalizer.normalizeTitle($0.title)) })
        if titles.count > 1 && Set(preferred.map(\.catalogID)).count > 1 && preferred.contains(where: { !title($0) }) { return [] }
        return Array(preferred.sorted { abs($0.duration - query.duration) < abs($1.duration - query.duration) }.prefix(3))
    }
    private nonisolated static func lookup(_ query: LyricsQuery, transport: Transport) async -> SongIdentity? {
        let term = "\(query.track) \(query.artist)"
        @Sendable func search(_ country: String, _ term: String) async -> [CatalogResponse.Item] {
            await request(url(path: "search", values: ["term": term, "country": country, "entity": "song", "limit": "25"]), transport: transport)
        }
        async let hk = search("hk", term)
        async let us = search("us", term)
        var candidates = await (hk + us).compactMap(\.variant)
        var selected = seeds(candidates, for: query)
        if selected.isEmpty {
            async let titleHK = search("hk", TextNormalizer.normalizeTitle(query.track))
            async let titleUS = search("us", TextNormalizer.normalizeTitle(query.track))
            candidates += await (titleHK + titleUS).compactMap(\.variant)
            selected = seeds(candidates, for: query)
        }
        guard !selected.isEmpty, !Task.isCancelled else { return nil }
        let ids = Set(selected.map(\.catalogID)).sorted().joined(separator: ",")
        async let localized = request(url(path: "lookup", values: ["id": ids, "country": "tw", "entity": "song"]), transport: transport)
        async let english = request(url(path: "lookup", values: ["id": ids, "country": "us", "entity": "song"]), transport: transport)
        let variants = await (localized + english).compactMap(\.variant).filter { variant in
            selected.contains { $0.catalogID == variant.catalogID && $0.artistID == variant.artistID && abs($0.duration - variant.duration) <= 1 && TextNormalizer.versionsCompatible($0.title, variant.title) }
        }
        // 某首歌可能未在另一地区上架，但同一 artist ID 的官方名称仍可解析。
        let artistIDs = Set(selected.map(\.artistID)).sorted().joined(separator: ",")
        let artists = await request(url(path: "lookup", values: ["id": artistIDs, "country": "us", "entity": "musicArtist"]), transport: transport)
        var all = selected + variants
        for artist in artists {
            guard let id = artist.artistId.map(String.init), let name = artist.artistName else { continue }
            for variant in selected + variants where variant.artistID == id {
                var renamed = variant; renamed.artist = name; all.append(renamed)
            }
        }
        var seen = Set<String>()
        all = all.filter { seen.insert("\($0.catalogID)|\($0.title)|\($0.artist)|\($0.album)").inserted }
        return SongIdentity(variants: all)
    }
}

struct IdentityLyricsSource: LyricsSource {
    let base: any LyricsSource
    let identity: SongIdentity
    var id: String { base.id }
    var isEnabled: Bool { base.isEnabled }
    func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
        var backup: LyricsResult?
        var lastError: Error?
        for alternative in identity.queries(for: query, provider: id) {
            try Task.checkCancellation()
            do {
                if let result = try await base.fetch(alternative) {
                    if !result.isPlain { return result }
                    if backup == nil { backup = result }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                // 网络故障时继续改搜索文字不会恢复同一服务。
                break
            }
        }
        if let backup { return backup }
        if let lastError { throw lastError }
        return nil
    }
}
