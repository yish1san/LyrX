import Foundation
import Security
import SwiftUI

protocol LyricsSecretStorage {
    func read() throws -> String?
    func write(_ secret: String) throws
    func delete() throws
}

enum LyricsSecretError: Error { case keychain(OSStatus), invalidData, verificationFailed }

/// 只访问 LyrX 自己的一个通用密码项目，不查询其他账户或浏览器凭据。
struct KeychainLyricsSecretStorage: LyricsSecretStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.local.lyrx.lyrics.credentials",
         kSecAttrAccount as String: "musixmatch.apikey"]
    }
    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LyricsSecretError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw LyricsSecretError.invalidData
        }
        return value
    }
    func write(_ secret: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "LyrX · Musixmatch API"
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw LyricsSecretError.keychain(added) }
        } else if status != errSecSuccess { throw LyricsSecretError.keychain(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LyricsSecretError.keychain(status) }
    }
}

struct LyricsCredentialMigration {
    let storage: any LyricsSecretStorage
    let defaults: UserDefaults
    let domains: [String]
    static let apiKey = "musixmatch.apikey"
    static let unusedKeys = ["deezer.arl", "netease.cookie"]

    func migrate() throws -> String? {
        clear(keys: Self.unusedKeys)
        let saved = try storage.read()
        let legacy = domains.lazy.compactMap {
            defaults.persistentDomain(forName: $0)?[Self.apiKey] as? String
        }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let key = saved?.isEmpty == false ? saved : legacy?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, saved != key {
            try storage.write(key)
            guard try storage.read() == key else { throw LyricsSecretError.verificationFailed }
        }
        // 写入并读回成功后才删除旧明文；失败时保留原值供解锁后重试。
        clear(keys: [Self.apiKey])
        return key
    }

    func clear(keys: [String]) {
        for name in domains {
            guard var domain = defaults.persistentDomain(forName: name) else { continue }
            let before = domain.count
            for key in keys { domain.removeValue(forKey: key) }
            if domain.count != before { defaults.setPersistentDomain(domain, forName: name) }
        }
    }
}

enum LyricsCredentials {
    private static let storage = KeychainLyricsSecretStorage()
    private static let lock = NSLock()
    private static var cachedKey: String?
    private static var pending = false
    private static var migration: LyricsCredentialMigration {
        LyricsCredentialMigration(storage: storage, defaults: .standard,
                                  domains: [AppIdentity.bundleID, AppIdentity.legacyBundleID])
    }
    static var musixmatchAPIKey: String? { lock.lock(); defer { lock.unlock() }; return cachedKey }
    static var needsMigration: Bool { lock.lock(); defer { lock.unlock() }; return pending }

    static func prepare() throws {
        do {
            let key = try migration.migrate()
            lock.lock(); cachedKey = key; pending = false; lock.unlock()
        } catch {
            lock.lock(); pending = true; lock.unlock()
            throw error
        }
    }
    static func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LyricsSecretError.invalidData }
        try storage.write(value)
        guard try storage.read() == value else { throw LyricsSecretError.verificationFailed }
        migration.clear(keys: [LyricsCredentialMigration.apiKey] + LyricsCredentialMigration.unusedKeys)
        lock.lock(); cachedKey = value; pending = false; lock.unlock()
    }
    static func remove() throws {
        try storage.delete()
        migration.clear(keys: [LyricsCredentialMigration.apiKey] + LyricsCredentialMigration.unusedKeys)
        lock.lock(); cachedKey = nil; pending = false; lock.unlock()
    }
}

struct LyricsCredentialSection: View {
    @State private var expanded = false
    @State private var draft = ""
    @State private var configured = LyricsCredentials.musixmatchAPIKey != nil
    @State private var pending = LyricsCredentials.needsMigration
    @State private var message: String?

    var body: some View {
        Section {
            DisclosureGroup("可选词源 · Musixmatch", isExpanded: $expanded) {
                if configured { Text("API 密钥已保存在钥匙串中。").font(.caption).foregroundStyle(.secondary) }
                SecureField(configured ? "输入新 API 密钥" : "API 密钥", text: $draft)
                HStack {
                    Button("保存密钥") {
                        perform { try LyricsCredentials.save(draft) }
                    }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除密钥") { perform { try LyricsCredentials.remove() } }
                        .disabled(!configured && !pending)
                }
            }
            if pending {
                Text("钥匙串暂不可用，旧密钥尚未迁移。请解锁钥匙串后重试。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重试迁移") { perform { try LyricsCredentials.prepare() } }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        guard !AppIdentity.isPreview else { draft = ""; return }
        do {
            try action(); draft = ""; message = nil
        } catch { message = "无法更新密钥，请解锁钥匙串后重试。" }
        configured = LyricsCredentials.musixmatchAPIKey != nil
        pending = LyricsCredentials.needsMigration
    }
}
