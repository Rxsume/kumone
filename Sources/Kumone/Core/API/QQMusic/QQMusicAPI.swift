import Foundation
import os.log

/// Errors from the QQ Music API layer. Only the cases this
/// implementation can actually throw. No error case carries a
/// credential or a session token.
enum QQMusicError: LocalizedError, Equatable {
    case invalidResponse
    case invalidURL
    case httpStatus(Int)
    /// A request carrying login cookies was refused with HTTP 401.
    /// The API layer treats this as a dead login and calls
    /// `QQMusicAuth.sessionExpired()` before throwing.
    case unauthorized
    /// A QR / OAuth login step failed for a backend-reported reason
    /// (the message is user-facing).
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid QQ Music response"
        case .invalidURL:
            return "Invalid QQ Music URL"
        case .httpStatus(let status):
            return "QQ Music HTTP status \(status)"
        case .unauthorized:
            return "QQ Music login required"
        case .loginFailed(let message):
            return message
        }
    }
}

// MARK: - Result types

/// One QQ Music song search / playlist hit.
struct QQMusicSong: Hashable, Identifiable, Sendable {
    let songmid: String
    let mediaMid: String?
    let title: String
    let artistNames: [String]
    let albumName: String
    let albumPicURL: URL?
    /// Length in milliseconds.
    let durationMS: Int

    var id: String { songmid }
    var artistDisplayName: String { artistNames.joined(separator: " / ") }
}

/// One QQ Music artist search hit.
struct QQMusicArtist: Hashable, Identifiable, Sendable {
    let name: String
    let picURL: URL?
    /// Platform singer MID (from `singerMID` / `mid` in search
    /// responses). Nil when the source did not carry one.
    let mid: String? = nil

    var id: String { name }
}

/// One QQ Music album search hit.
struct QQMusicAlbum: Hashable, Identifiable, Sendable {
    let name: String
    let artistName: String
    let picURL: URL?
    /// Platform album MID (from `mid` / `albummid` / `albumMID` in
    /// search responses). Nil when the source did not carry one.
    let mid: String? = nil

    var id: String { "\(artistName)-\(name)" }
}

/// Full QQ Music album detail, from `fcg_v8_album_info_cp.fcg`.
struct QQMusicAlbumDetail: Hashable, Sendable {
    let mid: String
    let name: String
    let artistName: String
    let artistMid: String?
    let picURL: URL?
    let publishDate: String?
    let description: String?
    let genre: String?
    let totalSongs: Int
    let songs: [QQMusicSong]
}

/// One of the logged-in user's QQ Music playlists.
struct QQMusicUserPlaylist: Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let coverURL: URL?
    let trackCount: Int?
}

/// A resolved QQ Music playback URL plus which quality tier hit, so the
/// player can keep stepping down when `AVPlayer` itself fails.
struct QQMusicSongURLResult: Hashable, Sendable {
    let url: URL
    let br: String
    let attemptedBRs: [String]
}

/// QQ Music API (search / playback URL / hot keys / liked songs /
/// like / user playlists), adapted from Beans' `QQMusicAPI`.
///
/// Direct to QQ's public endpoints — no self-hosted backend:
/// - Song search: anonymous `musicu.fcg` (`DoSearchForQQMusicLite`,
///   `search_type` 7 — `0` is refused upstream with code 2001), with
///   `client_search_cp` (`t=0`) as fallback. Artist/album search use
///   `musicu` `DoSearchForQQMusicDesktop` (`search_type` 1/2) and
///   `client_search_cp` (`t=8` for albums).
/// - Playback: vkey (`CDN.SrfCdnDispatchServer` + `vkey.GetVkeyServer`)
///   with the ladder F000 (FLAC) -> M800 (320k) -> M500 (128k) -> C400,
///   `resolveMediaMid` filling in the `media_mid` search often omits,
///   and a Range probe (`probeAudioURL`) weeding out dead CDN URLs.
///   Anonymous (logged-out) requests work for free tracks; logged-in
///   requests attach `authst` + cookies so VIP tracks resolve.
///
/// Skipped from Beans on purpose: comments, top lists, recommend
/// songs, hot playlists, lyric (lyrics are PR #23's `QQLyricProvider`
/// — untouched), playlist create/delete and playlist-song browsing
/// beyond what `favoriteSongs` needs.
///
/// Errors are `QQMusicError` (defined at the top of this file). A 401 on an
/// authenticated call, or a vkey answer with no `midurlinfo` at all
/// while logged in, calls `QQMusicAuth.sessionExpired()`.
final class QQMusicAPI: Sendable {
    static let shared = QQMusicAPI()

    /// QQ "我的喜欢" is not a normal created playlist; this stable
    /// placeholder ID routes it to the dedicated loading flow.
    static let likedPlaylistID = -201
    private static let likedCoverURL = URL(string: "https://y.gtimg.cn/mediastyle/global/img/cover_like.png")

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")
    private static let musicuURLString = "https://u.y.qq.com/cgi-bin/musicu.fcg"
    private static let searchBase = "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp"
    private static let webUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 QQMusic/9.0.5"
    private static let vkeyUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    // MARK: - Search

    /// Searches songs. Anonymous `musicu` search first; an empty or
    /// failed musicu answer falls back to `client_search_cp`.
    func searchSongs(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [QQMusicSong] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let songs = try? await musicuSearchSongs(keyword: trimmed, limit: limit, offset: offset),
           !songs.isEmpty {
            return songs
        }
        return try await clientSearchSongs(keyword: trimmed, limit: limit, offset: offset)
    }

    /// Searches artists (`musicu` `search_type` 1; `smartbox_new`
    /// suggestions as fallback). Returns [] when nothing answers.
    func searchArtists(keyword: String, limit: Int = 30) async throws -> [QQMusicArtist] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let json = try? await musicu(musicuSearchPayload(keyword: trimmed, limit: limit, type: .artist)) {
            let list = nestedArray(json, path: ["req_1", "data", "body", "singer", "list"])
            var artists: [QQMusicArtist] = []
            for item in list {
                let name = item["singerName"] as? String ?? (item["name"] as? String ?? (item["title"] as? String ?? ""))
                guard !name.isEmpty else { continue }
                let mid = item["singerMID"] as? String ?? (item["mid"] as? String)
                artists.append(QQMusicArtist(name: name, picURL: Self.singerPhotoURL(mid), mid: mid))
            }
            if !artists.isEmpty { return Array(artists.prefix(limit)) }
        }
        // Fallback: smartbox_new.fcg suggestions (singers + albums).
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?format=json&s_from=pc_header&type=1&key=\(encoded)"),
           let json = try? await get(url.absoluteString) {
            let singer = (json["data"] as? [String: Any])?["singer"] as? [String: Any] ?? [:]
            let list = singer["itemlist"] as? [[String: Any]] ?? []
            var artists: [QQMusicArtist] = []
            for item in list.prefix(limit) {
                let name = item["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                let mid = item["mid"] as? String
                artists.append(QQMusicArtist(
                    name: name,
                    picURL: Self.normalizedQQImageURL(item["pic"]) ?? Self.singerPhotoURL(mid),
                    mid: mid))
            }
            if !artists.isEmpty { return artists }
        }
        return []
    }

    /// Searches albums (`client_search_cp` `t=8` first — it works on
    /// home, mobile and datacenter networks alike; `musicu`
    /// `search_type` 2 is the fallback). Returns [] when nothing answers.
    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [QQMusicAlbum] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let url = clientSearchURL(keyword: trimmed, limit: limit, type: 8),
           let json = try? await get(url.absoluteString, referer: "https://y.qq.com/portal/player.html") {
            let data = json["data"] as? [String: Any] ?? [:]
            let album = data["album"] as? [String: Any] ?? [:]
            let list = album["list"] as? [[String: Any]] ?? []
            if !list.isEmpty {
                return parseAlbumItems(list)
            }
        }
        if let json = try? await musicu(musicuSearchPayload(keyword: trimmed, limit: limit, type: .album)) {
            let list = nestedArray(json, path: ["req_1", "data", "body", "album", "list"])
            if !list.isEmpty {
                return parseAlbumItems(list)
            }
        }
        return []
    }

    /// QQ Music hot search terms.
    func hotKeys(limit: Int = 10) async throws -> [String] {
        let url = "https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg?format=json&inCharset=utf8&outCharset=utf-8"
        let json = try await get(url)
        let data = json["data"] as? [String: Any] ?? [:]
        let hots = data["hotkey"] as? [[String: Any]] ?? []
        return hots.compactMap { $0["k"] as? String }.prefix(limit).map { $0 }
    }

    // MARK: - Artist / album detail

    /// Songs by one artist, via song search: no live dedicated
    /// artist-songs endpoint exists (the `fcg_v8_singer_track_cp`,
    /// `GetSingerSongList` and `GetHomepageSongList` routes are all
    /// dead), so the artist name is searched and only songs whose
    /// artist list contains that exact name — after normalization —
    /// are kept. `mid` is accepted for API symmetry / future use; the
    /// search path does not need it.
    func artistSongs(name: String, mid: String?, limit: Int = 60) async throws -> [QQMusicSong] {
        // `mid` is intentionally unused: see the doc comment above.
        _ = mid
        let expected = Self.normalizedArtistName(name)
        guard !expected.isEmpty else { return [] }
        let songs = try await searchSongs(keyword: name, limit: max(limit, 30))
        var seen = Set<String>()
        var result: [QQMusicSong] = []
        for song in songs {
            guard result.count < limit else { break }
            guard song.artistNames.contains(where: { Self.normalizedArtistName($0) == expected }) else { continue }
            guard seen.insert(song.songmid).inserted else { continue }
            result.append(song)
        }
        return result
    }

    /// Albums by one artist, via album search: no live dedicated
    /// artist-albums endpoint exists (the `fcg_v8_singer_album*` and
    /// `GetSingerAlbum` routes are all dead), so the artist name is
    /// searched and only albums whose artist tokens intersect the
    /// expected artist tokens are kept. `mid` is accepted for API
    /// symmetry / future use; the search path does not need it.
    func artistAlbums(name: String, mid: String?, limit: Int = 30) async throws -> [QQMusicAlbum] {
        // `mid` is intentionally unused: see the doc comment above.
        _ = mid
        let expectedTokens = Self.artistNameTokens(name)
        guard !expectedTokens.isEmpty else { return [] }
        let albums = try await searchAlbums(keyword: name, limit: max(limit, 30))
        var seen = Set<String>()
        var result: [QQMusicAlbum] = []
        for album in albums {
            guard result.count < limit else { break }
            guard !Self.artistNameTokens(album.artistName).isDisjoint(with: expectedTokens) else { continue }
            let key = (album.mid?.isEmpty == false ? album.mid : nil) ?? album.name
            guard seen.insert(key).inserted else { continue }
            result.append(album)
        }
        return result
    }

    /// Full album detail via the live `fcg_v8_album_info_cp.fcg`
    /// endpoint, paginated 30 songs at a time (capped at ~100 songs).
    /// Song rows are parsed with the shared `song(from:)`; their
    /// `mediaMid` is usually nil here and playback fills it in via
    /// `resolveMediaMid`.
    func albumDetail(mid: String) async throws -> QQMusicAlbumDetail {
        guard !mid.isEmpty else { throw QQMusicError.invalidResponse }
        let pageSize = 30
        let cap = 100
        var songs: [QQMusicSong] = []
        var seenSongMids = Set<String>()
        var begin = 0
        var albumName = ""
        var artistName = ""
        var artistMid: String?
        var publishDate: String?
        var albumDescription: String?
        var genre: String?
        var totalSongs = 0
        var isFirstPage = true
        while songs.count < cap {
            var comps = URLComponents(string: "https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg")
            comps?.queryItems = [
                URLQueryItem(name: "albummid", value: mid),
                URLQueryItem(name: "song_begin", value: "\(begin)"),
                URLQueryItem(name: "song_num", value: "\(pageSize)"),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = comps?.url else { throw QQMusicError.invalidURL }
            let json = try await get(url.absoluteString)
            guard (json["code"] as? Int) == 0,
                  let data = json["data"] as? [String: Any] else {
                throw QQMusicError.invalidResponse
            }
            if isFirstPage {
                albumName = data["name"] as? String ?? ""
                guard !albumName.isEmpty else { throw QQMusicError.invalidResponse }
                artistName = data["singername"] as? String ?? (data["singerName"] as? String ?? "")
                artistMid = data["singermid"] as? String ?? (data["singerMID"] as? String)
                publishDate = data["aDate"] as? String
                albumDescription = data["desc"] as? String
                genre = data["genre"] as? String
                totalSongs = Self.integerValue(data["total"] ?? data["total_song_num"])
                isFirstPage = false
            }
            let list = data["list"] as? [[String: Any]] ?? []
            for song in list.compactMap({ song(from: $0) }) {
                guard seenSongMids.insert(song.songmid).inserted else { continue }
                songs.append(song)
                if songs.count >= cap { break }
            }
            if list.count < pageSize { break }
            if totalSongs > 0, songs.count >= min(totalSongs, cap) { break }
            begin += pageSize
        }
        return QQMusicAlbumDetail(
            mid: mid,
            name: albumName,
            artistName: artistName,
            artistMid: artistMid,
            picURL: Self.photoURL(mid),
            publishDate: publishDate,
            description: albumDescription,
            genre: genre,
            totalSongs: totalSongs > 0 ? totalSongs : songs.count,
            songs: songs)
    }

    /// Normalizes an artist name for comparison: lowercased, with
    /// parenthetical "(...)" / "（...)" content and all whitespace /
    /// punctuation stripped, so "周杰伦 (Jay Chou)" matches "周杰伦".
    private static func normalizedArtistName(_ name: String) -> String {
        var text = name.lowercased()
        for (open, close) in [(Character("("), Character(")")), (Character("（"), Character("）"))] {
            while let start = text.firstIndex(of: open),
                  let end = text[start...].firstIndex(of: close) {
                text.removeSubrange(start...end)
            }
            // Unmatched opener: drop it and everything after it.
            if let start = text.firstIndex(of: open) {
                text.removeSubrange(start...)
            }
        }
        return text.filter { $0.isLetter || $0.isNumber }
    }

    /// Artist-name tokens: split on common multi-artist separators,
    /// then normalize each token.
    private static func artistNameTokens(_ name: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/、,，&;；")
        return Set(name.components(separatedBy: separators)
            .map { normalizedArtistName($0) }
            .filter { !$0.isEmpty })
    }

    // MARK: - Liked songs / like

    /// The logged-in user's "我的喜欢" (red-heart) songs. `limit <= 0`
    /// pages until the endpoint stops returning songs. Returns [] when
    /// logged out. Three stages, in Beans' order: the legacy `dirid=201`
    /// map -> detail flow, the official `CgiGetDiss` musicu flow, then
    /// per-identity `dirid=201` attempts, with a real-playlist-ID
    /// detail fetch as the last resort.
    func favoriteSongs(limit: Int = 0) async throws -> [QQMusicSong] {
        let auth = await authSnapshot()
        guard auth.isLoggedIn else { return [] }
        let pageSize = 300
        let targetLimit = limit > 0 ? limit : Int.max
        let cookieCandidates = [auth.playlistCookieHeader, auth.cookieHeader]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }

        // Stage 1: legacy flow. 201 returns the real playlist ID, then
        // the detail request MUST use loginUin=0 + the full cookie;
        // swapping in wxuin or a trimmed cookie returns empty here.
        let legacyFavURL = "https://c.y.qq.com/splcloud/fcgi-bin/fcg_musiclist_getmyfav.fcg?dirid=201&dirinfo=1&g_tk=\(auth.gtk)&format=json&utf8=1"
        if let favJson = try? await get(legacyFavURL, referer: "https://y.qq.com/n/yqq/playlist", cookie: auth.cookieHeader),
           let mapid = Self.likedMapID(favJson), mapid > 0 {
            let detailURL = "https://c.y.qq.com/qzone/fcgi-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(mapid)&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
            if let detailJson = try? await get(detailURL, referer: "https://y.qq.com/", cookie: auth.cookieHeader),
               let cdlist = detailJson["cdlist"] as? [[String: Any]],
               let rawSongs = cdlist.first?["songlist"] as? [[String: Any]] {
                let songs = rawSongs.prefix(targetLimit).compactMap { song(from: Self.unwrapQQSong($0)) }
                if !songs.isEmpty && (limit > 0 || rawSongs.count < pageSize) { return songs }
            }
        }

        // Stage 2: official "我的喜欢" detail endpoint (disstid/dirid
        // 201), paginated.
        let officialPayload: [String: Any] = [
            "comm": [
                "ct": 24,
                "cv": 0,
                "uin": auth.playlistUin,
                "g_tk": auth.gtk,
                "platform": "yqq",
            ],
            "req_1": [
                "module": "music.srfDissInfo.DissInfo",
                "method": "CgiGetDiss",
                "param": [
                    "new_format": 1,
                    "disstid": 201,
                    "dirid": 201,
                    "song_begin": 0,
                    "song_num": pageSize,
                    "enc_host_uin": auth.playlistUin,
                    "onlysonglist": 0,
                    "userinfo": 1,
                ],
            ],
        ]
        for cookie in cookieCandidates {
            var allSongs: [QQMusicSong] = []
            var seen = Set<String>()
            var begin = 0
            while allSongs.count < targetLimit {
                var pagePayload = officialPayload
                if var req = pagePayload["req_1"] as? [String: Any],
                   var param = req["param"] as? [String: Any] {
                    param["song_begin"] = begin
                    req["param"] = param
                    pagePayload["req_1"] = req
                }
                guard let json = try? await musicu(pagePayload, cookie: cookie, timeout: 20) else { break }
                let rawPage = Self.favoriteSongArray(from: json)
                let pageSongs = rawPage.compactMap { song(from: Self.unwrapQQSong($0)) }
                let newSongs = pageSongs.filter { seen.insert($0.songmid).inserted }
                allSongs.append(contentsOf: newSongs)
                if rawPage.count < pageSize || newSongs.isEmpty { break }
                begin += rawPage.count
            }
            if !allSongs.isEmpty {
                return limit > 0 ? Array(allSongs.prefix(limit)) : allSongs
            }
        }

        // Stage 3: the 201 endpoint sometimes returns the songs
        // directly instead of a playlist ID; consume those before
        // falling back to a playlist-ID lookup (WeChat login otherwise
        // ends up with an empty list).
        for identity in auth.playlistIdentityCandidates {
            let favURL = "https://c.y.qq.com/splcloud/fcgi-bin/fcg_musiclist_getmyfav.fcg?dirid=201&dirinfo=1&uin=\(identity)&loginUin=\(identity)&hostUin=0&g_tk=\(auth.gtk)&format=json&utf8=1"
            for cookie in cookieCandidates {
                guard let favJson = try? await get(favURL, referer: "https://y.qq.com/n/ryqq_v2/profile/create", cookie: cookie) else { continue }
                let songs = Self.favoriteSongArray(from: favJson)
                    .prefix(targetLimit)
                    .compactMap { song(from: ($0["track_info"] as? [String: Any]) ?? $0) }
                if !songs.isEmpty { return songs }
            }
        }

        guard let mapid = await likedPlaylistID(auth: auth, cookies: cookieCandidates), mapid > 0 else {
            return []
        }
        let fallbackLimit = limit > 0 ? limit : pageSize
        for cookie in cookieCandidates {
            let songs = try await playlistSongs(listID: mapid, preferredCookie: cookie, limit: fallbackLimit)
            if !songs.isEmpty { return songs }
        }
        return try await playlistSongs(listID: mapid, preferredCookie: nil, limit: fallbackLimit)
    }

    /// Hearts / un-hearts a song (`music.srfDissong do_dissong_op`).
    /// Returns false when logged out.
    func like(songmid: String, liked: Bool) async throws -> Bool {
        let auth = await authSnapshot()
        guard auth.isLoggedIn else { return false }
        let payload: [String: Any] = [
            "comm": [
                "ct": 24,
                "cv": 0,
                "uin": auth.uin,
                "g_tk": 5381,
                "platform": "yqq",
                "format": "json",
            ],
            "req_0": [
                "module": "music.srfDissong",
                "method": "do_dissong_op",
                "param": [
                    "songmid": [songmid],
                    "op": liked ? 1 : 2,
                ],
            ],
        ]
        let json = try await musicu(payload, cookie: auth.cookieHeader)
        let req = json["req_0"] as? [String: Any]
        let code = req?["code"] as? Int ?? -1
        return code == 0
    }

    // MARK: - Playlists

    /// The logged-in user's playlists (created + collected merged).
    /// WeChat web login may have no QQ `uin`, so the official
    /// `GetUserPlaylist` endpoint is tried with every identity
    /// candidate, with the legacy fcg endpoints as the fast path for QQ
    /// login. Returns [] when logged out. "我的喜欢" is always present
    /// as the first entry (it lives under `dirid=201`, not in the
    /// created/collected lists).
    func userPlaylists(uin: String) async throws -> [QQMusicUserPlaylist] {
        let auth = await authSnapshot()
        guard auth.isLoggedIn else { return [] }

        let requestUin = auth.playlistUin
        let cookieCandidates = [auth.playlistCookieHeader, auth.cookieHeader]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        let legacyUins = (auth.playlistIdentityCandidates + [requestUin, uin])
            .filter { !$0.isEmpty && $0 != "0" }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }

        var playlists: [QQMusicUserPlaylist] = []
        var seen = Set<Int>()

        func append(_ item: [String: Any]) {
            guard let playlist = Self.playlist(fromQQDiss: item), !seen.contains(playlist.id) else { return }
            let text = playlist.name + " " + (item["hostname"] as? String ?? "")
            if text.lowercased().contains("qzone") || text.contains("空间") || text.contains("背景音乐") { return }
            seen.insert(playlist.id)
            playlists.append(playlist)
        }

        var createdLoaded = false
        var collectedLoaded = false

        for legacyUin in legacyUins {
            let createdURL = "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss?hostUin=0&hostuin=\(legacyUin)&sin=0&size=200&g_tk=\(auth.gtk)&loginUin=\(legacyUin)&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
            for cookie in cookieCandidates {
                guard let created = try? await get(createdURL, referer: "https://y.qq.com/portal/profile.html", cookie: cookie) else { continue }
                let data = created["data"] as? [String: Any] ?? created
                let disslist = (data["disslist"] as? [[String: Any]]) ?? (created["disslist"] as? [[String: Any]]) ?? []
                if !disslist.isEmpty {
                    createdLoaded = true
                    disslist.forEach(append)
                    break
                }
            }
            if createdLoaded { break }
        }

        for legacyUin in legacyUins {
            let collectURL = "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg?ct=20&cid=205360956&userid=\(legacyUin)&reqtype=3&sin=0&ein=80&g_tk=\(auth.gtk)"
            for cookie in cookieCandidates {
                guard let collected = try? await get(collectURL, referer: "https://y.qq.com/portal/profile.html", cookie: cookie) else { continue }
                let data = collected["data"] as? [String: Any] ?? collected
                let cdlist = (data["cdlist"] as? [[String: Any]]) ?? (collected["cdlist"] as? [[String: Any]]) ?? []
                if !cdlist.isEmpty {
                    collectedLoaded = true
                    cdlist.forEach(append)
                    break
                }
            }
            if collectedLoaded { break }
        }

        // Official App endpoint, per identity candidate. order: 1 =
        // created, 2 = collected, 3 = liked. An empty answer still tries
        // the next identity.
        let officialUins = (auth.playlistIdentityCandidates + [requestUin, "0"]).reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        for (order, loaded) in [(1, createdLoaded), (2, collectedLoaded), (3, false)] {
            if loaded { continue }
            for officialUin in officialUins {
                let numericUin = Int(officialUin) ?? 0
                let payload: [String: Any] = [
                    "comm": [
                        "ct": 24,
                        "cv": 0,
                        "uin": numericUin,
                        "g_tk": auth.gtk,
                        "platform": "yqq",
                    ],
                    "req_1": [
                        "module": "music.musichallSong.PlayListDataServer",
                        "method": "GetUserPlaylist",
                        "param": [
                            "uin": numericUin,
                            "sin": 0,
                            "size": 200,
                            "order": order,
                        ],
                    ],
                ]
                for cookie in cookieCandidates {
                    guard let json = try? await musicu(payload, cookie: cookie, timeout: 15) else { continue }
                    let list = Self.playlistArray(from: json)
                    if !list.isEmpty {
                        list.forEach(append)
                        break
                    }
                }
                if !playlists.isEmpty && order != 3 { break }
            }
        }

        if !seen.contains(Self.likedPlaylistID) &&
           !playlists.contains(where: { $0.name == "我的喜欢" }) {
            playlists.insert(
                QQMusicUserPlaylist(
                    id: Self.likedPlaylistID,
                    name: "我的喜欢",
                    coverURL: Self.likedCoverURL,
                    trackCount: nil
                ),
                at: 0
            )
        }

        playlists.sort { lhs, rhs in
            let a = lhs.name.contains("我喜欢") || lhs.name.contains("我的喜欢") || lhs.name.contains("喜欢的音乐")
            let b = rhs.name.contains("我喜欢") || rhs.name.contains("我的喜欢") || rhs.name.contains("喜欢的音乐")
            if a != b { return a }
            return lhs.name < rhs.name
        }
        return playlists
    }

    // MARK: - Playback URLs

    /// One vkey request at a single quality tier (`br`: `F000` FLAC /
    /// `M800` 320k / `M500` 128k / `C400`). Returns nil when QQ issues
    /// no playable URL at this tier (e.g. a VIP track for this account)
    /// — that is "no audio", not a transport error. Anonymous callers
    /// get free tracks only.
    func songURL(songmid: String, mediaMid: String? = nil, br: String) async throws -> String? {
        let auth = await authSnapshot()
        let uin = auth.isLoggedIn ? auth.uin : "0"
        let loginKey = auth.isLoggedIn ? auth.loginKey : ""
        let resolvedMediaMid = await resolveMediaMid(songmid: songmid, provided: mediaMid, auth: auth)
        return try await vkeyURL(
            songmid: songmid, mediaMid: resolvedMediaMid, br: br,
            uin: uin, loginKey: loginKey, guid: Self.deviceGuid, auth: auth)
    }

    /// Runs the full quality ladder F000 -> M800 -> M500 -> C400 and
    /// returns the first playable URL, with the tier that hit and the
    /// tiers attempted, so the player can keep stepping down when
    /// `AVPlayer` itself fails on the returned URL. Nil when no tier
    /// yields a URL.
    func songURLResult(songmid: String, mediaMid: String? = nil) async throws -> QQMusicSongURLResult? {
        let auth = await authSnapshot()
        let uin = auth.isLoggedIn ? auth.uin : "0"
        let loginKey = auth.isLoggedIn ? auth.loginKey : ""
        let resolvedMediaMid = await resolveMediaMid(songmid: songmid, provided: mediaMid, auth: auth)
        var attemptedBRs: [String] = []
        for br in ["F000", "M800", "M500", "C400"] {
            attemptedBRs.append(br)
            if let urlString = try await vkeyURL(
                songmid: songmid, mediaMid: resolvedMediaMid, br: br,
                uin: uin, loginKey: loginKey, guid: Self.deviceGuid, auth: auth),
               let url = URL(string: urlString) {
                return QQMusicSongURLResult(url: url, br: br, attemptedBRs: attemptedBRs)
            }
        }
        return nil
    }

    /// Search often omits `file.media_mid`, and VIP-only tracks
    /// commonly have a `media_mid` different from their `songmid`, so
    /// the detail endpoint is consulted when no `mediaMid` was given.
    /// Falls back to `songmid` when the detail call answers nothing.
    private func resolveMediaMid(songmid: String, provided: String?, auth: AuthSnapshot) async -> String {
        if let provided, !provided.isEmpty { return provided }
        let payload: [String: Any] = [
            "comm": ["ct": 24, "cv": 0, "uin": auth.isLoggedIn ? auth.uin : "0"],
            "songinfo": [
                "module": "music.pf_song_detail_svr",
                "method": "get_song_detail_yqq",
                "param": ["song_mid": songmid],
            ],
        ]
        guard let json = try? await musicu(payload, cookie: auth.isLoggedIn ? auth.cookieHeader : ""),
              let block = json["songinfo"] as? [String: Any],
              let data = block["data"] as? [String: Any],
              let track = data["track_info"] as? [String: Any],
              let file = track["file"] as? [String: Any],
              let mediaMid = file["media_mid"] as? String,
              !mediaMid.isEmpty else {
            return songmid
        }
        return mediaMid
    }

    /// One vkey request (GET `musicu.fcg`, `data` query param in the
    /// `wp_MusicApi` shape). Tries several filename spellings — the
    /// official web form is `prefix + songmid + media_mid` — and probes
    /// each CDN candidate with a Range request before returning it.
    private func vkeyURL(
        songmid: String, mediaMid: String?, br: String,
        uin: String, loginKey: String, guid: String, auth: AuthSnapshot
    ) async throws -> String? {
        // Quality -> extension: M500/M800 are mp3, F000 (lossless) is
        // flac, C400 is m4a.
        let ext: String
        if br.hasPrefix("F") {
            ext = "flac"
        } else if br.hasPrefix("C") {
            ext = "m4a"
        } else {
            ext = "mp3"
        }
        let preferredMid = (mediaMid?.isEmpty == false ? mediaMid : nil) ?? songmid
        var filenames = [
            "\(br)\(songmid)\(preferredMid).\(ext)",
            "\(br)\(preferredMid).\(ext)",
            "\(br)\(songmid)\(songmid).\(ext)",
            "\(br)\(songmid).\(ext)",
        ]
        var seenFilenames = Set<String>()
        filenames = filenames.filter { seenFilenames.insert($0).inserted }
        let param: [String: Any] = [
            "filename": filenames,
            "guid": guid,
            "songmid": Array(repeating: songmid, count: filenames.count),
            "songtype": Array(repeating: 0, count: filenames.count),
            "uin": uin,
            "loginflag": auth.isLoggedIn ? 1 : 0,
            "platform": "20",
        ]
        var comm: [String: Any] = [
            "uin": Int(uin) ?? 0,
            "format": "json",
            "ct": loginKey.isEmpty ? 24 : 19,
            "cv": 0,
            "g_tk": auth.gtk,
        ]
        if !loginKey.isEmpty { comm["authst"] = loginKey }
        let payload: [String: Any] = [
            "comm": comm,
            "req": [
                "module": "CDN.SrfCdnDispatchServer",
                "method": "GetCdnDispatch",
                "param": ["guid": guid, "calltype": 0, "userip": ""],
            ],
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": param,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let dataString = String(data: data, encoding: .utf8),
              var comps = URLComponents(string: Self.musicuURLString) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "data", value: dataString),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.vkeyUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        request.setValue(auth.isLoggedIn ? auth.cookieHeader : "uin=0; qqmusic_fromtag=66", forHTTPHeaderField: "Cookie")
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 {
            if auth.isLoggedIn { await QQMusicAuth.shared.sessionExpired() }
            throw QQMusicError.unauthorized
        }
        guard http.statusCode == 200,
              let json = parseJSON(responseData),
              let req = json["req_0"] as? [String: Any] else { return nil }
        guard let reqData = req["data"] as? [String: Any],
              let infos = reqData["midurlinfo"] as? [[String: Any]] else {
            // A well-formed vkey answer with no midurlinfo at all while
            // logged in means the session no longer unlocks anything.
            // (An empty `purl` inside an info is different — that is
            // just a VIP track this account cannot play — and does NOT
            // expire the session.)
            if auth.isLoggedIn, (req["code"] as? Int) == 0 {
                await QQMusicAuth.shared.sessionExpired()
            }
            return nil
        }
        let playableInfos = infos.filter { ($0["purl"] as? String)?.isEmpty == false }
        guard !playableInfos.isEmpty else { return nil }
        let sips = reqData["sip"] as? [String] ?? []
        let cdnBases = Self.qqCDNBases(from: sips)
        var unverifiedCandidate: String?
        for info in playableInfos {
            guard let purl = info["purl"] as? String, !purl.isEmpty else { continue }
            let candidateURLs: [String]
            if purl.hasPrefix("http") {
                candidateURLs = [purl]
            } else {
                candidateURLs = cdnBases.map { base in
                    let secureBase = base.hasPrefix("http://") ? "https://" + String(base.dropFirst("http://".count)) : base
                    let suffix = purl.hasPrefix("/") ? String(purl.dropFirst()) : purl
                    return secureBase + suffix
                }
            }
            for candidate in candidateURLs {
                guard let url = URL(string: candidate) else { continue }
                unverifiedCandidate = unverifiedCandidate ?? candidate
                switch await probeAudioURL(url, cookie: auth.isLoggedIn ? auth.cookieHeader : "") {
                case .playable:
                    return candidate
                case .forbidden:
                    continue
                case .indeterminate:
                    unverifiedCandidate = unverifiedCandidate ?? candidate
                }
            }
        }
        // Some QQ CDNs refuse Range probes but still play fine in
        // AVPlayer with Referer/Cookie; do not mistake "probe refused"
        // for "no permission", hand the address to the player.
        return unverifiedCandidate
    }

    private enum AudioProbeResult {
        case playable
        case forbidden
        case indeterminate
    }

    /// Verifies a CDN URL with a Range request before handing it to
    /// `AVPlayer`, so a non-empty `purl` that is actually a 404 is not
    /// reported as success.
    private func probeAudioURL(_ url: URL, cookie: String) async -> AudioProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.setValue(Self.vkeyUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Timeout / TLS / a CDN node that does not support Range
            // proves nothing about the URL; let AVPlayer decide.
            return .indeterminate
        }
        if [403, 404, 410, 451].contains(http.statusCode) {
            return .forbidden
        }
        guard http.statusCode == 200 || http.statusCode == 206, !data.isEmpty else {
            return .indeterminate
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") || contentType.contains("application/json") {
            return .forbidden
        }
        return .playable
    }

    /// Fixed device GUID (persisted): vkey is bound to the guid, so a
    /// random guid per call would invalidate the playback URLs. This is
    /// a device identifier, not a credential, so `UserDefaults` is fine.
    private static var deviceGuid: String {
        let key = "sb.moe.kumone.qqmusic.guid"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let guid = String(format: "%09d", Int.random(in: 100000000...999999999))
        UserDefaults.standard.set(guid, forKey: key)
        return guid
    }

    /// QQ's SIP list only holds the currently assigned nodes; keep the
    /// official nodes and add common fallback CDNs so a playback URL
    /// does not hinge on one temporarily dead node.
    private static func qqCDNBases(from sips: [String]) -> [String] {
        let fallbacks = [
            "https://isure.stream.qqmusic.qq.com/",
            "https://dl.stream.qqmusic.qq.com/",
            "https://ws.stream.qqmusic.qq.com/",
            "https://streamoc.music.tc.qq.com/",
        ]
        var result: [String] = []
        var seen = Set<String>()
        for raw in sips + fallbacks {
            var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { continue }
            if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
                base = "https://" + base
            }
            if !base.hasSuffix("/") {
                base += "/"
            }
            let key = base.lowercased()
            if seen.insert(key).inserted {
                result.append(base)
            }
        }
        return result
    }

    // MARK: - Search internals

    /// Anonymous `musicu` song search (`DoSearchForQQMusicLite`,
    /// `search_type` 7). Logged-in callers attach their cookies; logged
    /// out, only `tmeLoginType=-1` is sent.
    private func musicuSearchSongs(keyword: String, limit: Int, offset: Int) async throws -> [QQMusicSong] {
        let auth = await authSnapshot()
        let pageSize = max(limit, 1)
        let page = max(offset, 0) / pageSize + 1
        let searchID = String(
            Int64.random(in: 0..<100_000_000_000_000)
            + Int64(Date().timeIntervalSince1970 * 1000) % 86_400_000)
        let param: [String: Any] = [
            "search_id": searchID,
            "remoteplace": "search.android.keyboard",
            "query": keyword,
            "search_type": 7,
            "num_per_page": pageSize,
            "page_num": page,
            "highlight": 0,
            "nqc_flag": 0,
            "page_id": 1,
            "grp": 1,
        ]
        let payload: [String: Any] = [
            "comm": [
                "ct": 11,
                "cv": "1003006",
                "v": "1003006",
                "os_ver": "15",
                "phonetype": "24122RKC7C",
                "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.102.0.VOMCNXM:user/release-keys",
                "tmeAppID": "qqmusiclight",
                "nettype": "NETWORK_WIFI",
                "udid": "0",
                "uid": "0",
            ],
            "request": [
                "method": "DoSearchForQQMusicLite",
                "module": "music.search.SearchCgiService",
                "param": param,
            ],
        ]
        let cookie = auth.isLoggedIn ? auth.cookieHeader : "tmeLoginType=-1;"
        let json = try await musicu(payload, cookie: cookie)
        guard (json["code"] as? Int) == 0,
              let requestNode = json["request"] as? [String: Any],
              (requestNode["code"] as? Int) == 0,
              let requestData = requestNode["data"] as? [String: Any],
              let bodyNode = requestData["body"] as? [String: Any],
              let items = bodyNode["item_song"] as? [[String: Any]]
        else { throw QQMusicError.invalidResponse }
        return items.compactMap { item -> QQMusicSong? in
            guard let mid = item["mid"] as? String, !mid.isEmpty,
                  let title = item["title"] as? String
            else { return nil }
            let singers = item["singer"] as? [[String: Any]] ?? []
            let artists = singers.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            let album = item["album"] as? [String: Any]
            let albumName = album?["name"] as? String ?? ""
            let albumMid = album?["mid"] as? String
            let interval = (item["interval"] as? NSNumber)?.doubleValue ?? 0
            let file = item["file"] as? [String: Any]
            let mediaMid = file?["media_mid"] as? String
            return QQMusicSong(
                songmid: mid, mediaMid: mediaMid, title: title,
                artistNames: artists, albumName: albumName,
                albumPicURL: Self.photoURL(albumMid),
                durationMS: Int(interval * 1000))
        }
    }

    /// `client_search_cp` song search (`t=0`), the fallback when the
    /// `musicu` search answers empty or fails.
    private func clientSearchSongs(keyword: String, limit: Int, offset: Int) async throws -> [QQMusicSong] {
        let pageSize = max(limit, 1)
        let page = max(offset, 0) / pageSize + 1
        guard let url = clientSearchURL(keyword: keyword, limit: pageSize, type: 0, page: page) else {
            throw QQMusicError.invalidURL
        }
        let json = try await get(url.absoluteString, referer: "https://y.qq.com/portal/player.html")
        let data = json["data"] as? [String: Any] ?? [:]
        let song = data["song"] as? [String: Any] ?? [:]
        let list = song["list"] as? [[String: Any]] ?? []
        return list.compactMap { song(from: $0) }
    }

    private func parseAlbumItems(_ items: [[String: Any]]) -> [QQMusicAlbum] {
        var albums: [QQMusicAlbum] = []
        for item in items {
            let name = item["name"] as? String ?? (item["albumname"] as? String ?? item["albumName"] as? String ?? "")
            guard !name.isEmpty else { continue }
            let mid = item["mid"] as? String ?? (item["albummid"] as? String ?? item["albumMID"] as? String)
            let singer = (item["singer"] as? [[String: Any]]) ?? []
            var artistName = singer.compactMap { $0["name"] as? String }.joined(separator: " / ")
            if artistName.isEmpty { artistName = item["singerName"] as? String ?? "" }
            albums.append(QQMusicAlbum(
                name: name, artistName: artistName, picURL: Self.photoURL(mid), mid: mid))
        }
        return albums
    }

    /// Generic QQ song parser (field names vary slightly per endpoint).
    private func song(from item: [String: Any]) -> QQMusicSong? {
        let mid = item["songmid"] as? String ?? (item["mid"] as? String ?? "")
        guard !mid.isEmpty else { return nil }
        let singers = (item["singer"] as? [[String: Any]]) ?? (item["songer"] as? [[String: Any]]) ?? []
        let artists = singers.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let albumDict = item["album"] as? [String: Any] ?? [:]
        let albumName = albumDict["name"] as? String ?? (item["albumname"] as? String ?? "")
        let albumMid = albumDict["mid"] as? String ?? (item["albummid"] as? String ?? "")
        let interval = item["interval"] as? Int ?? 0
        let file = item["file"] as? [String: Any]
        let mediaMid = file?["media_mid"] as? String
            ?? item["strMediaMid"] as? String
            ?? item["media_mid"] as? String
        return QQMusicSong(
            songmid: mid, mediaMid: mediaMid,
            title: item["songname"] as? String ?? (item["name"] as? String ?? ""),
            artistNames: artists, albumName: albumName,
            albumPicURL: Self.photoURL(albumMid.isEmpty ? nil : albumMid),
            durationMS: interval * 1000)
    }

    /// Songs of one playlist by its real ID, via the detail endpoint.
    private func playlistSongs(listID: Int, preferredCookie: String?, limit: Int) async throws -> [QQMusicSong] {
        if listID == Self.likedPlaylistID {
            return try await favoriteSongs(limit: limit)
        }
        let auth = await authSnapshot()
        let cookie = preferredCookie ?? (auth.isLoggedIn ? auth.playlistCookieHeader : "")
        let loginUins = (auth.isLoggedIn ? auth.playlistIdentityCandidates : ["0"])
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        for loginUin in loginUins {
            let detailURL = "https://c.y.qq.com/qzone/fcgi-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(listID)&loginUin=\(loginUin)&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
            if let detailJson = try? await get(detailURL, referer: "https://y.qq.com/n/yqq/playlist", cookie: cookie),
               let cdlist = detailJson["cdlist"] as? [[String: Any]],
               let songlist = cdlist.first?["songlist"] as? [[String: Any]],
               !songlist.isEmpty {
                let songs = songlist.prefix(limit).compactMap { item -> QQMusicSong? in
                    let raw = (item["track_info"] as? [String: Any]) ?? item
                    return song(from: raw)
                }
                if !songs.isEmpty { return songs }
            }
        }
        return []
    }

    /// Resolves the "我的喜欢" real playlist ID: the `dirid=201`
    /// endpoint, or `GetUserPlaylist` order 3.
    private func likedPlaylistID(auth: AuthSnapshot, cookies: [String]) async -> Int? {
        let favURL = "https://c.y.qq.com/splcloud/fcgi-bin/fcg_musiclist_getmyfav.fcg?dirid=201&dirinfo=1&g_tk=\(auth.gtk)&format=json&utf8=1"
        for cookie in cookies {
            guard let favJson = try? await get(favURL, referer: "https://y.qq.com/n/yqq/playlist", cookie: cookie) else { continue }
            if let id = Self.likedMapID(favJson), id > 0 { return id }
            let data = favJson["data"] as? [String: Any] ?? favJson
            if let first = (data["cdlist"] as? [[String: Any]])?.first {
                let id = Self.integerValue(first["dissid"] ?? first["diss_id"])
                if id > 0 { return id }
            }
        }

        for identity in auth.playlistIdentityCandidates {
            let numericUin = Int(identity) ?? 0
            let payload: [String: Any] = [
                "comm": [
                    "ct": 24,
                    "cv": 0,
                    "uin": numericUin,
                    "g_tk": auth.gtk,
                    "platform": "yqq",
                ],
                "req_1": [
                    "module": "music.musichallSong.PlayListDataServer",
                    "method": "GetUserPlaylist",
                    "param": [
                        "uin": numericUin,
                        "sin": 0,
                        "size": 100,
                        "order": 3,
                    ],
                ],
            ]
            for cookie in cookies {
                guard let json = try? await musicu(payload, cookie: cookie, timeout: 15) else { continue }
                for item in Self.playlistArray(from: json) {
                    let id = Self.integerValue(item["dissid"] ?? item["diss_id"] ?? item["tid"])
                    if id > 0 { return id }
                }
            }
        }
        return nil
    }

    // MARK: - Transport

    /// One snapshot of the login state, so a multi-request flow does not
    /// hop to the main actor for every field.
    private struct AuthSnapshot: Sendable {
        let isLoggedIn: Bool
        let uin: String
        let loginKey: String
        let gtk: Int
        let cookieHeader: String
        let playlistUin: String
        let playlistCookieHeader: String
        let playlistIdentityCandidates: [String]
    }

    private func authSnapshot() async -> AuthSnapshot {
        AuthSnapshot(
            isLoggedIn: await QQMusicAuth.shared.isLoggedIn,
            uin: await QQMusicAuth.shared.uin,
            loginKey: await QQMusicAuth.shared.loginKey,
            gtk: await QQMusicAuth.shared.gtk,
            cookieHeader: await QQMusicAuth.shared.cookieHeader,
            playlistUin: await QQMusicAuth.shared.playlistUin,
            playlistCookieHeader: await QQMusicAuth.shared.playlistCookieHeader,
            playlistIdentityCandidates: await QQMusicAuth.shared.playlistIdentityCandidates)
    }

    private func get(_ urlString: String, referer: String = "https://y.qq.com/", cookie: String = "") async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw QQMusicError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(cookie.isEmpty ? "uin=0; qqmusic_fromtag=66" : cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QQMusicError.invalidResponse }
        if http.statusCode == 401 {
            if !cookie.isEmpty { await QQMusicAuth.shared.sessionExpired() }
            throw QQMusicError.unauthorized
        }
        guard http.statusCode == 200 else { throw QQMusicError.httpStatus(http.statusCode) }
        guard let json = parseJSON(data) else { throw QQMusicError.invalidResponse }
        return json
    }

    /// `musicu.fcg` POST with a JSON body (the `wp_MusicApi` shape);
    /// logged-in callers attach their QQ cookies.
    private func musicu(_ payload: [String: Any], cookie: String = "", timeout: TimeInterval = 6) async throws -> [String: Any] {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: Self.musicuURLString) else {
            throw QQMusicError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // musicu occasionally hangs / gets filtered; search stays on a
        // short timeout, playlist sync may take longer.
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QQMusicError.invalidResponse }
        if http.statusCode == 401 {
            if !cookie.isEmpty { await QQMusicAuth.shared.sessionExpired() }
            throw QQMusicError.unauthorized
        }
        guard http.statusCode == 200 else { throw QQMusicError.httpStatus(http.statusCode) }
        guard let json = parseJSON(data) else { throw QQMusicError.invalidResponse }
        return json
    }

    /// Accepts plain JSON and JSONP (`callback({...})`); some legacy QQ
    /// endpoints also prefix a `while(1);` guard.
    private func parseJSON(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("while(1);") {
            text = String(text.dropFirst("while(1);".count))
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let slice = text[start...end]
        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
    }

    private func musicuSearchPayload(keyword: String, limit: Int, type: QQMusicSearchType) -> [String: Any] {
        [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": keyword,
                    "num_per_page": limit,
                    "page_num": 1,
                    "search_type": type.rawValue,
                    "grp": 1,
                ],
            ],
        ]
    }

    /// `search_for_qq_cp` search URL (works logged out; `t`: 0 songs /
    /// 8 albums).
    private func clientSearchURL(keyword: String, limit: Int, type: Int, page: Int = 1) -> URL? {
        var comps = URLComponents(string: Self.searchBase)
        comps?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "w", value: keyword),
            URLQueryItem(name: "n", value: "\(limit)"),
            URLQueryItem(name: "p", value: "\(max(page, 1))"),
            URLQueryItem(name: "t", value: "\(type)"),
        ]
        return comps?.url
    }

    // MARK: - Response helpers

    private static func photoURL(_ mid: String?, size: String = "300x300") -> URL? {
        guard let mid, !mid.isEmpty else { return nil }
        return URL(string: "https://y.gtimg.cn/music/photo_new/T002R\(size)M000\(mid).jpg")
    }

    /// Singer avatar (T001 singer template; the T002 album template
    /// 404s for singer mids, so singer search must use T001).
    private static func singerPhotoURL(_ mid: String?, size: String = "300x300") -> URL? {
        guard let mid, !mid.isEmpty else { return nil }
        return URL(string: "https://y.gtimg.cn/music/photo_new/T001R\(size)M000\(mid).jpg")
    }

    private static func normalizedQQImageURL(_ raw: Any?) -> URL? {
        guard var value = raw as? String else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = decodeJSONStringValue(value)
        if value.hasPrefix("data:image") { return nil }
        if value.hasPrefix("http://") {
            value = "https://" + String(value.dropFirst(7))
        } else if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("/") {
            value = "https://y.gtimg.cn" + value
        } else if !value.hasPrefix("https://") {
            value = "https://y.gtimg.cn/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return URL(string: value)
            ?? value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    /// A QQ playlist item, accepting legacy fcg and musicu
    /// `GetUserPlaylist` field names alike.
    private static func playlist(fromQQDiss item: [String: Any]) -> QQMusicUserPlaylist? {
        let rawName = item["diss_name"] as? String
            ?? (item["dissname"] as? String
                ?? (item["name"] as? String ?? (item["title"] as? String ?? "")))
        let dirid = integerValue(item["dirid"])
        let dissid = integerValue(item["dissid"] ?? item["diss_id"])
        let tid = integerValue(item["tid"])

        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if dirid == 201 || trimmedName == "我喜欢" || trimmedName == "我的喜欢" || trimmedName == "喜欢的音乐" {
            return QQMusicUserPlaylist(
                id: Self.likedPlaylistID,
                name: "我的喜欢",
                coverURL: URL(string: "https://y.gtimg.cn/mediastyle/global/img/cover_like.png"),
                trackCount: integerValue(item["song_cnt"] ?? item["songnum"] ?? item["total_song_num"])
            )
        }

        // A directory item with no real playlist ID would render as a
        // playlist that always opens empty.
        if dissid == 0 && tid == 0 && dirid > 0 { return nil }
        let id = dissid > 0 ? dissid : (tid > 0 ? tid : (dirid > 0 ? dirid : integerValue(item["id"])))
        guard id > 0, !trimmedName.isEmpty else { return nil }

        let coverURL = [
            "diss_cover", "dir_pic_url", "logo", "picurl", "pic_url",
            "cover", "cover_url", "headurl", "imgurl",
        ].lazy.compactMap { normalizedQQImageURL(item[$0]) }.first
        let count = integerValue(item["song_cnt"] ?? item["songnum"] ?? item["total_song_num"] ?? item["song_count"])
        return QQMusicUserPlaylist(id: id, name: trimmedName, coverURL: coverURL, trackCount: count)
    }

    /// `fcg_musiclist_getmyfav`'s map: a scalar, nested under `data`,
    /// or `{"201": <real playlist ID>}`.
    private static func likedMapID(_ json: [String: Any]) -> Int? {
        let data = json["data"] as? [String: Any] ?? [:]
        for value in [json["map"], json["mapid"], json["id"], data["map"], data["mapid"], data["id"]] {
            if let dict = value as? [String: Any] {
                let preferredID = integerValue(dict["201"])
                if preferredID > 0 { return preferredID }
                if let id = dict.values.lazy.map({ integerValue($0) }).first(where: { $0 > 0 }) { return id }
            } else {
                let id = integerValue(value)
                if id > 0 { return id }
            }
        }
        return nil
    }

    /// Recursively extracts the `songlist` / `songList` array a
    /// `fcg_musiclist_getmyfav` answer may carry.
    private static func favoriteSongArray(from json: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ value: Any) {
            guard result.isEmpty else { return }
            if let dict = value as? [String: Any] {
                for key in ["songlist", "songList", "song_list", "tracks", "tracklist"] {
                    if let list = dict[key] as? [[String: Any]], !list.isEmpty {
                        result = list
                        return
                    }
                }
                for child in dict.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
        return result
    }

    /// Liked-endpoint songs are sometimes wrapped in
    /// `songInfo` / `data` / `track_info`; unwrap to the song-field level.
    private static func unwrapQQSong(_ item: [String: Any]) -> [String: Any] {
        if item["songmid"] != nil || item["mid"] != nil || item["songname"] != nil {
            return item
        }
        for key in ["songInfo", "songinfo", "track_info", "trackInfo", "data", "song"] {
            if let nested = item[key] as? [String: Any] {
                let unwrapped = unwrapQQSong(nested)
                if unwrapped["songmid"] != nil || unwrapped["mid"] != nil || unwrapped["songname"] != nil {
                    return unwrapped
                }
            }
        }
        return item
    }

    /// `GetUserPlaylist`'s playlist array, across client-version
    /// nesting variants.
    private static func playlistArray(from json: [String: Any]) -> [[String: Any]] {
        let paths = [
            ["req_1", "data", "v_playlist"],
            ["req_1", "data", "playlist"],
            ["req_1", "data", "list"],
            ["req_1", "data", "data", "v_playlist"],
            ["req_1", "data", "body", "v_playlist"],
        ]
        for path in paths {
            var current: Any = json
            for key in path {
                guard let dict = current as? [String: Any], let next = dict[key] else {
                    current = NSNull()
                    break
                }
                current = next
            }
            if let list = current as? [[String: Any]], !list.isEmpty {
                return list
            }
        }

        var result: [[String: Any]] = []
        func walk(_ value: Any) {
            guard result.isEmpty else { return }
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if key == "v_playlist", let list = child as? [[String: Any]], !list.isEmpty {
                        result = list
                        return
                    }
                    walk(child)
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return result
    }

    private static func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func decodeJSONStringValue(_ value: String) -> String {
        let quoted = "\"\(value)\""
        guard let data = quoted.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? String else {
            return value
        }
        return decoded
    }

    private func nestedArray(_ json: [String: Any], path: [String]) -> [[String: Any]] {
        var current: Any = json
        for key in path {
            if let dict = current as? [String: Any] {
                current = dict[key] ?? [:]
            } else {
                return []
            }
        }
        return (current as? [[String: Any]]) ?? []
    }
}

/// QQ Music search type (`musicu` `search_type`).
private enum QQMusicSearchType: Int {
    case song = 0
    case artist = 1
    case album = 2
}
