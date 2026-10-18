import XCTest
@testable import LyrX

final class AppIdentityTests: XCTestCase {
    func testMigrationPreservesNewChoicesAndDoesNotModifyLegacyData() {
        let defaults = UserDefaults.standard
        let old = "LyrXTests.old.\(UUID().uuidString)"
        let new = "LyrXTests.new.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain([
            "overlay.fontSize": 24, "overlay.compact": true,
            "overlay.isVisible": false, "overlay.windowFrame": "saved frame",
            "netease.cookie": "test-only", "unrelated": "do not copy"
        ], forName: old)
        defaults.setPersistentDomain(["overlay.fontSize": 18], forName: new)
        AppIdentity.migratePreferences(defaults: defaults, from: old, to: new)
        let migrated = defaults.persistentDomain(forName: new)!
        XCTAssertEqual(migrated["overlay.fontSize"] as? Int, 18)
        XCTAssertEqual(migrated["overlay.compact"] as? Bool, true)
        XCTAssertEqual(migrated["overlay.isVisible"] as? Bool, false)
        XCTAssertEqual(migrated["overlay.windowFrame"] as? String, "saved frame")
        XCTAssertNil(migrated["netease.cookie"])
        XCTAssertNil(migrated["unrelated"])
        XCTAssertEqual(defaults.persistentDomain(forName: old)?["overlay.fontSize"] as? Int, 24)

        // 用户在新版移除设置后，后续启动也不能从旧版重新导入。
        var edited = migrated
        edited.removeValue(forKey: "overlay.compact")
        defaults.setPersistentDomain(edited, forName: new)
        AppIdentity.migratePreferences(defaults: defaults, from: old, to: new)
        XCTAssertNil(defaults.persistentDomain(forName: new)?["overlay.compact"])
    }

    func testPreviewRecognizesBothIdentitiesWithoutTreatingProductionAsPreview() {
        XCTAssertTrue(AppIdentity.isPreview(arguments: ["app", "--preview"], bundleID: AppIdentity.bundleID))
        XCTAssertTrue(AppIdentity.isPreview(arguments: [], bundleID: "com.local.lyrx.preview.permissions"))
        XCTAssertTrue(AppIdentity.isPreview(arguments: [], bundleID: "com.local.lyricsoverlay.preview.old"))
        XCTAssertFalse(AppIdentity.isPreview(arguments: [], bundleID: AppIdentity.bundleID))
        XCTAssertFalse(AppIdentity.isPreview(arguments: [], bundleID: nil))
    }
}

