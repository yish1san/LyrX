import XCTest
@testable import LyrX

private final class MemoryLyricsSecretStorage: LyricsSecretStorage {
    var value: String?
    var failRead = false
    var failWrite = false
    var discardWrite = false
    var writes = 0
    func read() throws -> String? {
        if failRead { throw LyricsSecretError.verificationFailed }
        return value
    }
    func write(_ secret: String) throws {
        writes += 1
        if failWrite { throw LyricsSecretError.verificationFailed }
        if !discardWrite { value = secret }
    }
    func delete() { value = nil }
}

final class PrivacyTests: XCTestCase {
    private var domains: [String] = []
    private var storage: MemoryLyricsSecretStorage!
    private var migration: LyricsCredentialMigration!
    override func setUp() {
        domains = (0..<2).map { _ in "LyrXTests.credentials.\(UUID().uuidString)" }
        storage = MemoryLyricsSecretStorage()
        migration = LyricsCredentialMigration(storage: storage, defaults: .standard, domains: domains)
    }
    override func tearDown() {
        for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }
    private func set(_ values: [String: Any], in index: Int) {
        UserDefaults.standard.setPersistentDomain(values, forName: domains[index])
    }
    private func value(_ key: String, in index: Int) -> Any? {
        UserDefaults.standard.persistentDomain(forName: domains[index])?[key]
    }

    func testMigrationSecuresCurrentKeyAndCleansOnlyCredentialKeys() throws {
        set(["musixmatch.apikey": "current-test-key", "netease.cookie": "unused-test-cookie", "overlay.fontSize": 22], in: 0)
        set(["musixmatch.apikey": "legacy-test-key", "deezer.arl": "unused-test-session", "unrelated": "keep"], in: 1)
        XCTAssertEqual(try migration.migrate(), "current-test-key")
        XCTAssertEqual(storage.value, "current-test-key")
        for i in 0..<2 {
            for key in ["musixmatch.apikey", "netease.cookie", "deezer.arl"] { XCTAssertNil(value(key, in: i)) }
        }
        XCTAssertEqual(value("overlay.fontSize", in: 0) as? Int, 22)
        XCTAssertEqual(value("unrelated", in: 1) as? String, "keep")
    }

    func testExistingKeychainChoiceWinsOverStalePlaintext() throws {
        storage.value = "secured-test-key"
        set(["musixmatch.apikey": "stale-test-key"], in: 0)
        XCTAssertEqual(try migration.migrate(), "secured-test-key")
        XCTAssertEqual(storage.writes, 0)
        XCTAssertNil(value("musixmatch.apikey", in: 0))
    }

    func testLegacyOnlyKeySurvivesRenameAndRepeatedMigration() throws {
        set(["musixmatch.apikey": " legacy-test-key "], in: 1)
        XCTAssertEqual(try migration.migrate(), "legacy-test-key")
        XCTAssertEqual(try migration.migrate(), "legacy-test-key")
        XCTAssertEqual(storage.writes, 1)
        XCTAssertNil(value("musixmatch.apikey", in: 1))
    }

    func testFailedWritePreservesUsableKeyForRetry() throws {
        storage.failWrite = true
        set(["musixmatch.apikey": "retry-test-key", "netease.cookie": "unused"], in: 0)
        XCTAssertThrowsError(try migration.migrate())
        XCTAssertEqual(value("musixmatch.apikey", in: 0) as? String, "retry-test-key")
        XCTAssertNil(value("netease.cookie", in: 0))
        storage.failWrite = false
        XCTAssertEqual(try migration.migrate(), "retry-test-key")
        XCTAssertNil(value("musixmatch.apikey", in: 0))
    }

    func testReadBackVerificationPreventsDataLoss() {
        storage.discardWrite = true
        set(["musixmatch.apikey": "verify-test-key"], in: 0)
        XCTAssertThrowsError(try migration.migrate())
        XCTAssertEqual(value("musixmatch.apikey", in: 0) as? String, "verify-test-key")
    }

    func testLockedKeychainDoesNotErasePendingKey() {
        storage.failRead = true
        set(["musixmatch.apikey": "pending-test-key"], in: 0)
        XCTAssertThrowsError(try migration.migrate())
        XCTAssertEqual(value("musixmatch.apikey", in: 0) as? String, "pending-test-key")
    }

    func testNoConfiguredKeyDoesNotCreateOne() throws {
        set(["deezer.arl": "unused"], in: 0)
        XCTAssertNil(try migration.migrate())
        XCTAssertEqual(storage.writes, 0)
        XCTAssertNil(value("deezer.arl", in: 0))
    }

    func testRequestsHaveNoPersistentCookiesCredentialsOrCache() {
        let configuration = LyricsHTTP.session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testOnlyExpectedHTTPSOriginsAreAllowed() {
        XCTAssertTrue(LyricsHTTP.permits(URL(string: "https://lrclib.net/api/search")))
        for url in ["http://lrclib.net/api/search", "https://mobilecdn.kugou.com/", "https://lrclib.net.evil.example/", "https://user:password@lrclib.net/", "https://lrclib.net:444/", "file:///tmp/lyrics"] {
            XCTAssertFalse(LyricsHTTP.permits(URL(string: url)))
        }
    }

    func testRedirectCannotDowngradeOrPassAPIKeyToAnotherHost() {
        let from = URL(string: "https://api.musixmatch.com/ws/1.1/track.search?apikey=test")
        XCTAssertTrue(LyricsHTTP.permitsRedirect(from: from, to: URL(string: "https://api.musixmatch.com/new")))
        XCTAssertFalse(LyricsHTTP.permitsRedirect(from: from, to: URL(string: "http://api.musixmatch.com/new")))
        XCTAssertFalse(LyricsHTTP.permitsRedirect(from: from, to: URL(string: "https://lrclib.net/new")))
        XCTAssertFalse(LyricsHTTP.permitsRedirect(from: from, to: URL(string: "https://untrusted.example/new")))
    }

    func testDefaultSourcesRemoveDiscontinuedProviders() {
        let sources = LyricsOrchestrator.makeDefault().sources.map(\.id)
        XCTAssertFalse(sources.contains("kugou"))
        XCTAssertFalse(sources.contains("deezer"))
        XCTAssertTrue(Set(["lrclib", "amll", "netease", "musixmatch"]).isSubset(of: Set(sources)))
    }
}
