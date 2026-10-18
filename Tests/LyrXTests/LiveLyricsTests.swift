import XCTest
@testable import LyrX

/// 显式启用后向真实服务查询，仅断言身份与时间轴，不输出歌词正文。
final class LiveLyricsTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["LYRICSOVERLAY_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set LYRICSOVERLAY_LIVE_TESTS=1 to query live providers")
        }
    }
    func testPalePinkFromNetEase() async throws { try await check(NetEaseSource(), "淺粉紅 pale pink", 201.816) }
    func testBabyPinkFromNetEase() async throws { try await check(NetEaseSource(), "淺粉紅 baby pink", 232.319) }
    func testPalePinkFromLRCLIB() async throws { try await check(LRCLibSource(), "淺粉紅 pale pink", 201.816) }
    func testBabyPinkFromLRCLIB() async throws { try await check(LRCLibSource(), "淺粉紅 baby pink", 232.319) }
    private func check(_ source: any LyricsSource, _ title: String, _ duration: Double) async throws {
        try requireLive()
        let result = try await source.fetch(LyricsQuery(track: title, artist: "Gareth.T", album: "淺粉紅 - Single", duration: duration))
        XCTAssertNotNil(result, "\(source.id) did not match \(title)")
        XCTAssertFalse(result?.isPlain ?? true)
        XCTAssertGreaterThan(result?.lines.count ?? 0, 5)
    }
}
