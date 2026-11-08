import Foundation

/// A QQ/Kugou artist hit from cross-platform search: just enough to
/// render a card and open `PlatformArtistDetailView`. The detail page
/// loads songs/albums from the platform APIs; there is no NetEase ID
/// behind these, so they never go through `ArtistDetailView`.
struct PlatformArtistSummary: Hashable, Identifiable, Sendable {
    let source: AudioSourceID
    let name: String
    let picURL: URL?
    /// QQ singer mid / Kugou author id; nil for name-only fallback hits.
    let platformID: String?

    var id: String { "\(source.rawValue)|\(platformID ?? "name:\(name)")" }
}

/// A QQ/Kugou album hit from cross-platform search: just enough to
/// render a card and open `PlatformAlbumDetailView`.
struct PlatformAlbumSummary: Hashable, Identifiable, Sendable {
    let source: AudioSourceID
    let name: String
    let artistName: String
    let picURL: URL?
    /// QQ album mid / Kugou album id; nil for name-only fallback hits.
    let platformID: String?

    var id: String { "\(source.rawValue)|\(platformID ?? "name:\(artistName)|\(name)")" }
}
