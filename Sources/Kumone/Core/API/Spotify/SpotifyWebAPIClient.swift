import Foundation
import os.log

/// Errors from the read-only Spotify Web API client.
enum SpotifyAPIError: LocalizedError {
    case notAuthenticated
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse
    case transport(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Spotify 未登录或登录已过期，请重新登录"
        case .httpStatus(let status):
            return "Spotify 请求失败（HTTP \(status)）"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Spotify 请求过于频繁，请 \(Int(retryAfter)) 秒后再试"
            }
            return "Spotify 请求过于频繁，请稍后再试"
        case .invalidResponse:
            return "Spotify 返回了无法识别的数据"
        case .transport(let code):
            return "网络错误（\(code.rawValue)）"
        }
    }
}

/// Search kinds for `SpotifyWebAPIClient.search`. Only tracks, albums and
/// playlists — the same three the task asks for.
enum SpotifySearchType: String, CaseIterable, Hashable {
    case track
    case album
    case playlist
}

/// Read-only client for the public Spotify Web API (`api.spotify.com/v1`).
///
/// This is deliberately **not** Folia's Spotify path: Folia talked to
/// Spotify's internal query services (`api-partner.spotify.com`,
/// `spclient.wg.spotify.com`) with unpublished persisted-query hashes,
/// which the public Web API answers with 429 — and its audio came from
/// librespot. This client uses only the documented public Web API, so its
/// search paging is plain offset/limit (unlike Folia's dedup walk), and
/// it offers no playback at all:
///
/// **No playback, by design.** Spotify audio needs librespot (a native
/// module with win32-x64 / darwin-arm64 / linux builds and no iOS
/// target), and the public Web API returns no full-track audio URL.
/// Nothing this client returns may be fed to the player as a track.
/// The 30-second `preview_url` is not even decoded (see
/// `SpotifyModels.swift`).
///
/// Why this client has its own URLSession instead of reusing
/// `AudioSourceClient`: every `AudioSourceClient` entry point takes an
/// `AudioSourceID` (its logging is attributed per audio source), and
/// there is no Spotify audio-source case — adding one would mean editing
/// the shared `AudioSourceProvider.swift` and mislabelling a login-only
/// provider as an audio source. The session configuration below mirrors
/// `AudioSourceClient` exactly (ephemeral, no cookies, 10 s timeout,
/// 2xx only, same `sb.moe.kumone` logging). If a `.spotify` case is ever
/// added to `AudioSourceID`, the request path here can be swapped for
/// `AudioSourceClient.shared` with no other change.
struct SpotifyWebAPIClient {
    static let shared = SpotifyWebAPIClient()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "spotify")
    private let session: URLSession

    /// `session` is injectable for tests (e.g. a `URLProtocol` stub);
    /// production use takes the default ephemeral session.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    /// Searches tracks, albums and/or playlists (`GET /v1/search`).
    /// `types` defaults to all three. Spotify pages by offset/limit
    /// (max 50); `total` in each returned page is Spotify's count.
    /// An empty query returns an empty response without a request.
    func search(
        query: String,
        types: Set<SpotifySearchType> = [.track, .album, .playlist],
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> SpotifySearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpotifySearchResponse(tracks: nil, albums: nil, playlists: nil)
        }
        let queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: types.sorted(by: { $0.rawValue < $1.rawValue }).map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(clampedLimit(limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]
        return try await get(path: "search", queryItems: queryItems)
    }

    /// The user's playlists, own and followed (`GET /v1/me/playlists`).
    /// The liked-songs pseudo-playlist is not part of this answer; use
    /// `likedTracks` for it (Folia prepended it as a card — the UI layer
    /// can do the same with the liked count).
    func userPlaylists(limit: Int = 20, offset: Int = 0) async throws -> SpotifyPaging<SpotifyPlaylist> {
        try await get(path: "me/playlists", queryItems: pageQueryItems(limit: limit, offset: offset))
    }

    /// The user's liked tracks (`GET /v1/me/tracks`). Rows whose `track`
    /// is nil (withdrawn tracks) are included as-is; callers must skip
    /// them instead of showing them.
    func likedTracks(limit: Int = 20, offset: Int = 0) async throws -> SpotifyPaging<SpotifySavedTrack> {
        try await get(path: "me/tracks", queryItems: pageQueryItems(limit: limit, offset: offset))
    }

    /// The logged-in user's profile (`GET /v1/me`).
    func userProfile() async throws -> SpotifyUserProfile {
        try await get(path: "me", queryItems: [])
    }

    // MARK: - Request plumbing

    private func pageQueryItems(limit: Int, offset: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(clampedLimit(limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]
    }

    /// Spotify's per-page maximum is 50.
    private func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 50)
    }

    /// One authenticated GET. On a 401 the access token is refreshed once
    /// and the request retried; a second 401 (or a rejected refresh
    /// token) surfaces as `.notAuthenticated`.
    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        try await get(path: path, queryItems: queryItems, allowRetry: true)
    }

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem], allowRetry: Bool) async throws -> T {
        guard await SpotifyAuthSession.shared.isLoggedIn else {
            throw SpotifyAPIError.notAuthenticated
        }
        let token: String
        do {
            token = try await SpotifyAuthSession.shared.validAccessToken()
        } catch {
            throw SpotifyAPIError.notAuthenticated
        }
        var components = URLComponents(
            url: SpotifyConfiguration.webAPIBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw SpotifyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SpotifyAPIError.transport(error.code)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401 where allowRetry:
            do {
                _ = try await SpotifyAuthSession.shared.refreshAccessToken()
            } catch {
                throw SpotifyAPIError.notAuthenticated
            }
            return try await get(path: path, queryItems: queryItems, allowRetry: false)
        case 401:
            throw SpotifyAPIError.notAuthenticated
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw SpotifyAPIError.rateLimited(retryAfter: retryAfter)
        default:
            Self.log.error("Spotify API \(path, privacy: .public) status=\(httpResponse.statusCode, privacy: .public)")
            throw SpotifyAPIError.httpStatus(httpResponse.statusCode)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("Spotify API \(path, privacy: .public) decode failed")
            throw SpotifyAPIError.invalidResponse
        }
    }
}
