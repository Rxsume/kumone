import Foundation

/// Decodable models for the Spotify Web API (`api.spotify.com/v1`) responses
/// used by `SpotifyWebAPIClient`. Decoded with
/// `keyDecodingStrategy = .convertFromSnakeCase`.
///
/// No playable audio: the Web API returns no full-track audio URL, and the
/// `preview_url` field is deliberately not decoded here — it is only a
/// 30-second preview, and nothing in this client may be fed to the player
/// as a track. Full Spotify audio needs librespot, which has no iOS target
/// (see `SpotifyWebAPIClient`).
struct SpotifyImage: Decodable, Hashable {
    let url: String
    let width: Int?
    let height: Int?
}

extension Array where Element == SpotifyImage {
    /// URL of the largest image, for covers and avatars.
    var largestImageURL: URL? {
        self.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })
            .flatMap { URL(string: $0.url) }
    }
}

struct SpotifyArtist: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
}

struct SpotifyAlbum: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let albumType: String?
    let artists: [SpotifyArtist]
    let images: [SpotifyImage]
    let releaseDate: String?
    let totalTracks: Int?
    let uri: String
}

struct SpotifyTrack: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let durationMs: Int
    let explicit: Bool
    let popularity: Int?
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
    let uri: String
}

struct SpotifyUserProfile: Decodable, Hashable {
    let id: String
    let displayName: String?
    let email: String?
    let country: String?
    let product: String?
    let images: [SpotifyImage]?
    let uri: String
    let href: String

    /// Display name for account rows; falls back to the Spotify user id.
    var nickname: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }
}

struct SpotifyPlaylistOwner: Decodable, Hashable {
    let id: String
    let displayName: String?
}

struct SpotifyPlaylistTrackRef: Decodable, Hashable {
    let total: Int
    let href: String?
}

struct SpotifyPlaylist: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let owner: SpotifyPlaylistOwner
    let images: [SpotifyImage]
    let tracks: SpotifyPlaylistTrackRef
    let uri: String
}

/// One row of `GET /v1/me/tracks`. `track` is nil when Spotify withdrew
/// the track; callers must skip such rows instead of showing them.
struct SpotifySavedTrack: Decodable, Hashable {
    let addedAt: String
    let track: SpotifyTrack?
}

/// Spotify's offset paging envelope, shared by search, playlists and
/// liked tracks.
struct SpotifyPaging<Item: Decodable>: Decodable {
    let href: String?
    let items: [Item]
    let limit: Int
    let offset: Int
    let total: Int
    let next: String?
    let previous: String?
}

/// `GET /v1/search` response. Only the types asked for are present.
struct SpotifySearchResponse: Decodable {
    let tracks: SpotifyPaging<SpotifyTrack>?
    let albums: SpotifyPaging<SpotifyAlbum>?
    let playlists: SpotifyPaging<SpotifyPlaylist>?
}
