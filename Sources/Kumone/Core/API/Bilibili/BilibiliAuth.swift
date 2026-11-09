import Combine
import Foundation
import os.log
import Security

extension Notification.Name {
    static let goliaBilibiliLoginDidUpdate = Notification.Name("goliaBilibiliLoginDidUpdate")
}

/// Bilibili session.
///
/// Ported from Beans 2.0.3 (`Beans/BilibiliLoginSheet.swift`,
/// `BilibiliAuth`), adapted to Golia's house pattern (service
/// `sb.moe.kumone.bilibili`, profile keys `sb.moe.kumone.bilibili.*`).
/// The session cookie lives ONLY in the Keychain (generic password,
/// account `account-cookie-v1`); the nickname/mid/avatar are display
/// strings in `UserDefaults` under `sb.moe.kumone.bilibili.*` keys —
/// never under `settings.*`, so they never enter SettingsBackup, and
/// no credential is ever logged.
/// `acceptCiliCiliSession` is intentionally NOT ported here: it needs
/// `import CiliCiliKit`, which KumoneCore cannot see. The phase-2
/// bridge in KumoneIOSFeature owns that handoff.
@MainActor
final class BilibiliAuth: ObservableObject {
    static let shared = BilibiliAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""
    @Published private(set) var accountID = ""
    @Published private(set) var avatarURL: URL?

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "bilibili")
    private static let keychainService = "sb.moe.kumone.bilibili"
    private static let cookieAccount = "account-cookie-v1"
    private static let nicknameDefaultsKey = "sb.moe.kumone.bilibili.nickname"
    private static let midDefaultsKey = "sb.moe.kumone.bilibili.mid"
    private static let avatarDefaultsKey = "sb.moe.kumone.bilibili.avatar"
    private let defaults = UserDefaults.standard

    private init() {
        nickname = defaults.string(forKey: Self.nicknameDefaultsKey) ?? ""
        accountID = defaults.string(forKey: Self.midDefaultsKey) ?? ""
        avatarURL = defaults.string(forKey: Self.avatarDefaultsKey).flatMap { URL(string: $0) }
        if let cookie = Self.readCookie(), !cookie.isEmpty {
            isLoggedIn = true
        }
    }

    var cookieHeader: String { BilibiliProtocol.normalizeCookie(Self.readCookie() ?? "") }

    /// Restore the visible account header after a cold launch. The cookie is
    /// persisted securely, but the profile image is only a cache and may be
    /// missing after reinstall or an older login.
    func refreshProfileIfNeeded() async {
        guard isLoggedIn, !cookieHeader.isEmpty else { return }
        do {
            let info = try await BilibiliAPI.shared.accountInfo(cookie: cookieHeader)
            nickname = info.nickname
            accountID = info.mid
            avatarURL = info.avatar
            defaults.set(info.nickname, forKey: Self.nicknameDefaultsKey)
            defaults.set(info.mid, forKey: Self.midDefaultsKey)
            if let avatar = info.avatar?.absoluteString {
                defaults.set(avatar, forKey: Self.avatarDefaultsKey)
            }
            objectWillChange.send()
        } catch {
            Self.log.error("Bilibili account refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func login(cookie: String) async throws {
        let normalized = BilibiliProtocol.normalizeCookie(cookie)
        guard BilibiliProtocol.hasSession(normalized) else {
            throw BilibiliError(message: "登录凭据不完整，请重新扫码")
        }
        let info = try await BilibiliAPI.shared.accountInfo(cookie: normalized)
        try Self.saveCookie(normalized)
        await BilibiliAPI.shared.setCookie(normalized)
        nickname = info.nickname
        accountID = info.mid
        isLoggedIn = true
        avatarURL = info.avatar
        defaults.set(info.nickname, forKey: Self.nicknameDefaultsKey)
        defaults.set(info.mid, forKey: Self.midDefaultsKey)
        defaults.set(info.avatar?.absoluteString, forKey: Self.avatarDefaultsKey)
        NotificationCenter.default.post(name: .goliaBilibiliLoginDidUpdate, object: nil)
    }

    func logout() {
        Self.deleteCookie()
        nickname = ""
        accountID = ""
        avatarURL = nil
        isLoggedIn = false
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        defaults.removeObject(forKey: Self.midDefaultsKey)
        defaults.removeObject(forKey: Self.avatarDefaultsKey)
        Task { await BilibiliAPI.shared.setCookie("") }
        NotificationCenter.default.post(name: .goliaBilibiliLoginDidUpdate, object: nil)
    }

    private static func readCookie() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cookieAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveCookie(_ cookie: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cookieAccount
        ]
        let data = Data(cookie.utf8)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        guard update == errSecItemNotFound else {
            guard update == errSecSuccess else {
                throw BilibiliError(message: "无法安全保存哔哩哔哩登录凭据（\(update)）")
            }
            return
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw BilibiliError(message: "无法安全保存哔哩哔哩登录凭据（\(add)）")
        }
    }

    private static func deleteCookie() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cookieAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
