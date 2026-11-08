import Foundation
import os.log

/// Read-only Apple Music API client (`https://api.music.apple.com/v1`).
///
/// What it does — the three read-only groups from the Folia audit
/// (logins.md §8), re-implemented against the REST API instead of Folia's
/// desktop companion window:
/// - Catalog search (songs / albums / playlists) — developer token only.
/// - The user's library playlists — developer token + user token.
/// - The user's library songs, i.e. added / liked tracks — developer
///   token + user token. The Apple Music API has no separate "liked songs"
///   list endpoint: a liked song is a library song, so
///   `GET /v1/me/library/songs` is the source. Folia's liked-song ids came
///   from the companion's `likeSong` / `getLikedSongIds` operations, which
///   have no REST equivalent.
///
/// What it does NOT do — playback, by design:
/// Apple Music audio is DRM-protected and the Apple Music API returns no
/// audio stream URL for any resource (the `playParams` in a response are
/// identifiers for queueing in the system player, not a URL). This client
/// therefore exposes no playback address and no play method. Playing an
/// Apple Music track needs a separate externalPlayback branch that hands
/// the catalog id to the system player (`ApplicationMusicPlayer` /
/// `MPMusicPlayerController`) — that branch is explicitly out of scope
/// here and must not be bolted onto this client.
///
/// Auth model: the developer token is pasted by the user in Settings
/// (`AppleMusicSettings.developerTokenKey`); the user token is read from
/// the Keychain (`AppleMusicKeychain`). Neither token value is ever logged.
/// A 401 means a token was rejected: the caller should call
/// `AppleMusicSession.shared.invalidateUserToken()` and ask the user to
/// sign in again (developer-token expiry is reported separately, as
/// `AppleMusicError.developerTokenExpired`, from its decoded `exp` claim).
final class AppleMusicCatalogClient: Sendable {
    static let shared = AppleMusicCatalogClient()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "apple-music")

    private let urlSession: URLSession
    private let session: AppleMusicSession

    init(urlSession: URLSession? = nil, session: AppleMusicSession = .shared) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            // No login cookies and no shared cache: same posture as
            // `AudioSourceClient` for third-party endpoints.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 15
            self.urlSession = URLSession(configuration: configuration)
        }
        self.session = session
    }

    // MARK: - Catalog

    /// Resource types a catalog search can ask for. The mapped results
    /// only cover songs / albums / playlists; `.artists` may be requested
    /// but its group is not mapped yet (see `AppleMusicSearchResults`).
    enum CatalogSearchType: String, CaseIterable {
        case songs
        case albums
        case playlists
        case artists
    }

    /// Searches the Apple Music catalog. Developer token only — no user
    /// token is sent. `storefront` is a lowercase country code such as
    /// `"us"`; nil defaults to the device region (`Locale.current.region`,
    /// `"us"` when unknown). Note this is the device region, not
    /// necessarily the Apple ID's billing storefront.
    func searchCatalog(
        term: String,
        types: [CatalogSearchType] = [.songs, .albums, .playlists],
        limit: Int = 25,
        offset: Int = 0,
        storefront: String? = nil
    ) async throws -> AppleMusicSearchResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleMusicError.invalidResponse }
        let storefront = (storefront ?? Self.defaultStorefront()).lowercased()
        let response: AppleMusicSearchResponse = try await get(
            path: "/catalog/\(storefront)/search",
            queryItems: [
                URLQueryItem(name: "term", value: trimmed),
                URLQueryItem(name: "types", value: types.map(\.rawValue).joined(separator: ",")),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            requiresUserToken: false
        )
        return AppleMusicSearchResults(
            songs: response.results?.songs?.data ?? [],
            albums: response.results?.albums?.data ?? [],
            playlists: response.results?.playlists?.data ?? []
        )
    }

    // MARK: - Library (user token required)

    /// The user's library playlists (`GET /v1/me/library/playlists`).
    /// Paginated with `limit` / `offset`; `totalCount` comes from the
    /// response `meta` when Apple reports it.
    func libraryPlaylists(
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> AppleMusicLibraryPage<AppleMusicPlaylist> {
        try await get(
            path: "/me/library/playlists",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            requiresUserToken: true
        )
    }

    /// The user's library songs (`GET /v1/me/library/songs`) — the songs
    /// the user added to their library, which is also where liked songs
    /// live. See the type documentation for why there is no separate
    /// "liked" endpoint.
    func librarySongs(
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> AppleMusicLibraryPage<AppleMusicSong> {
        try await get(
            path: "/me/library/songs",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ],
            requiresUserToken: true
        )
    }

    // MARK: - Storefront

    /// Default storefront from the device region, e.g. `"cn"` / `"us"`.
    /// Callers that know the user's Apple ID storefront should pass it
    /// explicitly to `searchCatalog(storefront:)` instead.
    static func defaultStorefront() -> String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    // MARK: - Private

    /// Performs an authenticated GET against the Apple Music API.
    /// The developer token goes in `Authorization: Bearer ...`; library
    /// calls additionally send the user token as `Music-User-Token`.
    private func get<Resource: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        requiresUserToken: Bool
    ) async throws -> Resource {
        let developerToken = session.developerToken
        guard !developerToken.isEmpty else { throw AppleMusicError.missingDeveloperToken }
        guard !session.isDeveloperTokenExpired else { throw AppleMusicError.developerTokenExpired }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1" + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw AppleMusicError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if requiresUserToken {
            guard let userToken = AppleMusicKeychain.loadUserToken(), !userToken.isEmpty else {
                throw AppleMusicError.missingUserToken
            }
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppleMusicError.underlying(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppleMusicError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw AppleMusicError.unauthorized
        case 403:
            throw AppleMusicError.forbidden
        case 429:
            throw AppleMusicError.rateLimited
        default:
            throw AppleMusicError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Resource.self, from: data)
        } catch {
            // Log the failure, never the body or the tokens.
            Self.log.error("Apple Music decode failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AppleMusicError.invalidResponse
        }
    }
}
