import Foundation

struct ArtistRef: Codable, Hashable, Identifiable {
    let id: Int
    let name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

struct AlbumRef: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let picUrl: String?

    init(id: Int, name: String, picUrl: String?) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? c.decode(String.self, forKey: .picUrl)
    }
}

/// A unified track model that decodes both the "v3" song shape (`ar`/`al`/`dt`)
/// and the legacy shape (`artists`/`album`/`duration`).
struct Track: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let artists: [ArtistRef]
    let album: AlbumRef
    let durationMS: Int
    let alias: [String]
    let transNames: [String]
    let fee: Int
    let mvID: Int
    let trackNo: Int
    let disc: String?
    let noCopyright: Bool
    /// Cloud-disk song marker (`pc` field present).
    let isCloud: Bool
    /// Some endpoints (cloudsearch, FM) embed the privilege in the track itself.
    let embeddedPrivilege: TrackPrivilege?
    /// Cross-platform origin (Beans QQ/Kugou search): which provider this
    /// track came from. Nil for NetEase tracks. The unblock providers
    /// short-circuit on this instead of searching by NetEase ID.
    let platformSource: AudioSourceID?
    /// Opaque per-provider song key (`songmid[|mediaMid]` for QQ,
    /// `hash[|albumAudioId|albumId]` for Kugou). Nil for NetEase tracks.
    let platformSongKey: String?

    var artistNames: String { artists.map(\.name).joined(separator: " / ") }
    var duration: TimeInterval { TimeInterval(durationMS) / 1000 }
    var subtitle: String? { transNames.first ?? alias.first }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case ar, artists
        case al, album
        case dt, duration
        case alia, alias
        case tns, fee, mv, no, cd, noCopyrightRcmd, pc, privilege
        case platformSource, platformSongKey
    }

    /// Memberwise init (the custom `init(from:)` below suppresses the
    /// synthesized one). The platform fields default to nil: NetEase
    /// call sites never set them.
    init(
        id: Int, name: String, artists: [ArtistRef], album: AlbumRef,
        durationMS: Int, alias: [String], transNames: [String], fee: Int,
        mvID: Int, trackNo: Int, disc: String?, noCopyright: Bool,
        isCloud: Bool, embeddedPrivilege: TrackPrivilege?,
        platformSource: AudioSourceID? = nil, platformSongKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.alias = alias
        self.transNames = transNames
        self.fee = fee
        self.mvID = mvID
        self.trackNo = trackNo
        self.disc = disc
        self.noCopyright = noCopyright
        self.isCloud = isCloud
        self.embeddedPrivilege = embeddedPrivilege
        self.platformSource = platformSource
        self.platformSongKey = platformSongKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        artists = (try? c.decode([ArtistRef].self, forKey: .ar))
            ?? (try? c.decode([ArtistRef].self, forKey: .artists)) ?? []
        album = (try? c.decode(AlbumRef.self, forKey: .al))
            ?? (try? c.decode(AlbumRef.self, forKey: .album))
            ?? AlbumRef(id: 0, name: "", picUrl: nil)
        durationMS = (try? c.decode(Int.self, forKey: .dt))
            ?? (try? c.decode(Int.self, forKey: .duration)) ?? 0
        alias = (try? c.decode([String].self, forKey: .alia))
            ?? (try? c.decode([String].self, forKey: .alias)) ?? []
        transNames = (try? c.decode([String].self, forKey: .tns)) ?? []
        fee = (try? c.decode(Int.self, forKey: .fee)) ?? 0
        mvID = (try? c.decode(Int.self, forKey: .mv)) ?? 0
        trackNo = (try? c.decode(Int.self, forKey: .no)) ?? 0
        disc = try? c.decode(String.self, forKey: .cd)
        noCopyright = c.contains(.noCopyrightRcmd)
            && (try? c.decodeNil(forKey: .noCopyrightRcmd)) == false
        isCloud = c.contains(.pc) && (try? c.decodeNil(forKey: .pc)) == false
        embeddedPrivilege = try? c.decode(TrackPrivilege.self, forKey: .privilege)
        // Cross-platform fields are absent in old archives (and in every
        // NetEase payload); missing keys decode to nil, never fail.
        platformSource = try? c.decode(AudioSourceID.self, forKey: .platformSource)
        platformSongKey = try? c.decode(String.self, forKey: .platformSongKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .ar)
        try c.encode(album, forKey: .al)
        try c.encode(durationMS, forKey: .dt)
        try c.encode(alias, forKey: .alia)
        try c.encode(transNames, forKey: .tns)
        try c.encode(fee, forKey: .fee)
        try c.encode(mvID, forKey: .mv)
        try c.encode(trackNo, forKey: .no)
        try c.encodeIfPresent(disc, forKey: .cd)
        if isCloud { try c.encode([String: String](), forKey: .pc) }
        if noCopyright { try c.encode([String: String](), forKey: .noCopyrightRcmd) }
        try c.encodeIfPresent(embeddedPrivilege, forKey: .privilege)
        try c.encodeIfPresent(platformSource, forKey: .platformSource)
        try c.encodeIfPresent(platformSongKey, forKey: .platformSongKey)
    }
}

extension Track {
    /// Builds a `Track` for a song that only exists on another platform
    /// (Beans QQ/Kugou search). The ID is a stable negative hash of
    /// source + song key: negative so it can never collide with a
    /// NetEase ID (NetEase IDs are positive; the `id > 0` guards in the
    /// lyric/download paths skip it gracefully), stable across launches
    /// (FNV-1a, not Swift's seeded `Hasher`) so queue/cache entries
    /// keyed by ID survive a restart, and never 0.
    static func platform(
        source: AudioSourceID, songKey: String, name: String,
        artistNames: [String], albumName: String, albumPicURL: URL?,
        durationMS: Int
    ) -> Track {
        Track(
            id: stableNegativeID(source: source, songKey: songKey),
            name: name,
            artists: artistNames.map { ArtistRef(id: 0, name: $0) },
            album: AlbumRef(id: 0, name: albumName, picUrl: albumPicURL?.absoluteString),
            durationMS: durationMS,
            alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0, disc: nil,
            noCopyright: false, isCloud: false, embeddedPrivilege: nil,
            platformSource: source, platformSongKey: songKey
        )
    }

    /// Maps one QQ search/detail song to a platform `Track`. Same
    /// mapping (guards, key construction, `Track.platform` call) as
    /// `SearchViewModel.searchQQSongs` used to inline; moved here so
    /// the platform detail pages share it exactly.
    static func fromQQSong(_ song: QQMusicSong) -> Track? {
        guard !song.title.isEmpty else { return nil }
        let key: String
        if let mediaMid = song.mediaMid, !mediaMid.isEmpty {
            key = "\(song.songmid)|\(mediaMid)"
        } else {
            key = song.songmid
        }
        return Track.platform(
            source: .qqmusic, songKey: key, name: song.title,
            artistNames: song.artistNames, albumName: song.albumName,
            albumPicURL: song.albumPicURL, durationMS: song.durationMS)
    }

    /// Maps one Kugou search/detail song to a platform `Track`. Same
    /// mapping as `SearchViewModel.searchKugouSongs` used to inline.
    static func fromKugouSong(_ song: KugouMusicSong) -> Track? {
        guard !song.title.isEmpty, !song.hash.isEmpty else { return nil }
        let key: String
        if let audioId = song.albumAudioId, !audioId.isEmpty,
           let albumId = song.albumId, !albumId.isEmpty {
            key = "\(song.hash)|\(audioId)|\(albumId)"
        } else {
            key = song.hash
        }
        return Track.platform(
            source: .kugou, songKey: key, name: song.title,
            artistNames: song.artistNames, albumName: song.albumName,
            albumPicURL: song.albumPicURL, durationMS: song.durationMS)
    }

    private static func stableNegativeID(source: AudioSourceID, songKey: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(source.rawValue)|\(songKey)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let id = Int(bitPattern: UInt(hash))
        if id == 0 { return -1 }
        if id == Int.min { return Int.min + 1 }
        return id < 0 ? id : -id
    }
}

/// Playability flags per track, returned in parallel `privileges` arrays.
struct TrackPrivilege: Codable, Hashable {
    let id: Int
    let fee: Int?
    let pl: Int?
    let st: Int?
    let cs: Bool?
    let maxbr: Int?
}

enum TrackPlayability: Hashable {
    case playable
    case vipOnly
    case paidAlbum
    case noCopyright
    case delisted

    var reason: String? {
        switch self {
        case .playable: return nil
        case .vipOnly: return String(localized: "VIP 专属")
        case .paidAlbum: return String(localized: "付费专辑")
        case .noCopyright: return String(localized: "无版权")
        case .delisted: return String(localized: "已下架")
        }
    }
}

extension Track {
    /// Mirrors YesPlayMusic's `isTrackPlayable` decision chain,
    /// with the VIP check widened to cover 黑胶 SVIP (vipType 110 etc).
    func playability(privilege: TrackPrivilege?, isLoggedIn: Bool, vipType: Int) -> TrackPlayability {
        let privilege = privilege ?? embeddedPrivilege
        if let pl = privilege?.pl, pl > 0 { return .playable }
        if isLoggedIn, privilege?.cs == true { return .playable }
        let effectiveFee = privilege?.fee ?? fee
        if effectiveFee == 1 {
            return vipType > 0 ? .playable : .vipOnly
        }
        if effectiveFee == 4 { return .paidAlbum }
        if noCopyright { return .noCopyright }
        if let st = privilege?.st, st < 0, isLoggedIn { return .delisted }
        return .playable
    }
}

extension Array where Element == Track {
    @discardableResult
    mutating func replaceRecommendation(_ rejected: Track, with replacement: Track) -> Bool {
        guard let index = firstIndex(where: { $0.id == rejected.id }),
              replacement.id != rejected.id,
              !contains(where: { $0.id == replacement.id }) else { return false }
        self[index] = replacement
        return true
    }
}
