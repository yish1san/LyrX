import XCTest
@testable import LyrX

final class SongIdentityTests: XCTestCase {
    let chinese = SongIdentity.Variant(catalogID: "1134344911", artistID: "117741179", title: "愛錯", artist: "王力宏", album: "心中的日月", duration: 238.827)
    let english = SongIdentity.Variant(catalogID: "1134344911", artistID: "117741179", title: "Wrong Love", artist: "Wang Leehom", album: "Shangri-La", duration: 238.827)
    func testDifferentRegionNamesGenerateProviderSpecificQueries() {
        let identity = SongIdentity(variants: [english, chinese])
        let query = LyricsQuery(track: english.title, artist: english.artist, album: english.album, duration: english.duration)
        XCTAssertEqual(identity.queries(for: query, provider: "netease").first?.track, "愛錯")
        XCTAssertEqual(identity.queries(for: query, provider: "lrclib").first?.track, "Wrong Love")
        XCTAssertTrue(identity.accepts(id: chinese.catalogID, duration: 238.827))
        XCTAssertFalse(identity.accepts(id: "other", duration: 238.827))
        XCTAssertFalse(identity.accepts(id: chinese.catalogID, duration: 280))
    }
    func testAmbiguousArtistAndLiveVersionAreRejected() {
        let query = LyricsQuery(track: "爱错", artist: "王力宏", album: "心中的日月", duration: 238.827)
        var cover = chinese; cover.artistID = "wrong"; cover.artist = "Another Artist"
        XCTAssertEqual(SongIdentityResolver.seeds([cover], for: query).count, 1) // strict title + album + subsecond duration anchor
        XCTAssertTrue(SongIdentityResolver.seeds([cover, { var x = cover; x.artistID = "second"; return x }()], for: query).isEmpty)
        var live = chinese; live.title += " (Live)"
        XCTAssertTrue(SongIdentityResolver.seeds([live], for: query).isEmpty)
        cover.album = "Cover Album"
        XCTAssertTrue(SongIdentityResolver.seeds([cover], for: query).isEmpty)
    }
    func testNativeLyricsUseVerifiedIDAcrossCompletelyDifferentText() throws {
        let query = LyricsQuery(track: english.title, artist: english.artist, album: english.album, duration: english.duration,
                                identity: SongIdentity(variants: [chinese, english]))
        let root: [String: Any] = ["data": [["id": chinese.catalogID, "attributes": ["name": chinese.title, "artistName": chinese.artist, "albumName": chinese.album, "durationInMillis": 238827], "relationships": ["lyrics": ["data": [["attributes": ["ttml": "<tt><body><p begin=\"1s\" end=\"3s\">测试</p></body></tt>"]]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertNotNil(AppleMusicLyricsCache.decode(data, for: query))
        var unrelated = query; unrelated.identity = SongIdentity(variants: [])
        XCTAssertNil(AppleMusicLyricsCache.decode(data, for: unrelated))
    }
    func testResolverBindsTranslationsBySameSongAndArtistID() async throws {
        let resolver = SongIdentityResolver(directory: nil) { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let english = q["country"] == "us"
            let item: [String: Any] = ["kind": "song", "trackId": 1134344911, "artistId": 117741179,
                                      "trackName": english ? "Wrong Love" : "愛錯", "artistName": english ? "Wang Leehom" : "王力宏",
                                      "collectionName": english ? "Shangri-La" : "心中的日月", "trackTimeMillis": 238827]
            return try JSONSerialization.data(withJSONObject: ["results": [item]])
        }
        let query = LyricsQuery(track: "Wrong Love", artist: "Wang Leehom", album: "Shangri-La", duration: 238.827)
        let identity = await resolver.resolve(query)
        XCTAssertTrue(identity?.variants.contains(where: { $0.title == "愛錯" && $0.artist == "王力宏" }) == true)
        XCTAssertEqual(identity?.catalogIDs, ["1134344911"])
    }
    func testEveryExternalProviderReceivesResolvedNames() async throws {
        struct Source: LyricsSource {
            let id: String
            let isEnabled = true
            func fetch(_ query: LyricsQuery) async throws -> LyricsResult? {
                let chinese = ["netease", "amll"].contains(id)
                guard query.track == (chinese ? "愛錯" : "Wrong Love"),
                      query.artist == (chinese ? "王力宏" : "Wang Leehom") else { return nil }
                return LyricsResult(lines: [LyricLine(time: 1, text: "fixture")], sourceID: id, isWordSynced: false)
            }
        }
        let identity = SongIdentity(variants: [chinese, english])
        let query = LyricsQuery(track: "愛錯", artist: "Wang Leehom", album: "Shangri-La", duration: 238.827)
        for id in ["netease", "amll", "lrclib", "musixmatch"] {
            let result = try await IdentityLyricsSource(base: Source(id: id), identity: identity).fetch(query)
            XCTAssertEqual(result?.sourceID, id)
        }
    }
    func testLiveAppleIdentityForWrongLove() async throws {
        guard ProcessInfo.processInfo.environment["LYRX_LIVE_IDENTITY"] == "1" else { throw XCTSkip("Explicit live catalog test") }
        let resolver = SongIdentityResolver(directory: nil)
        let identity = await resolver.resolve(LyricsQuery(track: "Wrong Love", artist: "Wang Leehom", album: "Shangri-La", duration: 238.827))
        XCTAssertTrue(identity?.variants.contains(where: { TextNormalizer.looselyEqual($0.title, "爱错") }) == true)
    }
}
