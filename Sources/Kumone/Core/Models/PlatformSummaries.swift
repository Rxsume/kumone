import Foundation

/// The home-page platform: which service's feed the home page shows.
/// NetEase is the default and preserves today's behaviour; QQ/Kugou
/// feeds are anonymous (their home endpoints need no login).
enum HomePlatform: String, CaseIterable, Identifiable {
    case netease
    case qqmusic
    case kugou
    /// Bilibili video home (full CiliCili port, phase 1: entry point
    /// only — the video feed lands in phase 3). No audio source: it
    /// never enters the music resolve order.
    case bilibili

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .netease: return String(localized: "网易云")
        case .qqmusic: return String(localized: "QQ音乐")
        case .kugou: return String(localized: "酷狗")
        case .bilibili: return String(localized: "哔哩哔哩")
        }
    }

    /// The audio-source toggle that gates this platform's search
    /// results and playback fallback. Nil for NetEase (always on)
    /// and for Bilibili (video, not a music source).
    var sourceID: AudioSourceID? {
        switch self {
        case .netease: return nil
        case .qqmusic: return .qqmusic
        case .kugou: return .kugou
        case .bilibili: return nil
        }
    }
}

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

/// A QQ/Kugou playlist from the platform home feed: just enough to
/// render a card. There is no platform playlist detail page — tapping
/// a card plays the playlist's songs directly.
struct PlatformPlaylistSummary: Hashable, Identifiable, Sendable {
    let source: AudioSourceID
    /// QQ playlist tid / Kugou special id.
    let platformID: Int
    let name: String
    let coverURL: URL?
    /// Song count when the feed carries one.
    let trackCount: Int?

    var id: String { "\(source.rawValue)|\(platformID)" }
}

/// A QQ/Kugou chart from the platform home feed: just enough to
/// render a card. Tapping a card plays the chart's songs directly.
struct PlatformToplistItem: Hashable, Identifiable, Sendable {
    let source: AudioSourceID
    /// QQ top id / Kugou rank id.
    let platformID: Int
    let name: String
    let coverURL: URL?
    /// QQ `subTitle` / Kugou update frequency, when the feed has one.
    let subtitle: String?

    var id: String { "\(source.rawValue)|\(platformID)" }
}
