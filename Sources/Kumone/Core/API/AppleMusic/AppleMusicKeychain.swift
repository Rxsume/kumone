import Foundation
import Security

/// Keychain storage for the Apple Music user token.
///
/// Only the user token lives here. The developer token is a user-pasted
/// setting (see `AppleMusicSettings.developerTokenKey`) and is not stored
/// by this type. Never put either token in UserDefaults beyond that one
/// settings key, in a file, or in a log line.
///
/// Mirrors the Keychain conventions already used by `LoginKeyStore.keychain`:
/// generic-password item, not synchronizable, accessible after first unlock
/// on this device only.
enum AppleMusicKeychain {
    private static let service = "sb.moe.kumone.apple-music"
    private static let userTokenAccount = "apple-music-user-token"

    /// Stores (or replaces) the user token. Throws on a Keychain failure.
    static func saveUserToken(_ token: String) throws {
        let tokenData = Data(token.utf8)
        guard !tokenData.isEmpty else { return }
        // One token at a time: a replaced token is useless and must not linger.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userTokenAccount,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userTokenAccount,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: tokenData,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Returns the stored user token, or nil when there is none.
    static func loadUserToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userTokenAccount,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              !data.isEmpty,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    /// Deletes the stored user token. Used by sign-out and by the
    /// "token rejected (401) → re-sign-in" path. Never throws: a missing
    /// item is already the desired end state.
    static func deleteUserToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userTokenAccount,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
}
