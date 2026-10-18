import AppKit
import CoreServices

enum AppIdentity {
    static let bundleID = "com.local.lyrx"
    static let legacyBundleID = "com.local.lyricsoverlay"
    static let migrationKey = "lyrx.didMigrateLegacyPreferences.v1"

    static var isPreview: Bool {
        isPreview(arguments: CommandLine.arguments, bundleID: Bundle.main.bundleIdentifier)
    }

    static func isPreview(arguments: [String], bundleID: String?) -> Bool {
        arguments.contains("--preview") || [self.bundleID, legacyBundleID].contains {
            bundleID?.hasPrefix($0 + ".preview") == true
        }
    }

    static func prepareForLaunch() {
        guard !isPreview, Bundle.main.bundleIdentifier == bundleID else { return }
        migratePreferences()
        try? LyricsCredentials.prepare()
        registerCurrentApplication()
    }

    // 系统权限使用新身份；仅迁移应用自己的设置，不修改旧域或权限数据库。
    static func migratePreferences(defaults: UserDefaults = .standard,
                                   from oldDomain: String = legacyBundleID,
                                   to newDomain: String = bundleID) {
        var current = defaults.persistentDomain(forName: newDomain) ?? [:]
        guard current[migrationKey] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: oldDomain) ?? [:]
        for (key, value) in legacy where key.hasPrefix("overlay.") {
            if current[key] == nil { current[key] = value }
        }
        current[migrationKey] = true
        defaults.setPersistentDomain(current, forName: newDomain)
    }

    static func registerCurrentApplication() {
        guard !isPreview, Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        // 刷新当前包的名称、图标与位置，避免从旧版记录解析显示名称。
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }
}
