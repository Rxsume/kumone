import Foundation

/// Apple Music API resource models (catalog + library) and the shared error type.
///
/// Data layer only: these types describe what `api.music.apple.com/v1` returns.
/// They deliberately carry no audio URL — the Apple Music API never returns one.
/// Apple Music audio is DRM-protected; playback needs a separate externalPlayback
/// branch (system player), which this module does not provide.

enum AppleMusicError: LocalizedError {
    case missingDeveloperToken
    case missingUserToken
    case notAuthorized
    case developerTokenExpired
    case unauthorized
    case forbidden
    case rateLimited
    case httpStatus(Int)
    case invalidResponse
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .missingDeveloperToken:
            return String(localized: "未设置 Apple Music Developer Token，请先在设置里粘贴")
        case .missingUserToken:
            return String(localized: "Apple Music 未登录，请先登录")
        case .notAuthorized:
            return String(localized: "未获得 Apple Music 访问权限，请在系统设置里允许")
        case .developerTokenExpired:
            return String(localized: "Apple Music Developer Token 已过期，请重新签发并粘贴")
        case .unauthorized:
            return String(localized: "Apple Music 登录已失效，请重新登录")
        case .forbidden:
            return String(localized: "Apple Music 拒绝了该请求")
        case .rateLimited:
            return String(localized: "Apple Music 请求过于频繁，请稍后再试")
        case .httpStatus(let status):
            return String(localized: "网络错误 (\(status))")
        case .invalidResponse:
            return String(localized: "数据加载失败，请稍后重试")
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

/// Artwork whose `url` is a template containing `{w}` and `{h}` placeholders.
struct AppleMusicArtwork: Decodable, Hashable {
    let width: Int?
    let height: Int?
    let url: String?

    func url(width: Int, height: Int) -> URL? {
        guard let template = url else { return nil }
        let expanded = template
            .replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
        return URL(string: expanded)
    }
}

/// Playback parameters as returned by the API. These are identifiers for
/// queueing a resource in the system player (future externalPlayback branch),
/// not a stream URL — there is no audio URL anywhere in the Apple Music API.
struct AppleMusicPlayParams: Decodable, Hashable {
    /// Catalog id for a catalog resource; library id for a library resource.
    let id: String?
    let kind: String?
    /// The catalog twin of a library resource, when Apple matched one.
    let catalogId: String?
}

/// Playlist / album description object (`{ "standard": ..., "short": ... }`).
struct AppleMusicDescription: Decodable, Hashable {
    let standard: String?
    let short: String?
}

struct AppleMusicSong: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let href: String?
    let attributes: Attributes?

    struct Attributes: Decodable, Hashable {
        let name: String
        let artistName: String?
        let albumName: String?
        let durationInMillis: Int?
        let artwork: AppleMusicArtwork?
        let trackNumber: Int?
        let discNumber: Int?
        let genreNames: [String]?
        let releaseDate: String?
        let isrc: String?
        let composerName: String?
        /// Apple Music web share URL. Not an audio URL.
        let url: String?
        let playParams: AppleMusicPlayParams?
    }

    var name: String { attributes?.name ?? "" }
    var artistName: String? { attributes?.artistName }
    var albumName: String? { attributes?.albumName }
    var duration: TimeInterval? {
        guard let millis = attributes?.durationInMillis else { return nil }
        return TimeInterval(millis) / 1000
    }

    /// `library-songs` vs catalog `songs`.
    var isLibraryItem: Bool { type.hasPrefix("library-") }

    /// The catalog id, when one exists. Catalog songs carry it as their own
    /// id; library songs carry it in `playParams.catalogId`. Nil means the
    /// row has no catalog twin (e.g. an unmatched upload).
    var catalogID: String? {
        if isLibraryItem { return attributes?.playParams?.catalogId }
        return id
    }

    func artworkURL(width: Int, height: Int) -> URL? {
        attributes?.artwork?.url(width: width, height: height)
    }
}

struct AppleMusicAlbum: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let href: String?
    let attributes: Attributes?

    struct Attributes: Decodable, Hashable {
        let name: String
        let artistName: String?
        let artwork: AppleMusicArtwork?
        let releaseDate: String?
        let trackCount: Int?
        let genreNames: [String]?
        /// Apple Music web share URL. Not an audio URL.
        let url: String?
    }

    var name: String { attributes?.name ?? "" }
    var artistName: String? { attributes?.artistName }

    func artworkURL(width: Int, height: Int) -> URL? {
        attributes?.artwork?.url(width: width, height: height)
    }
}

struct AppleMusicPlaylist: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let href: String?
    let attributes: Attributes?

    struct Attributes: Decodable, Hashable {
        let name: String
        let descriptionText: AppleMusicDescription?
        let artwork: AppleMusicArtwork?
        let curatorName: String?
        let canEdit: Bool?
        let playParams: AppleMusicPlayParams?
        /// Apple Music web share URL. Not an audio URL.
        let url: String?

        enum CodingKeys: String, CodingKey {
            case name, artwork, curatorName, canEdit, playParams, url
            case descriptionText = "description"
        }
    }

    var name: String { attributes?.name ?? "" }
    var summary: String? { attributes?.descriptionText?.standard }
    var isLibraryItem: Bool { type.hasPrefix("library-") }

    func artworkURL(width: Int, height: Int) -> URL? {
        attributes?.artwork?.url(width: width, height: height)
    }
}

/// One group of a catalog search response (`results.songs`, etc.).
struct AppleMusicResultGroup<Resource: Decodable>: Decodable {
    let data: [Resource]
    let href: String?
    let next: String?
}

/// Raw catalog search response envelope (`{ "results": { ... } }`).
struct AppleMusicSearchResponse: Decodable {
    let results: Results?

    struct Results: Decodable {
        let songs: AppleMusicResultGroup<AppleMusicSong>?
        let albums: AppleMusicResultGroup<AppleMusicAlbum>?
        let playlists: AppleMusicResultGroup<AppleMusicPlaylist>?
    }
}

/// Mapped catalog search results: only songs / albums / playlists.
/// (The API can also return artists; this client does not map that group yet.)
struct AppleMusicSearchResults {
    var songs: [AppleMusicSong] = []
    var albums: [AppleMusicAlbum] = []
    var playlists: [AppleMusicPlaylist] = []
}

/// One page of a library listing (`/v1/me/library/...`).
/// `next` is a relative URL (e.g. `/v1/me/library/playlists?offset=25`)
/// that a future store can follow; the client methods take `offset` instead.
struct AppleMusicLibraryPage<Resource: Decodable>: Decodable {
    let data: [Resource]
    let meta: Meta?
    let next: String?

    struct Meta: Decodable {
        let total: Int?
    }

    var totalCount: Int? { meta?.total }
}
