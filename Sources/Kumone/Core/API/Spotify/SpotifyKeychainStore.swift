import Foundation
import Security

/// Tokens stored for one Spotify login, persisted as a single Keychain item.
///
/// Access and refresh tokens never go to UserDefaults or any plaintext file
/// (unlike the NetEase `cookies.json`); they live only here and in
/// `SpotifyAuthSession` memory. The item is device-only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and never syncs
/// (`kSecAttrSynchronizable: false`), mirroring `LoginKeyStore.keychain`.
struct SpotifyStoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var scope: String
    var expiresAt: Date

    /// True when the access token should no longer be used (60 s early, so
    /// a token expiring mid-request still gets refreshed first).
    var isAccessTokenExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Keychain backing for `SpotifyStoredTokens`. One generic-password item;
/// a new login replaces it, logout deletes it.
enum SpotifyKeychainStore {
    private static let service = "sb.moe.kumone.spotify-tokens"
    private static let account = "spotify-tokens"

    static func load() -> SpotifyStoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyStoredTokens.self, from: data)
    }

    static func save(_ tokens: SpotifyStoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
}
