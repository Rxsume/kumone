import CryptoKit
import Foundation
import os.log
import Security

/// KuGou login state, adapted from Beans' `KugouMusicAuth`.
///
/// Direct-to-KuGou: QR login talks to `login-user.kugou.com`, search and
/// playback talk to KuGou's public gateways. There is no self-hosted
/// backend anywhere in this file (contrast the Folia version,
/// which proxied everything through a self-hosted backend).
///
/// Storage split (same as the Folia version):
/// - Keychain ONLY (`sb.moe.kumone.kugou`, generic password, not
///   synchronizable, accessible after first unlock on this device
///   only): `token` and the full `cookie` string. Never UserDefaults.
/// - UserDefaults (non-sensitive identifiers / display data):
///   `auth.kugou.userid`, `auth.kugou.dfid`, `auth.kugou.guid`,
///   `auth.kugou.mid`, `auth.kugou.nickname`, `auth.kugou.avatar`,
///   `auth.kugou.vipType`.
///
/// `logout()` / `sessionExpired()` clear all four session items
/// (token, cookie, userid, dfid) plus the cached profile. The device
/// identifiers (`guid` / `mid`) survive logout: they identify the
/// device, not the account, and minting a new device identity on every
/// login would look like a fresh device each time.
///
/// `@MainActor` like `QQMusicAuth`: `@Published` state is only ever
/// mutated on the main actor, and API-layer callers reach the auth
/// with `await KugouMusicAuth.shared.<member>`.
@MainActor
final class KugouMusicAuth: ObservableObject {
    static let shared = KugouMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""
    @Published private(set) var vipType = 0
    @Published private(set) var avatarURL: URL?

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "kugou")

    private static let keychainService = "sb.moe.kumone.kugou"
    private static let tokenAccount = "token"
    private static let cookieAccount = "cookie"

    private static let userIDDefaultsKey = "auth.kugou.userid"
    private static let dfidDefaultsKey = "auth.kugou.dfid"
    private static let guidDefaultsKey = "auth.kugou.guid"
    private static let midDefaultsKey = "auth.kugou.mid"
    private static let nicknameDefaultsKey = "auth.kugou.nickname"
    private static let avatarDefaultsKey = "auth.kugou.avatar"
    private static let vipTypeDefaultsKey = "auth.kugou.vipType"

    /// The User-Agent Beans sends for KuGou CDN playback (see
    /// `playbackHeaders`).
    private static let playbackUserAgent =
        "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi"

    private var tokenValue = ""
    private var cookieValue = ""
    private var userIDValue = ""
    private var dfidValue = ""
    private var guidValue = ""
    private var midValue = ""

    private let defaults = UserDefaults.standard

    private init() {
        tokenValue = Self.keychainLoad(account: Self.tokenAccount) ?? ""
        cookieValue = Self.keychainLoad(account: Self.cookieAccount) ?? ""
        userIDValue = (defaults.string(forKey: Self.userIDDefaultsKey) ?? "").filter(\.isNumber)
        dfidValue = defaults.string(forKey: Self.dfidDefaultsKey) ?? ""
        guidValue = defaults.string(forKey: Self.guidDefaultsKey) ?? ""
        midValue = defaults.string(forKey: Self.midDefaultsKey) ?? ""
        nickname = defaults.string(forKey: Self.nicknameDefaultsKey) ?? ""
        if let avatar = defaults.string(forKey: Self.avatarDefaultsKey), !avatar.isEmpty {
            avatarURL = URL(string: avatar)
        }
        vipType = defaults.integer(forKey: Self.vipTypeDefaultsKey)
        refreshPublishedState()
    }

    // MARK: - Session values (read by the API layer)

    var userID: String { userIDValue }
    var token: String { tokenValue }
    var dfid: String { dfidValue }

    /// Device GUID (a random install UUID). Feeds `mid` and the
    /// device-registration request; not an account credential.
    var guid: String { guidValue }

    /// Device `mid`, derived from `guid` (Beans' `calculateMid`).
    var mid: String { midValue }

    /// Full cookie string, as stored in the Keychain. Rebuilt from the
    /// session components whenever any of them changes, so it is never
    /// stale.
    var cookieHeader: String {
        cookieValue.isEmpty
            ? Self.buildCookie(
                userID: userIDValue, token: tokenValue, mid: midValue, dfid: dfidValue,
                vipType: vipType)
            : cookieValue
    }

    /// Headers for KuGou CDN playback (Beans' `PlayerManager` KuGou
    /// branch): KuGou Android UA + KuGou referer, plus the login
    /// cookie when logged in.
    var playbackHeaders: [String: String] {
        var headers = [
            "User-Agent": Self.playbackUserAgent,
            "Referer": "https://www.kugou.com/",
        ]
        let cookie = cookieHeader
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: - Login lifecycle

    /// Makes sure a device identity exists (`guid` + derived `mid`).
    /// Call before any request that needs `mid`/`dfid` headers.
    func prepareDevice() {
        var changed = false
        if guidValue.isEmpty {
            guidValue = UUID().uuidString
            defaults.set(guidValue, forKey: Self.guidDefaultsKey)
            changed = true
        }
        if midValue.isEmpty {
            midValue = Self.calculateMid(seed: guidValue)
            defaults.set(midValue, forKey: Self.midDefaultsKey)
            changed = true
        }
        if changed { rebuildCookie() }
    }

    func saveLogin(userId: String, token: String, nickname: String, avatar: String, vipType: Int) {
        prepareDevice()
        userIDValue = userId.filter(\.isNumber)
        tokenValue = token
        self.nickname = nickname.removingPercentEncoding ?? nickname
        avatarURL = avatar.isEmpty ? nil : URL(string: avatar)
        self.vipType = vipType
        defaults.set(userIDValue, forKey: Self.userIDDefaultsKey)
        defaults.set(self.nickname, forKey: Self.nicknameDefaultsKey)
        defaults.set(avatar, forKey: Self.avatarDefaultsKey)
        defaults.set(vipType, forKey: Self.vipTypeDefaultsKey)
        rebuildCookie()
        refreshPublishedState()
    }

    func saveDeviceDFID(_ dfid: String) {
        guard !dfid.isEmpty, dfidValue != dfid else { return }
        dfidValue = dfid
        defaults.set(dfid, forKey: Self.dfidDefaultsKey)
        rebuildCookie()
    }

    /// Raises the cached VIP type; never lowers it (a downgrade only
    /// comes from a fresh login via `saveLogin`). Used by the API
    /// layer's membership probe.
    func updateVIPType(_ vipType: Int) {
        guard vipType > self.vipType else { return }
        self.vipType = vipType
        defaults.set(vipType, forKey: Self.vipTypeDefaultsKey)
        rebuildCookie()
    }

    /// Clears all four session items (token + cookie from the Keychain,
    /// userid + dfid from UserDefaults) plus the cached profile.
    func logout() {
        tokenValue = ""
        cookieValue = ""
        userIDValue = ""
        dfidValue = ""
        nickname = ""
        avatarURL = nil
        vipType = 0
        Self.keychainDelete(account: Self.tokenAccount)
        Self.keychainDelete(account: Self.cookieAccount)
        defaults.removeObject(forKey: Self.userIDDefaultsKey)
        defaults.removeObject(forKey: Self.dfidDefaultsKey)
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        defaults.removeObject(forKey: Self.avatarDefaultsKey)
        defaults.removeObject(forKey: Self.vipTypeDefaultsKey)
        refreshPublishedState()
    }

    /// Login is dead (HTTP 401/403 or errcode 152): same cleanup as
    /// `logout()` so the next resolve falls back to anonymous search.
    func sessionExpired() {
        Self.log.info("kugou session expired; clearing login")
        logout()
    }

    // MARK: - Private

    private func refreshPublishedState() {
        isLoggedIn = !userIDValue.isEmpty && !tokenValue.isEmpty
    }

    private func rebuildCookie() {
        cookieValue = Self.buildCookie(
            userID: userIDValue, token: tokenValue, mid: midValue, dfid: dfidValue,
            vipType: vipType)
        if cookieValue.isEmpty {
            Self.keychainDelete(account: Self.cookieAccount)
        } else {
            Self.keychainSave(cookieValue, account: Self.cookieAccount)
        }
        if tokenValue.isEmpty {
            Self.keychainDelete(account: Self.tokenAccount)
        } else {
            Self.keychainSave(tokenValue, account: Self.tokenAccount)
        }
    }

    private static func buildCookie(
        userID: String, token: String, mid: String, dfid: String, vipType: Int
    ) -> String {
        var items = [
            ("userid", userID),
            ("token", token),
            ("KUGOU_API_MID", mid),
            ("dfid", dfid),
        ]
        if vipType > 0 {
            items.append(("vipType", "\(vipType)"))
            items.append(("viptype", "\(vipType)"))
        }
        return items.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func calculateMid(seed: String) -> String {
        let hex = md5Hex(seed)
        let prefix = String(hex.prefix(15))
        if let value = UInt64(prefix, radix: 16) { return "\(value)" }
        return hex
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain (token + cookie only)

    private static func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func keychainSave(_ value: String, account: String) {
        let data = Data(value.utf8)
        guard !data.isEmpty else { return }
        keychainDelete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            log.error(
                "kugou keychain save failed account=\(account, privacy: .public) status=\(status, privacy: .public)"
            )
        }
    }

    private static func keychainDelete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
}
