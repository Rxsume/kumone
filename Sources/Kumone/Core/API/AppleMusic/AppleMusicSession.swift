import Foundation
import MusicKit
import StoreKit
import os.log

/// UserDefaults key for the pasted MusicKit developer token.
///
/// The key is defined here, next to its only reader, so this module stays
/// self-contained: the wiring PR adds a `SettingsManager` property backed by
/// this same key string (see INTEGRATION-applemusic.md) instead of this file
/// reaching into `SettingsManager`. Default is empty — no token is bundled
/// with the app, and no placeholder / fake token is ever written.
/// The developer token is a JWT the user signs with their own Apple
/// Developer MusicKit key; the `.p8` private key must never enter the app.
enum AppleMusicSettings {
    static let developerTokenKey = "settings.appleMusicDeveloperToken"

    /// The pasted developer token, trimmed. Empty when not configured.
    static var developerToken: String {
        get {
            UserDefaults.standard.string(forKey: developerTokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: developerTokenKey) }
    }
}

/// Apple Music sign-in state, via native MusicKit authorization.
///
/// What this session is:
/// - `MusicAuthorization.request()` asks the user for Apple Music access
///   (system prompt; requires `NSAppleMusicUsageDescription` in Info.plist).
/// - The raw user token is obtained with StoreKit's
///   `SKCloudServiceController.requestUserToken(forDeveloperToken:)` and
///   stored in the Keychain (`AppleMusicKeychain`). It is never written to
///   UserDefaults, a file, or a log line.
///
/// Why StoreKit and not a `MusicUserToken` type: Apple's current
/// documentation ("User Authentication for MusicKit", checked 2026-11-08)
/// says MusicKit on Apple platforms manages the user token automatically —
/// `MusicDataRequest` decorates requests with it — and exposes no public
/// Swift API that hands the raw user-token string to the app. The only
/// public API that returns the raw string is the long-standing StoreKit
/// one used here, which is what makes Keychain caching and plain
/// URLSession requests possible. If the wiring later switches library calls
/// to `MusicDataRequest`, the Keychain user token becomes unnecessary and
/// this session can drop the StoreKit half.
///
/// What this session is not:
/// - It does not sign developer tokens and never sees the `.p8` private key.
/// - Sign-out only deletes the Keychain user token. It does not revoke the
///   system-level MusicKit authorization (the user revokes that in iOS
///   Settings → Privacy & Security) and does not clear the pasted developer
///   token, which is a setting the user manages.
/// - User tokens have no locally readable expiry: unlike the developer JWT,
///   their lifetime is not observable until the API answers 401. Callers
///   must treat `AppleMusicError.unauthorized` as "clear the stored user
///   token and ask the user to sign in again" (see `invalidateUserToken()`).
final class AppleMusicSession: Sendable {
    static let shared = AppleMusicSession()

    private init() {}

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "apple-music")

    // MARK: - State (all derived; nothing mutable is cached here)

    /// The current system authorization status. `.notDetermined` until the
    /// user has answered the prompt once.
    var authorizationStatus: MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    /// The pasted developer token (empty when not configured).
    var developerToken: String { AppleMusicSettings.developerToken }

    var hasDeveloperToken: Bool { !developerToken.isEmpty }

    var hasUserToken: Bool { AppleMusicKeychain.loadUserToken() != nil }

    /// Expiry decoded from the developer JWT's `exp` claim, or nil when the
    /// token is absent or its payload cannot be parsed. This only reads the
    /// claim; it does not verify the signature.
    var developerTokenExpiry: Date? { Self.expiry(of: developerToken) }

    /// True only when an expiry could be decoded and it has passed.
    /// An undecodable token is reported as "unknown", not as expired.
    var isDeveloperTokenExpired: Bool {
        guard let expiry = developerTokenExpiry else { return false }
        return expiry <= Date()
    }

    /// Signed in means: system-authorized, developer token present and
    /// unexpired, and a user token stored in the Keychain.
    var isSignedIn: Bool {
        authorizationStatus == .authorized
            && hasDeveloperToken
            && !isDeveloperTokenExpired
            && hasUserToken
    }

    /// The single reason sign-in is currently blocked, for greying out the
    /// login entry and showing the right hint. Nil when signed in.
    enum LoginBlocker: Equatable {
        case missingDeveloperToken
        case notAuthorized(MusicAuthorization.Status)
        case missingUserToken
        case developerTokenExpired
    }

    var loginBlocker: LoginBlocker? {
        if !hasDeveloperToken { return .missingDeveloperToken }
        if isDeveloperTokenExpired { return .developerTokenExpired }
        if authorizationStatus != .authorized { return .notAuthorized(authorizationStatus) }
        if !hasUserToken { return .missingUserToken }
        return nil
    }

    // MARK: - Sign-in / sign-out

    /// Requests system authorization, then fetches a user token and stores
    /// it in the Keychain. Throws `AppleMusicError` on any failure.
    /// No QR code, no web view, no companion window: unlike Folia's desktop
    /// flow, iOS signs in natively with the user's Apple ID.
    func signIn() async throws {
        guard hasDeveloperToken else { throw AppleMusicError.missingDeveloperToken }
        let status = await MusicAuthorization.request()
        guard status == .authorized else { throw AppleMusicError.notAuthorized }
        let userToken = try await requestUserToken()
        try AppleMusicKeychain.saveUserToken(userToken)
        Self.log.info("Apple Music signed in")
    }

    /// Re-runs the user-token request and replaces the stored token.
    /// User tokens cannot be refreshed; this is a fresh authorization round.
    func refreshUserToken() async throws {
        guard hasDeveloperToken else { throw AppleMusicError.missingDeveloperToken }
        guard authorizationStatus == .authorized else { throw AppleMusicError.notAuthorized }
        let userToken = try await requestUserToken()
        try AppleMusicKeychain.saveUserToken(userToken)
        Self.log.info("Apple Music user token refreshed")
    }

    /// Signs out: deletes the Keychain user token only. The pasted developer
    /// token and the system authorization are left untouched (see the type
    /// documentation above for why).
    func signOut() {
        AppleMusicKeychain.deleteUserToken()
        Self.log.info("Apple Music signed out")
    }

    /// Clears the stored user token after the API rejected it (401), so the
    /// next sign-in starts clean instead of retrying a dead token.
    func invalidateUserToken() {
        AppleMusicKeychain.deleteUserToken()
        Self.log.info("Apple Music user token invalidated after 401")
    }

    // MARK: - Private

    /// Asks StoreKit for the raw user-token string for the pasted developer
    /// token. The token value is never logged.
    private func requestUserToken() async throws -> String {
        let developerToken = AppleMusicSettings.developerToken
        return try await withCheckedThrowingContinuation { continuation in
            SKCloudServiceController().requestUserToken(forDeveloperToken: developerToken) { token, error in
                if let error {
                    continuation.resume(throwing: AppleMusicError.underlying(error))
                    return
                }
                guard let token, !token.isEmpty else {
                    continuation.resume(throwing: AppleMusicError.missingUserToken)
                    return
                }
                continuation.resume(returning: token)
            }
        }
    }

    /// Reads the `exp` claim (seconds since epoch) from a JWT's payload.
    /// Returns nil for a non-JWT string or a payload without `exp`.
    /// Signature verification is deliberately out of scope: expiry display
    /// only needs the claim, and the server is the authority on validity.
    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
