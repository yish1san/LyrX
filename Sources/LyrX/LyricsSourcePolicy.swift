import Foundation

enum TrackLyricsSource: String, Codable, CaseIterable, Identifiable {
    case followDefault, appleMusic, automatic, lrclib, amll, netease, musixmatch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .followDefault: "跟随全局设置"
        case .appleMusic: "Apple Music"
        case .automatic: "其他词源自动匹配"
        case .lrclib: "LRCLIB"
        case .amll: "AMLL"
        case .netease: "网易云音乐"
        case .musixmatch: "Musixmatch"
        }
    }
    var providerID: String? {
        switch self { case .lrclib, .amll, .netease, .musixmatch: rawValue; default: nil }
    }
    func prefersMusic(global: Bool) -> Bool { self == .appleMusic || (self == .followDefault && global) }
}

enum LyricsSourcePolicy {
    static let musicGracePeriod: TimeInterval = 8
    static func shouldFallback(enabled: Bool, selection: TrackLyricsSource, musicPreferred: Bool,
                               hasTimedMusic: Bool, unavailable: Bool, staticLyrics: Bool) -> Bool {
        enabled && selection == .followDefault && musicPreferred && !hasTimedMusic && (unavailable || staticLyrics)
    }
}
