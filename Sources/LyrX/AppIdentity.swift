import AppKit
import CoreServices

enum AppIdentity {
    static let bundleID = "com.local.lyrx"
    static let legacyBundleID = "com.local.lyricsoverlay"
    static let migrationKey = "lyrx.didMigrateLegacyPreferences.v1"

    @MainActor static var applicationIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    @MainActor static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: info["CFBundleDisplayName"] as? String ?? "LyrX",
            .applicationVersion: info["CFBundleShortVersionString"] as? String ?? "版本信息不可用",
            .version: info["CFBundleVersion"] as? String ?? ""
        ]
        if let icon = applicationIcon { options[.applicationIcon] = icon }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: "为 Apple Music 打造的桌面悬浮歌词工具。\n\nGitHub",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph])
        credits.addAttribute(.link, value: URL(string: "https://github.com/yish1san/LyrX")!,
                             range: (credits.string as NSString).range(of: "GitHub"))
        options[.credits] = credits
        return options
    }

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
