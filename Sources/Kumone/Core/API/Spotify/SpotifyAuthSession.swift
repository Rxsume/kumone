import AuthenticationServices
import CryptoKit
import Foundation
import os.log
import Security

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Errors from the Spotify login flow. Messages are user-facing (the app's
/// default language is zh-Hans). Folia's failure words map here as:
/// `access-denied` -> `.accessDenied`, `unreachable` / `no-answer` ->
/// `.network`, `account-not-read` -> `.profileNotRead`; Folia's
/// `cannot-listen` has no iOS equivalent because the callback is a custom
/// URL scheme, not a localhost listener.
enum SpotifyAuthError: LocalizedError {
    case notConfigured
    case invalidRedirectURI
    case loginAlreadyInProgress
    case userCancelled
    case accessDenied
    case invalidCallback
    case tokenExchangeFailed(status: Int)
    case tokenResponseInvalid
    case refreshFailedRequiresLogin
    case profileNotRead
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "需在 Spotify Developer Dashboard 注册应用后填入 Client ID"
        case .invalidRedirectURI:
            return "Redirect URI 无效：请填入应用在 Spotify Developer Dashboard 登记的自定义 scheme 回调地址，例如 golia-spotify://callback"
        case .loginAlreadyInProgress:
            return "正在登录 Spotify，请稍候"
        case .userCancelled:
            return "已取消 Spotify 登录"
        case .accessDenied:
            return "已在 Spotify 页面拒绝授权"
        case .invalidCallback:
            return "Spotify 回调无效（state 不匹配或缺少授权码）"
        case .tokenExchangeFailed(let status):
            return "Spotify 换取 token 失败（HTTP \(status)）"
        case .tokenResponseInvalid:
            return "Spotify 返回的 token 缺少 refresh_token"
        case .refreshFailedRequiresLogin:
            return "Spotify 登录已过期，请重新登录"
        case .profileNotRead:
            return "已授权，但读取 Spotify 账号失败"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        }
    }
}

/// Spotify OAuth login session: authorization-code flow with PKCE (S256),
/// via `ASWebAuthenticationSession`.
///
/// Folia did this in the desktop main process (`electron/spotify/signIn.cjs`,
/// not in the sparse checkout): it opened the authorize page in a browser
/// and listened on localhost for the callback. On iOS the same flow is
/// `ASWebAuthenticationSession` with a custom URL scheme callback — no
/// localhost listener, no port to fail (`cannot-listen` cannot happen).
///
/// - Tokens never leave this class except as a Bearer header built by
///   `SpotifyWebAPIClient` via `validAccessToken()` (same module,
///   internal). There is no public accessor for any token value, and
///   tokens are never logged.
/// - Tokens persist only in the Keychain (`SpotifyKeychainStore`); the
///   profile in `currentUser` is non-sensitive display data.
/// - No playback: Spotify audio needs librespot, which has no iOS target
///   (see `SpotifyWebAPIClient`); login only unlocks browsing/search.
@MainActor
final class SpotifyAuthSession: ObservableObject {
    static let shared = SpotifyAuthSession()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isLoggingIn = false
    /// Profile read from `/v1/me` right after login; nil when logged out.
    @Published private(set) var currentUser: SpotifyUserProfile?

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "spotify")
    private static let presentationProvider = SpotifyAuthPresentationContextProvider()
    private static let tokenSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private var tokens: SpotifyStoredTokens?
    private var refreshTask: Task<String, Error>?

    init() {
        tokens = SpotifyKeychainStore.load()
        isLoggedIn = tokens?.refreshToken.isEmpty == false
    }

    /// Starts the Spotify OAuth login: opens the authorize page in
    /// `ASWebAuthenticationSession`, exchanges the returned code for tokens
    /// (PKCE), stores them in the Keychain, and reads the profile to
    /// confirm the login (Folia's `account-not-read` case). Throws
    /// `SpotifyAuthError` on any failure; a cancelled sheet throws
    /// `.userCancelled`.
    ///
    /// The caller (LoginSheet) must check
    /// `SpotifyConfiguration().canLogIn` first and keep the entry disabled
    /// otherwise.
    func beginLogin() async throws -> SpotifyUserProfile {
        let configuration = SpotifyConfiguration()
        guard configuration.isConfigured else { throw SpotifyAuthError.notConfigured }
        guard let callbackScheme = configuration.callbackScheme else { throw SpotifyAuthError.invalidRedirectURI }
        guard !isLoggingIn else { throw SpotifyAuthError.loginAlreadyInProgress }
        isLoggingIn = true
        defer { isLoggingIn = false }

        // PKCE: a fresh verifier per attempt; only the S256 challenge
        // leaves the app. `state` guards the callback against CSRF.
        let state = Self.randomBase64URL(byteCount: 32)
        let verifier = Self.randomBase64URL(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        var components = URLComponents(url: SpotifyConfiguration.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: SpotifyConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        guard let authorizeURL = components.url else { throw SpotifyAuthError.invalidRedirectURI }

        let code = try await Self.presentAuthorization(url: authorizeURL, callbackScheme: callbackScheme, state: state)
        let newTokens = try await Self.exchangeCodeForTokens(code: code, verifier: verifier, configuration: configuration)
        try SpotifyKeychainStore.save(newTokens)
        tokens = newTokens
        let profile = try await fetchProfile(accessToken: newTokens.accessToken)
        currentUser = profile
        isLoggedIn = true
        Self.log.info("Spotify login confirmed")
        return profile
    }

    /// Returns a usable access token, refreshing it first when expired.
    /// Internal: only `SpotifyWebAPIClient` calls this, so that no token
    /// value is ever exposed to UI or other modules.
    func validAccessToken() async throws -> String {
        if let tokens, !tokens.isAccessTokenExpired { return tokens.accessToken }
        return try await refreshAccessToken()
    }

    /// Exchanges the stored refresh token for a new access token (and
    /// stores a rotated refresh token when Spotify returns one).
    /// Concurrent callers share the one in-flight refresh. Throws
    /// `.refreshFailedRequiresLogin` when the refresh token is rejected —
    /// the session is cleared and the user must log in again.
    func refreshAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw SpotifyAuthError.refreshFailedRequiresLogin }
            guard let stored = self.tokens, !stored.refreshToken.isEmpty else {
                throw SpotifyAuthError.refreshFailedRequiresLogin
            }
            let configuration = SpotifyConfiguration()
            let response: SpotifyTokenResponse
            do {
                response = try await Self.postTokenForm(body: [
                    "grant_type": "refresh_token",
                    "refresh_token": stored.refreshToken,
                    "client_id": configuration.clientID,
                ])
            } catch let error as SpotifyAuthError {
                // A 400 on refresh is (almost always) `invalid_grant`: the
                // refresh token is dead. Clear the session so the UI falls
                // back to "log in again" instead of retrying forever.
                if case .tokenExchangeFailed(let status) = error, status == 400 {
                    self.clearSession()
                    throw SpotifyAuthError.refreshFailedRequiresLogin
                }
                throw error
            }
            var updated = stored
            updated.accessToken = response.access_token
            updated.tokenType = response.token_type
            updated.scope = response.scope ?? stored.scope
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in))
            if let rotated = response.refresh_token, !rotated.isEmpty {
                updated.refreshToken = rotated
            }
            try SpotifyKeychainStore.save(updated)
            self.tokens = updated
            return updated.accessToken
        }
        refreshTask = task
        do {
            let token = try await task.value
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }

    /// Logs out: clears the Keychain tokens and the in-memory session.
    /// No server call: Spotify's Web API has no token-revocation endpoint
    /// for this flow, so local deletion is the whole logout (the tokens
    /// simply stop being used; the user can also revoke the app in their
    /// Spotify account settings).
    func logout() {
        clearSession()
        Self.log.info("Spotify logout: tokens cleared")
    }

    private func clearSession() {
        tokens = nil
        refreshTask = nil
        currentUser = nil
        isLoggedIn = false
        SpotifyKeychainStore.delete()
    }

    // MARK: - Authorization page

    /// Presents the Spotify authorize page and returns the authorization
    /// code from the callback URL. The `ASWebAuthenticationSession` is
    /// kept alive by a box until its completion handler runs; the box is
    /// released there, which breaks the retain cycle.
    private static func presentAuthorization(url: URL, callbackScheme: String, state: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            final class SessionBox { var session: ASWebAuthenticationSession? }
            let box = SessionBox()
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                defer { box.session = nil }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.userCancelled)
                    return
                }
                if let error = error as? URLError {
                    continuation.resume(throwing: SpotifyAuthError.network(error))
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                    continuation.resume(throwing: SpotifyAuthError.invalidCallback)
                    return
                }
                let query = components.queryItems ?? []
                if query.first(where: { $0.name == "error" })?.value == "access_denied" {
                    continuation.resume(throwing: SpotifyAuthError.accessDenied)
                    return
                }
                guard query.first(where: { $0.name == "state" })?.value == state,
                      let code = query.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty else {
                    continuation.resume(throwing: SpotifyAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            box.session = authSession
            authSession.presentationContextProvider = presentationProvider
            // Not ephemeral: the user is usually already signed in to
            // Spotify in Safari, and sharing that cookie jar lets them
            // approve without typing a password — the same behaviour as
            // Folia opening the browser where the user is signed in.
            authSession.prefersEphemeralWebBrowserSession = false
            authSession.start()
        }
    }

    // MARK: - Token endpoint

    /// `POST https://accounts.spotify.com/api/token` with a
    /// `application/x-www-form-urlencoded` body. This is a public client
    /// (PKCE, no client secret), so the token endpoint takes
    /// `client_id` in the body. A dedicated form POST is used instead of
    /// `AudioSourceClient.postJSON`: that client only posts JSON and its
    /// calls are attributed to an `AudioSourceID`, neither of which fits
    /// an auth endpoint.
    private static func postTokenForm(body: [String: String]) async throws -> SpotifyTokenResponse {
        var request = URLRequest(url: SpotifyConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = body.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await tokenSession.data(for: request)
        } catch let error as URLError {
            throw SpotifyAuthError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenExchangeFailed(status: -1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            Self.log.error("Spotify token endpoint status=\(httpResponse.statusCode, privacy: .public)")
            throw SpotifyAuthError.tokenExchangeFailed(status: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        } catch {
            throw SpotifyAuthError.tokenExchangeFailed(status: httpResponse.statusCode)
        }
    }

    private static func exchangeCodeForTokens(code: String, verifier: String, configuration: SpotifyConfiguration) async throws -> SpotifyStoredTokens {
        let response = try await postTokenForm(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
        ])
        guard let refreshToken = response.refresh_token, !refreshToken.isEmpty else {
            throw SpotifyAuthError.tokenResponseInvalid
        }
        return SpotifyStoredTokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            tokenType: response.token_type,
            scope: response.scope ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in))
        )
    }

    /// Reads `/v1/me` with a fresh access token to confirm the login.
    /// Any failure here is Folia's `account-not-read`: the authorization
    /// went through, but the account could not be read, so the login does
    /// not count as confirmed.
    private func fetchProfile(accessToken: String) async throws -> SpotifyUserProfile {
        var request = URLRequest(url: SpotifyConfiguration.webAPIBaseURL.appendingPathComponent("me"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.tokenSession.data(for: request)
        } catch let error as URLError {
            throw SpotifyAuthError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SpotifyAuthError.profileNotRead
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SpotifyUserProfile.self, from: data)
        } catch {
            throw SpotifyAuthError.profileNotRead
        }
    }

    // MARK: - PKCE

    /// `byteCount` random bytes, base64url-encoded without padding. 64
    /// bytes -> 86 characters, inside PKCE's 43–128 range.
    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// S256 code challenge: base64url(SHA256(verifier)).
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

/// Supplies the presentation anchor for `ASWebAuthenticationSession`.
private final class SpotifyAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
#else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
#endif
    }
}

/// Token endpoint response. Property names are the wire names
/// (`access_token`, …), so this decodes with the default key strategy.
private struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let scope: String?
    let expires_in: Int
    let refresh_token: String?
}

private extension Data {
    /// Base64url without padding, as PKCE requires.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
