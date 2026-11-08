import CommonCrypto
import CryptoKit
import Foundation
import os.log
import Security

/// A KuGou song from search. `hash` is the playback identity
/// (uppercase `FileHash` from the search payloads); `albumAudioId` /
/// `albumId` pin the album variant for the `/v5/url` ladder.
struct KugouMusicSong: Hashable, Sendable {
    let hash: String
    let albumAudioId: String?
    let albumId: String?
    let title: String
    let artistNames: [String]
    let albumName: String
    let albumPicURL: URL?
    let durationMS: Int
}

/// A KuGou artist from search.
struct KugouMusicArtist: Hashable, Sendable {
    let name: String
    let picURL: URL?
}

/// A KuGou album from search.
struct KugouMusicAlbum: Hashable, Sendable {
    let name: String
    let artistName: String
    let picURL: URL?
}

/// A KuGou user playlist (from `userPlaylists()`). Golia has no shared
/// playlist model for third-party sources, so this type lives here.
struct KugouMusicPlaylist: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let coverURL: URL?
    let trackCount: Int
}

/// Playback quality for `/v5/url`. Raw values are the quality strings
/// the endpoint expects (`flac` / `high` / `320` / `128`).
enum KugouAudioQuality: String, Sendable, CaseIterable {
    case standard = "128"
    case high = "320"
    case lossless = "flac"
    case hires = "high"

    /// Full ladder, best first: flac, high, 320, 128.
    static let ladder: [KugouAudioQuality] = [.lossless, .hires, .high, .standard]

    /// This quality first, then everything below it on the ladder.
    func degraded() -> [KugouAudioQuality] {
        guard let index = Self.ladder.firstIndex(of: self) else { return Self.ladder }
        return Array(Self.ladder[index...])
    }
}

enum KugouMusicAPIError: LocalizedError {
    case sessionExpired
    case network
    case invalidResponse
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "KuGou login has expired"
        case .network: return "KuGou request failed"
        case .invalidResponse: return "KuGou returned an unreadable response"
        case .invalidURL: return "KuGou request URL is invalid"
        }
    }
}

/// KuGou API, adapted from Beans' `KugouMusicAPI`, slimmed to what
/// Golia uses: QR login, user playlists, search, hot words, and
/// playback-URL resolution. No self-hosted backend anywhere: QR login
/// talks directly to `login-user.kugou.com`, search and playback talk
/// to KuGou's public gateways, and anonymous search/playback need no
/// login at all.
///
/// Expiry: HTTP 401/403 or a top-level `error_code`/`errcode` of 152
/// on an authenticated gateway call clears the session (via
/// `KugouMusicAuth.sessionExpired()`) and throws `.sessionExpired`.
/// Other errors — including backend 502s and anonymous-endpoint
/// failures — are never treated as expiry. Search degrades through
/// its tiers instead of surfacing expiry: an expired login answers
/// through the anonymous tiers while the session is cleared once.
///
/// Deliberately NOT ported from Beans: personalFM, everydayRecommend,
/// topLists, rankSongs, recommendPlaylists, comments, lyric (lyric is
/// PR #23's `KugouLyricProvider`), artist songs, playlist songs, and
/// the VIP membership probe.
final class KugouMusicAPI: @unchecked Sendable {
    static let shared = KugouMusicAPI()

    struct QRLogin: Equatable, Sendable {
        let key: String
        let url: String
    }

    /// QR poll state. KuGou uses its own codes, not NetEase's
    /// 800/801/802/803: 0 expired, 1 waiting, 2 or 3 scanned,
    /// 4 confirmed (or `data.token` appearing counts as confirmed).
    /// A confirmed poll saves the login via `KugouMusicAuth` before
    /// returning, so callers only see the state, never the token.
    enum QRState: Equatable, Sendable {
        case expired
        case waiting
        case scanned
        case confirmed
    }

    private let gateway = "https://gateway.kugou.com"
    private let loginBase = "https://login-user.kugou.com"
    private let userService = "https://userservice.kugou.com"

    // KuGouMusicApi request profile (Beans' upstream constants). These
    // identify public KuGou clients; they are not secrets.
    private let upstreamAppID = "1005"
    private let upstreamClientVersion = "20489"
    private let upstreamSignSalt = "OIlwieks28dk2k092lksi2UIkp"
    private let upstreamSongClientVersion = "11430"
    private let appid = "3116"
    private let clientver = "11440"
    private let qrAppid = "1001"
    private let qrSrcAppid = "2919"
    private let androidSignKey = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private let webSignKey = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
    private let playSalt = "kgcloudv2"
    private let playSignSalt = "57ae12eb6890223e355ccfcb74edf70d"
    private let playAppid = "1005"
    private let playClientver = "20489"
    private let androidUA = "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi"
    private let playbackUA = "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi"
    private let rsaPublicKeyBase64 =
        "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB"

    /// The signed anonymous search (Folia's `requestKugouAnonymousSearch`
    /// parameters): old public Android client identifiers.
    private static let anonymousSearchURL = "http://complexsearch.kugou.com/v2/search/song"
    private static let anonymousAppID = "3116"
    private static let anonymousClientVersion = "11070"
    private static let anonymousSignatureSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let anonymousSearchUA = "Android14-1070-11070-201-0-SearchSong-wifi"

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "kugou")

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    // MARK: - QR login

    func qrKey() async throws -> QRLogin {
        let auth = await KugouMusicAuth.shared
        await auth.prepareDevice()
        let qrcodeText = "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(appid)&"
        let response = try await gatewayRequest(
            "/v2/qrcode",
            baseURL: loginBase,
            signType: .web,
            params: [
                "appid": qrAppid,
                "type": "1",
                "plat": "4",
                "qrcode_txt": qrcodeText,
                "srcappid": qrSrcAppid,
            ],
            headers: [
                "User-Agent": Self.browserUA,
                "x-router": "login-user.kugou.com",
            ]
        )
        let key = Self.deepString(response.json, names: ["qrcode", "key"])
        guard !key.isEmpty else { throw KugouMusicAPIError.invalidResponse }
        return QRLogin(
            key: key,
            url: "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(Self.urlEncode(key))"
        )
    }

    func pollQR(key: String) async throws -> QRState {
        let response = try await gatewayRequest(
            "/v2/get_userinfo_qrcode",
            baseURL: loginBase,
            signType: .web,
            params: [
                "plat": "4",
                "appid": appid,
                "srcappid": qrSrcAppid,
                "qrcode": key,
            ],
            headers: [
                "User-Agent": Self.browserUA,
                "x-router": "login-user.kugou.com",
            ]
        )
        let json = response.json
        let status = Self.deepInt(json, names: ["status"])
        let token = Self.deepString(json, names: ["token", "user_token", "access_token", "key"])
        let userId = Self.deepString(
            json, names: ["userid", "user_id", "uid", "kugooid", "kugouid"]
        ).filter(\.isNumber)
        if !token.isEmpty, !userId.isEmpty {
            let nick = Self.deepString(
                json, names: ["nickname", "nick", "username", "user_name", "uname"])
            let avatar = Self.deepString(
                json, names: ["avatar", "pic", "img", "headpic", "user_pic", "userpic"])
            let vip = Self.deepInt(
                json, names: ["vip_type", "vipType", "viptype", "isvip", "is_vip", "vip"])
            let auth = await KugouMusicAuth.shared
            await auth.saveLogin(userId: userId, token: token, nickname: nick, avatar: avatar, vipType: vip)
            await registerDevice()
            return .confirmed
        }
        switch status {
        case 0:
            return .expired
        case 2, 3:
            return .scanned
        case 4:
            // Confirmed but no token arrived with this poll (the token
            // normally accompanies status 4, and the login is saved on
            // the token path above). The caller re-checks login state
            // before relying on the confirmation.
            return .confirmed
        default:
            return .waiting
        }
    }

    // MARK: - User playlists

    func userPlaylists() async throws -> [KugouMusicPlaylist] {
        let snapshot = await authSnapshot()
        guard snapshot.isLoggedIn else { return [] }
        let dataBody: [String: Any] = [
            "total_ver": 979,
            "type": 2,
            "page": 1,
            "pagesize": 200,
            "userid": Int(snapshot.userID) ?? 0,
            "token": snapshot.token,
        ]
        let response = try await gatewayRequest(
            "/v7/get_all_list",
            method: "POST",
            params: [
                "total_ver": "979",
                "type": "2",
                "page": "1",
                "pagesize": "200",
                "userid": snapshot.userID,
                "token": snapshot.token,
            ],
            data: dataBody,
            headers: ["x-router": "cloudlist.service.kugou.com"]
        )
        let raw = Self.deepArrays(
            response.json,
            names: ["lists", "list", "info", "data", "listinfo", "collection_list", "playlist"])
        var seen = Set<Int>()
        return raw.compactMap { item -> KugouMusicPlaylist? in
            guard let playlist = Self.mapPlaylist(item), !seen.contains(playlist.id) else {
                return nil
            }
            seen.insert(playlist.id)
            return playlist
        }
    }

    // MARK: - Search

    /// Three tiers, best data first, all anonymous-capable:
    /// 1. KuGouMusicApi v3 song search (gateway, signed);
    /// 2. the signed anonymous search (`complexsearch` v2, appid 3116 /
    ///    clientver 11070 / AndroidFilter);
    /// 3. the public web search (`song_search_v2`).
    /// A tier that throws (including an expired login, which clears
    /// the session as a side effect) falls through to the next tier.
    /// Returns [] when every tier is empty.
    func searchSongs(keyword: String, limit: Int = 30) async throws -> [KugouMusicSong] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let target = min(max(limit, 1), 100)
        if let upstream = try? await upstreamSearchSongs(keyword: trimmed, limit: target),
           !upstream.isEmpty {
            return upstream
        }
        if let anonymous = try? await anonymousSearchSongs(keyword: trimmed, limit: target),
           !anonymous.isEmpty {
            return anonymous
        }
        if let web = try? await webSearchSongs(keyword: trimmed, limit: target),
           !web.isEmpty {
            return web
        }
        return []
    }

    private func upstreamSearchSongs(keyword: String, limit: Int) async throws -> [KugouMusicSong] {
        let pageSize = min(max(limit, 1), 30)
        // The endpoint commonly returns 15 rows even when pagesize is
        // 30; page on so artist pages do not stop at the first 15.
        let pageCount = max(1, min(4, Int(ceil(Double(max(limit, 1)) / 15.0)) + 1))
        var result: [KugouMusicSong] = []
        var seen = Set<String>()
        for page in 1...pageCount {
            let response = try await upstreamRequest(
                "/v3/search/song",
                params: [
                    "albumhide": "0",
                    "iscorrection": "1",
                    "keyword": keyword,
                    "nocollect": "0",
                    "page": "\(page)",
                    "pagesize": "\(pageSize)",
                    "platform": "AndroidFilter",
                ],
                headers: ["x-router": "complexsearch.kugou.com"]
            )
            let rows = Self.deepArrays(
                response.json, names: ["info", "songs", "song", "list", "data"])
            let batch = rows.compactMap(Self.mapSong)
            if batch.isEmpty { break }
            let before = result.count
            for song in batch where seen.insert(Self.dedupKey(for: song)).inserted {
                result.append(song)
                if result.count >= limit { return Array(result.prefix(limit)) }
            }
            if result.count == before { break }
        }
        return result
    }

    /// Folia's `requestKugouAnonymousSearch`: `signature = md5(salt +
    /// key-sorted "key=value" concatenation + salt)`,
    /// `mid = md5(current millisecond timestamp)`. Needs no login and
    /// no backend.
    private func anonymousSearchSongs(keyword: String, limit: Int) async throws -> [KugouMusicSong] {
        let clientTimeMs = Int(Date().timeIntervalSince1970 * 1_000)
        let clientTimeSec = clientTimeMs / 1_000
        let mid = Self.md5Hex(String(clientTimeMs))
        var params: [String: String] = [
            "sorttype": "0",
            "keyword": keyword,
            "pagesize": String(min(max(limit, 1), 30)),
            "page": "1",
            "userid": "0",
            "appid": Self.anonymousAppID,
            "token": "",
            "clienttime": String(clientTimeSec),
            "iscorrection": "1",
            "uuid": "-",
            "mid": mid,
            "dfid": "-",
            "clientver": Self.anonymousClientVersion,
            "platform": "AndroidFilter",
        ]
        let signatureSource = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        params["signature"] = Self.md5Hex(
            "\(Self.anonymousSignatureSalt)\(signatureSource)\(Self.anonymousSignatureSalt)")

        var components = URLComponents(string: Self.anonymousSearchURL)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw KugouMusicAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.anonymousSearchUA, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "KG-Rec")
        request.setValue("1", forHTTPHeaderField: "KG-RC")
        request.setValue(String(clientTimeMs), forHTTPHeaderField: "KG-CLIENTTIMEMS")
        request.setValue(mid, forHTTPHeaderField: "mid")
        request.setValue("complexsearch.kugou.com", forHTTPHeaderField: "x-router")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw KugouMusicAPIError.network }
        let errorCode = Self.deepInt(json, names: ["error_code", "errcode"])
        guard errorCode == 0 || errorCode == 200 else {
            throw KugouMusicAPIError.invalidResponse
        }
        return Self.deepArrays(json, names: ["info", "songs", "song", "list", "data"])
            .compactMap(Self.mapSong)
    }

    private func webSearchSongs(keyword: String, limit: Int) async throws -> [KugouMusicSong] {
        var components = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "\(min(max(limit, 1), 100))"),
        ]
        guard let url = components.url else { throw KugouMusicAPIError.invalidURL }
        let json = try await getJSON(url, ua: Self.browserUA)
        let raw = Self.deepArrays(json, names: ["info", "songs", "song", "list", "data"])
        return raw.compactMap(Self.mapSong)
    }

    /// Official author search first; when it is empty, aggregate
    /// artists from song search (name + song cover).
    func searchArtists(keyword: String, limit: Int = 40) async throws -> [KugouMusicArtist] {
        let target = min(max(limit, 1), 100)
        if let artists = try? await upstreamSearchArtists(keyword: keyword, limit: target),
           !artists.isEmpty {
            return artists
        }
        let songs = try await searchSongs(keyword: keyword, limit: target)
        var result: [KugouMusicArtist] = []
        var seen = Set<String>()
        for song in songs {
            for name in song.artistNames {
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                result.append(KugouMusicArtist(name: name, picURL: song.albumPicURL))
                if result.count >= target { return result }
            }
        }
        return result
    }

    private func upstreamSearchArtists(keyword: String, limit: Int) async throws -> [KugouMusicArtist] {
        let pageSize = min(max(limit, 1), 30)
        let response = try await upstreamRequest(
            "/v1/search/author",
            params: [
                "albumhide": "0",
                "iscorrection": "1",
                "keyword": keyword,
                "nocollect": "0",
                "page": "1",
                "pagesize": "\(pageSize)",
                "platform": "AndroidFilter",
            ],
            headers: ["x-router": "complexsearch.kugou.com"]
        )
        let rows = Self.deepArrays(
            response.json, names: ["info", "authors", "artists", "author", "list", "data"])
        var result: [KugouMusicArtist] = []
        var seen = Set<String>()
        for item in rows {
            let name = Self.clean(
                Self.string(
                    item["author_name"] ?? item["authorname"] ?? item["singername"] ?? item["name"]))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            let cover = Self.normalizeURL(
                Self.string(
                    item["avatar"] ?? item["pic"] ?? item["imgurl"] ?? item["img_url"] ?? item["author_pic"]
                ).replacingOccurrences(of: "{size}", with: "400"))
            result.append(
                KugouMusicArtist(name: name, coverURL: cover.isEmpty ? nil : URL(string: cover)))
            if result.count >= limit { return result }
        }
        return result
    }

    /// Albums aggregated from song search (deduped by album + artist).
    func searchAlbums(keyword: String, limit: Int = 40) async throws -> [KugouMusicAlbum] {
        let target = min(max(limit, 1), 100)
        let songs = try await searchSongs(keyword: keyword, limit: target)
        var result: [KugouMusicAlbum] = []
        var seen = Set<String>()
        for song in songs where !song.albumName.isEmpty {
            let artistName = song.artistNames.joined(separator: " / ")
            let key = "\(song.albumName)|\(artistName)"
            guard seen.insert(key).inserted else { continue }
            result.append(
                KugouMusicAlbum(name: song.albumName, artistName: artistName, picURL: song.albumPicURL))
            if result.count >= target { return result }
        }
        return result
    }

    /// KuGou has no stable public hot-search JSON contract; use a
    /// fixed word list (Beans) so the search page never shows another
    /// platform's hot words after switching to KuGou.
    func hotWords() async -> [String] {
        [
            "周杰伦", "林俊杰", "陈奕迅", "薛之谦", "邓紫棋",
            "凤凰传奇", "五月天", "毛不易", "告五人", "热门歌曲",
        ]
    }

    // MARK: - Playback URLs

    /// Resolves a playback URL for a searched song. `quality` pins the
    /// first rung; the ladder below it is still tried (`flac` → `high`
    /// → `320` → `128`). `nil` quality tries the full ladder.
    func songURL(song: KugouMusicSong, quality: KugouAudioQuality? = nil) async throws -> URL? {
        try await songURL(
            hash: song.hash, albumAudioId: song.albumAudioId, albumId: song.albumId,
            quality: quality)
    }

    /// Resolves a playback URL straight from a hash (plus optional
    /// album ids), down the full quality ladder, then the public
    /// mobile endpoint. No search, no login required.
    func songURL(hash: String, albumAudioId: String?, albumId: String?) async throws -> URL? {
        try await songURL(
            hash: hash, albumAudioId: albumAudioId, albumId: albumId, quality: nil)
    }

    private func songURL(
        hash: String, albumAudioId: String?, albumId: String?, quality: KugouAudioQuality?
    ) async throws -> URL? {
        let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let qualities = quality.map { $0.degraded() } ?? KugouAudioQuality.ladder
        let snapshot = await authSnapshot()
        let vipTypes = Self.vipTypeCandidates(snapshot.vipType, loggedIn: snapshot.isLoggedIn)
        for rung in qualities {
            // KuGouMusicApi v5/url (gateway, signed upstream params).
            if let url = try await attempt({
                try await self.upstreamSongURLOnce(
                    hash: trimmed, albumAudioId: albumAudioId, albumId: albumId,
                    quality: rung, snapshot: snapshot)
            }) { return url }
            // Legacy tracker endpoint, one pass per VIP type.
            for vipType in vipTypes {
                if let url = try await attempt({
                    try await self.songURLOnce(
                        hash: trimmed, albumAudioId: albumAudioId, albumId: albumId,
                        vipType: vipType, snapshot: snapshot)
                }) { return url }
            }
            // Official v5/url with explicit params, one pass per VIP type.
            for vipType in vipTypes {
                if let url = try await attempt({
                    try await self.songURLV5Once(
                        hash: trimmed, albumAudioId: albumAudioId, albumId: albumId,
                        vipType: vipType, quality: rung, snapshot: snapshot)
                }) { return url }
            }
            // Web playback channel.
            if let url = try await attempt({
                try await self.songURLWebOnce(
                    hash: trimmed, albumAudioId: albumAudioId, albumId: albumId,
                    snapshot: snapshot)
            }) { return url }
        }
        // Public mobile endpoint, last resort.
        let legacy = try await attempt { try await self.legacyPlayInfoURL(hash: trimmed) }
        if legacy == nil {
            Self.log.info("kugou no playback url for hash prefix=\(trimmed.prefix(8), privacy: .public)")
        }
        return legacy
    }

    /// Runs one URL attempt. Ordinary failures fall through to the
    /// next rung; a dead session is rethrown (the session is already
    /// cleared by then).
    private func attempt(_ operation: () async throws -> URL?) async throws -> URL? {
        do {
            return try await operation()
        } catch KugouMusicAPIError.sessionExpired {
            throw error
        } catch {
            return nil
        }
    }

    /// KuGouMusicApi `v5/url` with the signed upstream parameter set.
    private func upstreamSongURLOnce(
        hash: String, albumAudioId: String?, albumId: String?,
        quality: KugouAudioQuality, snapshot: AuthSnapshot
    ) async throws -> URL? {
        let fileHash = hash.lowercased()
        var params = upstreamBaseParams(snapshot: snapshot)
        params["album_id"] = albumId ?? "0"
        params["area_code"] = "1"
        params["hash"] = fileHash
        params["ssa_flag"] = "is_fromtrack"
        params["version"] = upstreamSongClientVersion
        params["quality"] = quality.rawValue
        params["behavior"] = "play"
        params["pid"] = "2"
        params["pidversion"] = "3001"
        params["cmd"] = "26"
        params["page_id"] = "151369488"
        params["ppage_id"] = "463467626,350369493,788954147"
        params["cdnBackup"] = "1"
        params["module"] = ""
        params["clientver"] = upstreamSongClientVersion
        params["key"] = Self.md5Hex(
            "\(fileHash)\(playSignSalt)\(upstreamAppID)\(snapshot.mid)\(snapshot.userID.isEmpty ? "0" : snapshot.userID)")
        if let albumAudioId, !albumAudioId.isEmpty {
            params["album_audio_id"] = albumAudioId
        }
        let response = try await request(
            "/v5/url",
            baseURL: gateway,
            method: "GET",
            params: params,
            body: nil,
            headers: upstreamHeaders(
                snapshot: snapshot,
                extra: [
                    "x-router": "trackercdn.kugou.com",
                    "dfid": snapshot.dfid,
                    "mid": snapshot.mid,
                    "Cookie": snapshot.cookieHeader,
                ])
        )
        return Self.playbackURL(from: response.json)
    }

    /// Legacy tracker endpoint `trackercdn.kugou.com/i/v2/`.
    private func songURLOnce(
        hash: String, albumAudioId: String?, albumId: String?,
        vipType: Int, snapshot: AuthSnapshot
    ) async throws -> URL? {
        let h = hash.uppercased()
        var components = URLComponents(string: "https://trackercdn.kugou.com/i/v2/")!
        var params: [String: String] = [
            "cmd": "26",
            "hash": h,
            "behavior": "play",
            "appid": appid,
            "pid": "2",
            "mid": snapshot.mid,
            "userid": snapshot.userID.isEmpty ? "0" : snapshot.userID,
            "version": clientver,
            "vipType": "\(vipType)",
            "token": snapshot.token.isEmpty ? "0" : snapshot.token,
            "key": Self.md5Hex(
                "\(h)\(playSalt)\(appid)\(snapshot.mid)\(snapshot.userID.isEmpty ? "0" : snapshot.userID)"),
        ]
        if let albumAudioId, !albumAudioId.isEmpty { params["album_audio_id"] = albumAudioId }
        if let albumId, !albumId.isEmpty { params["album_id"] = albumId }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw KugouMusicAPIError.invalidURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(androidUA, forHTTPHeaderField: "User-Agent")
        if !snapshot.cookieHeader.isEmpty {
            urlRequest.setValue(snapshot.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KugouMusicAPIError.network
        }
        try await checkSessionExpiry(statusCode: http.statusCode)
        guard http.statusCode == 200 else { return nil }
        var text = String(data: data, encoding: .utf8) ?? ""
        text = text.replacingOccurrences(of: "<!--KG_TAG_RES_START-->", with: "")
            .replacingOccurrences(of: "<!--KG_TAG_RES_END-->", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return Self.playbackURL(from: json)
    }

    /// Official `v5/url` with explicit parameters (Beans'
    /// `songURLV5Once`). Note the quality spelling here differs from
    /// the upstream variant: hires is `hires`, not `high`.
    private func songURLV5Once(
        hash: String, albumAudioId: String?, albumId: String?,
        vipType: Int, quality: KugouAudioQuality, snapshot: AuthSnapshot
    ) async throws -> URL? {
        var components = URLComponents(string: "\(gateway)/v5/url")!
        let qualityString: String
        switch quality {
        case .standard: qualityString = "128"
        case .high: qualityString = "320"
        case .lossless: qualityString = "flac"
        case .hires: qualityString = "hires"
        }
        let userId = snapshot.userID.isEmpty ? "0" : snapshot.userID
        let fileHash = hash.lowercased()
        var params: [String: String] = [
            "album_id": albumId ?? "0",
            "area_code": "1",
            "hash": fileHash,
            "ssa_flag": "is_fromtrack",
            "version": "11430",
            "quality": qualityString,
            "behavior": "play",
            "pid": "2",
            "pidversion": "3001",
            "cmd": "26",
            "appid": playAppid,
            "page_id": "151369488",
            "ppage_id": "463467626,350369493,788954147",
            "cdnBackup": "1",
            "module": "",
            "clientver": playClientver,
            "dfid": snapshot.dfid,
            "mid": snapshot.mid,
            "userid": userId,
            "token": snapshot.token,
            "vipType": "\(vipType)",
            "IsFreePart": vipType > 0 ? "0" : "1",
            "key": Self.md5Hex("\(fileHash)\(playSignSalt)\(playAppid)\(snapshot.mid)\(userId)"),
        ]
        if let albumAudioId, !albumAudioId.isEmpty {
            params["album_audio_id"] = albumAudioId
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw KugouMusicAPIError.invalidURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(playbackUA, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("trackercdn.kugou.com", forHTTPHeaderField: "x-router")
        urlRequest.setValue(snapshot.dfid, forHTTPHeaderField: "dfid")
        urlRequest.setValue(snapshot.mid, forHTTPHeaderField: "mid")
        if !snapshot.cookieHeader.isEmpty {
            urlRequest.setValue(snapshot.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KugouMusicAPIError.network
        }
        try await checkSessionExpiry(statusCode: http.statusCode)
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.playbackURL(from: json)
    }

    /// Web playback channel. Some accounts get an authorized URL here
    /// when the mobile tracker answers 20006.
    private func songURLWebOnce(
        hash: String, albumAudioId: String?, albumId: String?, snapshot: AuthSnapshot
    ) async throws -> URL? {
        var components = URLComponents(string: "https://wwwapi.kugou.com/yy/index.php")!
        var params: [String: String] = [
            "r": "play/getdata",
            "hash": hash.uppercased(),
            "appid": "1014",
            "platid": "4",
            "mid": snapshot.mid,
            "dfid": snapshot.dfid,
            "userid": snapshot.userID.isEmpty ? "0" : snapshot.userID,
            "token": snapshot.token,
        ]
        if let albumId, !albumId.isEmpty { params["album_id"] = albumId }
        if let albumAudioId, !albumAudioId.isEmpty { params["album_audio_id"] = albumAudioId }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw KugouMusicAPIError.invalidURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        if !snapshot.cookieHeader.isEmpty {
            urlRequest.setValue(snapshot.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KugouMusicAPIError.network
        }
        try await checkSessionExpiry(statusCode: http.statusCode)
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.playbackURL(from: json)
    }

    /// `https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=…`,
    /// Folia's `requestKugouLegacyPlayInfo`. Public, needs no backend
    /// and no login. Prefers `url` over `backup_url`, top-level then
    /// under `data`.
    private func legacyPlayInfoURL(hash: String) async throws -> URL? {
        var components = URLComponents(string: "https://m.kugou.com/app/i/getSongInfo.php")
        components?.queryItems = [
            URLQueryItem(name: "cmd", value: "playInfo"),
            URLQueryItem(name: "hash", value: hash),
        ]
        guard let url = components?.url else { throw KugouMusicAPIError.invalidURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let dataObject = (json["data"] as? [String: Any]) ?? [:]
        let candidates = [
            Self.string(json["url"]),
            Self.string(dataObject["url"]),
            Self.string(json["backup_url"]),
            Self.string(dataObject["backup_url"]),
        ]
        for candidate in candidates where !candidate.isEmpty {
            for part in candidate.split(separator: ",").map(String.init) {
                if let url = Self.validPlaybackURL(part) { return url }
            }
        }
        return nil
    }

    // MARK: - Device registration

    /// Registers this device with KuGou (`/risk/v2/r_register_dev`)
    /// and stores the returned `dfid`. Never throws: a failed
    /// registration leaves the previous dfid in place and playback /
    /// search keep working anonymously. Called after a confirmed QR
    /// login.
    private func registerDevice() async {
        let snapshot = await authSnapshot()
        let guid = snapshot.guid.isEmpty ? UUID().uuidString : snapshot.guid
        let dataMap: [String: Any] = [
            "availableRamSize": 4983533568,
            "availableRomSize": 48114719,
            "availableSDSize": 48114717,
            "basebandVer": "",
            "batteryLevel": 100,
            "batteryStatus": 3,
            "brand": "Redmi",
            "buildSerial": "unknown",
            "device": "marble",
            "imei": guid,
            "imsi": "",
            "manufacturer": "Xiaomi",
            "uuid": guid,
            "accelerometer": false,
            "gyroscope": false,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dataMap),
              let aes = Self.randomLower(6),
              let encrypted = Self.aesCBCEncrypt(jsonData, password: aes),
              let pData = try? JSONSerialization.data(withJSONObject: [
                  "aes": aes, "uid": Int(snapshot.userID) ?? 0, "token": snapshot.token,
              ]),
              let rsa = Self.rsaEncryptPKCS1(pData, publicKeyBase64: rsaPublicKeyBase64)
        else { return }
        do {
            let response = try await gatewayRequest(
                "/risk/v2/r_register_dev",
                baseURL: userService,
                method: "POST",
                params: ["part": "1", "platid": "1", "p": Self.hexString(rsa)],
                dataRaw: encrypted,
                headers: [
                    "x-router": "userservice.kugou.com",
                    "Content-Type": "application/octet-stream",
                ]
            )
            var json: [String: Any]?
            if let parsed = try? JSONSerialization.jsonObject(with: response.rawData) as? [String: Any] {
                json = parsed
            } else if let decrypted = Self.aesCBCDecrypt(response.rawData, password: aes),
                      let parsed = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] {
                json = parsed
            }
            let dfid = Self.deepString(json ?? [:], names: ["dfid"])
            if !dfid.isEmpty {
                let auth = await KugouMusicAuth.shared
                await auth.saveDeviceDFID(dfid)
                Self.log.info("kugou device registered; dfid received")
            }
        } catch {
            Self.log.error(
                "kugou device registration failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Request plumbing

    private enum SignType { case android, web }
    private struct RawResponse { let json: [String: Any]; let rawData: Data }

    /// One frozen copy of the auth state per call chain, so a request
    /// never mixes a pre- and post-login token mid-flight.
    private struct AuthSnapshot {
        let userID: String
        let token: String
        let dfid: String
        let mid: String
        let guid: String
        let vipType: Int
        let isLoggedIn: Bool
        let cookieHeader: String
    }

    private func authSnapshot() async -> AuthSnapshot {
        let auth = await KugouMusicAuth.shared
        return AuthSnapshot(
            userID: await auth.userID,
            token: await auth.token,
            dfid: await auth.dfid,
            mid: await auth.mid,
            guid: await auth.guid,
            vipType: await auth.vipType,
            isLoggedIn: await auth.isLoggedIn,
            cookieHeader: await auth.cookieHeader
        )
    }

    /// Authenticated gateway calls only: a 401/403 clears the session
    /// and throws `.sessionExpired`. Anonymous endpoints (anonymous
    /// search, web search, `m.kugou.com`) never call this.
    private func checkSessionExpiry(statusCode: Int) async throws {
        if statusCode == 401 || statusCode == 403 {
            let auth = await KugouMusicAuth.shared
            await auth.sessionExpired()
            throw KugouMusicAPIError.sessionExpired
        }
    }

    private func request(
        _ path: String, baseURL: String, method: String = "GET",
        params: [String: String] = [:], body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> RawResponse {
        guard var comps = URLComponents(string: baseURL + path) else {
            throw KugouMusicAPIError.invalidURL
        }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw KugouMusicAPIError.invalidURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = body
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KugouMusicAPIError.network
        }
        try await checkSessionExpiry(statusCode: http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            throw KugouMusicAPIError.network
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if Self.topLevelErrorCode(json) == 152 {
            let auth = await KugouMusicAuth.shared
            await auth.sessionExpired()
            throw KugouMusicAPIError.sessionExpired
        }
        return RawResponse(json: json, rawData: data)
    }

    private func gatewayRequest(
        _ path: String, baseURL: String? = nil, method: String = "GET",
        signType: SignType = .android, params: [String: String] = [:],
        data: [String: Any]? = nil, dataRaw: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> RawResponse {
        let snapshot = await authSnapshot()
        var final = baseParams(snapshot: snapshot)
        params.forEach { final[$0.key] = $0.value }
        let body = try data.map { try JSONSerialization.data(withJSONObject: $0) } ?? dataRaw
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        final["signature"] =
            signType == .web ? webSignature(params: final) : androidSignature(params: final, data: bodyString)
        var requestHeaders = [
            "User-Agent": androidUA,
            "kg-rc": "1",
            "kg-thash": "5d816a0",
            "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "dfid": snapshot.dfid,
            "mid": snapshot.mid,
            "clienttime": final["clienttime"] ?? "",
        ]
        if !snapshot.cookieHeader.isEmpty { requestHeaders["Cookie"] = snapshot.cookieHeader }
        headers.forEach { requestHeaders[$0.key] = $0.value }
        return try await request(
            path, baseURL: baseURL ?? gateway, method: method, params: final, body: body,
            headers: requestHeaders)
    }

    /// KuGouMusicApi's standard request wrapper (appid 1005 profile).
    /// Kept separate from `gatewayRequest` so the two client profiles
    /// never overwrite each other.
    private func upstreamRequest(
        _ path: String, method: String = "GET",
        params: [String: String] = [:], data: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) async throws -> RawResponse {
        let snapshot = await authSnapshot()
        let body = try data.map { try JSONSerialization.data(withJSONObject: $0) }
        var final = upstreamBaseParams(snapshot: snapshot)
        params.forEach { final[$0.key] = $0.value }
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        final["signature"] = upstreamAndroidSignature(params: final, data: bodyString)
        var requestHeaders = upstreamHeaders(snapshot: snapshot, extra: headers)
        if body != nil, requestHeaders["Content-Type"] == nil {
            requestHeaders["Content-Type"] = "application/json"
        }
        return try await request(
            path, baseURL: gateway, method: method, params: final, body: body,
            headers: requestHeaders)
    }

    private func baseParams(snapshot: AuthSnapshot) -> [String: String] {
        var p: [String: String] = [
            "dfid": snapshot.dfid,
            "mid": snapshot.mid,
            "uuid": "-",
            "appid": appid,
            "clientver": clientver,
            "clienttime": "\(Int(Date().timeIntervalSince1970))",
        ]
        if snapshot.isLoggedIn {
            p["token"] = snapshot.token
            p["userid"] = snapshot.userID
        }
        return p
    }

    private func upstreamBaseParams(snapshot: AuthSnapshot) -> [String: String] {
        var p: [String: String] = [
            "dfid": snapshot.dfid,
            "mid": snapshot.mid,
            "uuid": "-",
            "appid": upstreamAppID,
            "clientver": upstreamClientVersion,
            "clienttime": "\(Int(Date().timeIntervalSince1970))",
        ]
        if snapshot.isLoggedIn {
            p["token"] = snapshot.token
            p["userid"] = snapshot.userID
        }
        return p
    }

    private func upstreamParamsKey(_ value: String) -> String {
        Self.md5Hex("\(upstreamAppID)\(upstreamSignSalt)\(upstreamClientVersion)\(value)")
    }

    private func upstreamHeaders(snapshot: AuthSnapshot, extra: [String: String] = [:]) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": androidUA,
            "kg-rc": "1",
            "kg-thash": "5d816a0",
            "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "dfid": snapshot.dfid,
            "mid": snapshot.mid,
        ]
        if !snapshot.cookieHeader.isEmpty {
            headers["Cookie"] = snapshot.cookieHeader
        }
        extra.forEach { headers[$0.key] = $0.value }
        return headers
    }

    private func androidSignature(params: [String: String], data: String) -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return Self.md5Hex("\(androidSignKey)\(body)\(data)\(androidSignKey)")
    }

    private func upstreamAndroidSignature(params: [String: String], data: String) -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return Self.md5Hex("\(upstreamSignSalt)\(body)\(data)\(upstreamSignSalt)")
    }

    private func webSignature(params: [String: String]) -> String {
        let body = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        return Self.md5Hex("\(webSignKey)\(body)\(webSignKey)")
    }

    /// Plain JSON GET for the anonymous web endpoints. No session
    /// involved, so no expiry handling here.
    private func getJSON(_ url: URL, ua: String, headers: [String: String] = [:]) async throws -> [String: Any] {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(ua, forHTTPHeaderField: "User-Agent")
        headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw KugouMusicAPIError.network }
        return obj
    }

    // MARK: - Mapping

    private static func mapSong(_ raw: [String: Any]) -> KugouMusicSong? {
        var normalized = raw
        if normalized["singername"] == nil,
           let authors = raw["authors"] as? [[String: Any]] {
            let names = authors.compactMap { author -> String? in
                let name = string(author["author_name"] ?? author["name"])
                return name.isEmpty ? nil : name
            }
            if !names.isEmpty { normalized["singername"] = names.joined(separator: " / ") }
        }
        normalized["songname"] = raw["SongName"] ?? raw["FileName"] ?? raw["songname"]
        normalized["filename"] = raw["FileName"] ?? raw["SongName"] ?? raw["filename"]
        normalized["singername"] = raw["SingerName"] ?? raw["singername"] ?? normalized["singername"]
        normalized["album_name"] = raw["AlbumName"] ?? raw["album_name"]
        normalized["hash"] = raw["FileHash"] ?? raw["Hash"] ?? raw["hash"]
        normalized["mixsongid"] = raw["MixSongID"] ?? raw["mixsongid"] ?? raw["audio_id"] ?? raw["audioid"] ?? raw["encrypt_id"]
        normalized["audio_id"] = raw["audio_id"] ?? raw["audioid"] ?? raw["encrypt_id"]
        normalized["album_id"] = raw["AlbumID"] ?? raw["album_id"]
        normalized["duration"] = raw["Duration"] ?? raw["duration"] ?? raw["timeLen"] ?? raw["timelength"]
        normalized["album_sizable_cover"] = raw["Image"] ?? raw["ImageUrl"] ?? raw["AlbumImg"] ?? raw["album_sizable_cover"]

        let trans = raw["trans_param"] as? [String: Any] ?? raw["transParam"] as? [String: Any] ?? [:]
        let hash = string(normalized["hash"])
        let albumAudioId = string(
            normalized["album_audio_id"] ?? normalized["albumAudioId"] ?? normalized["audio_id"]
                ?? normalized["mixsongid"] ?? normalized["songid"] ?? normalized["id"])
        var title = clean(string(normalized["songname"] ?? normalized["song_name"] ?? normalized["name"] ?? normalized["title"]))
        var artist = clean(string(normalized["singername"] ?? normalized["singer_name"] ?? normalized["author_name"] ?? normalized["singer"] ?? normalized["artist"]))
        let filename = clean(string(normalized["filename"] ?? normalized["FileName"]))
        if !filename.isEmpty {
            let parts = filename.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = clean(parts[0]) }
                if title.isEmpty || title == filename {
                    title = clean(parts.dropFirst().joined(separator: " - "))
                }
            } else if title.isEmpty {
                title = filename
            }
        }
        guard !title.isEmpty, !hash.isEmpty || !albumAudioId.isEmpty else { return nil }
        let album = string(
            normalized["album_name"] ?? normalized["albumname"] ?? normalized["album"]
                ?? (normalized["albuminfo"] as? [String: Any])?["name"])
        let cover = normalizeURL(
            string(
                normalized["pic"] ?? normalized["img"] ?? normalized["image"] ?? normalized["cover"]
                    ?? normalized["album_sizable_cover"] ?? normalized["sizable_cover"] ?? trans["union_cover"]
            ).replacingOccurrences(of: "{size}", with: "300"))
        // Duration arrives as seconds (< 10000 in the anonymous
        // payloads) or milliseconds; normalize to milliseconds.
        let durRaw = double(
            normalized["timelength"] ?? normalized["time_length"] ?? normalized["timelen"]
                ?? normalized["duration"] ?? normalized["interval"])
        let seconds = durRaw > 1000 ? durRaw / 1000.0 : durRaw
        let artistNames = artist
            .split(whereSeparator: { "/&、,，;；".contains($0) })
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
        return KugouMusicSong(
            hash: hash,
            albumAudioId: albumAudioId.isEmpty ? nil : albumAudioId,
            albumId: {
                let id = string(normalized["album_id"] ?? normalized["albumid"] ?? normalized["AlbumID"] ?? normalized["albumId"])
                return id.isEmpty ? nil : id
            }(),
            title: title,
            artistNames: artistNames,
            albumName: album,
            albumPicURL: cover.isEmpty ? nil : URL(string: cover),
            durationMS: Int(seconds * 1000)
        )
    }

    private static func mapPlaylist(_ raw: [String: Any]) -> KugouMusicPlaylist? {
        let id = int(raw["listid"] ?? raw["id"] ?? raw["global_collection_id"] ?? raw["specialid"])
        guard id > 0 else { return nil }
        let name = string(
            raw["name"] ?? raw["listname"] ?? raw["list_name"] ?? raw["specialname"] ?? raw["title"])
        let cover = string(raw["pic"] ?? raw["img"] ?? raw["cover"] ?? raw["sizable_cover"] ?? raw["list_pic"])
            .replacingOccurrences(of: "{size}", with: "240")
        let count = int(raw["count"] ?? raw["song_count"] ?? raw["total"] ?? raw["file_count"] ?? raw["songcount"])
        return KugouMusicPlaylist(
            id: id,
            name: name.isEmpty ? "酷狗歌单" : name,
            coverURL: cover.isEmpty ? nil : URL(string: cover),
            trackCount: count
        )
    }

    private static func dedupKey(for song: KugouMusicSong) -> String {
        if !song.hash.isEmpty { return "hash:\(song.hash.lowercased())" }
        if let audioId = song.albumAudioId, !audioId.isEmpty { return "audio:\(audioId)" }
        return "meta:\(song.title.lowercased())|\(song.artistNames.joined(separator: "/").lowercased())"
    }

    private static func vipTypeCandidates(_ vipType: Int, loggedIn: Bool) -> [Int] {
        let values = vipType > 0 ? [vipType, 6, 1, 0] : (loggedIn ? [1, 6, 0] : [0])
        var seen = Set<Int>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func playbackURL(from json: [String: Any]) -> URL? {
        let raw = deepString(json, names: ["play_url", "play_backup_url", "url", "src", "backup_url"])
        return raw.isEmpty ? nil : validPlaybackURL(raw)
    }

    private static func validPlaybackURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    // MARK: - JSON helpers

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\.(mp3|flac|m4a|aac|ogg|wav)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeURL(_ value: String) -> String {
        if value.hasPrefix("//") { return "https:" + value }
        if value.hasPrefix("http://") { return "https://" + String(value.dropFirst("http://".count)) }
        return value
    }

    /// Top-level error code only (expiry must not trigger on a nested
    /// item's code).
    private static func topLevelErrorCode(_ json: [String: Any]) -> Int {
        int(json["error_code"] ?? json["errcode"])
    }

    private static func deepString(_ obj: Any, names: [String]) -> String {
        if let value = deepValue(obj, names: names), let array = value as? [Any] {
            return array.first.map { string($0) } ?? ""
        }
        return string(deepValue(obj, names: names))
    }

    private static func deepInt(_ obj: Any, names: [String]) -> Int { int(deepValue(obj, names: names)) }

    private static func deepArrays(_ obj: Any, names: [String]) -> [[String: Any]] {
        var best: [[String: Any]] = []
        func walk(_ value: Any) {
            if let array = value as? [[String: Any]], array.count > best.count {
                best = array
            } else if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if names.contains(where: { $0.lowercased() == key.lowercased() }) {
                        walk(child)
                    }
                }
                if best.isEmpty {
                    dict.values.forEach(walk)
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(obj)
        return best
    }

    private static func deepValue(_ obj: Any, names: [String]) -> Any? {
        let wanted = Set(names.map { $0.lowercased() })
        func walk(_ value: Any) -> Any? {
            if let dict = value as? [String: Any] {
                for (key, child) in dict where wanted.contains(key.lowercased()) {
                    return child
                }
                for child in dict.values {
                    if let found = walk(child) { return found }
                }
            } else if let array = value as? [Any] {
                for child in array {
                    if let found = walk(child) { return found }
                }
            }
            return nil
        }
        return walk(obj)
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    private static var browserUA: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Device-registration crypto

    private static func randomLower(_ length: Int) -> String? {
        let chars = Array("1234567890abcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private static func aesCBCEncrypt(_ data: Data, password: String) -> Data? {
        let digest = md5Hex(password)
        return crypt(
            data, op: CCOperation(kCCEncrypt),
            key: Data(digest.prefix(16).utf8), iv: Data(digest.suffix(16).utf8))
    }

    private static func aesCBCDecrypt(_ data: Data, password: String) -> Data? {
        let digest = md5Hex(password)
        return crypt(
            data, op: CCOperation(kCCDecrypt),
            key: Data(digest.prefix(16).utf8), iv: Data(digest.suffix(16).utf8))
    }

    private static func crypt(_ data: Data, op: CCOperation, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLen..<out.count)
        return out
    }

    private static func rsaEncryptPKCS1(_ data: Data, publicKeyBase64: String) -> Data? {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { return nil }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, nil) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error)
        else { return nil }
        return encrypted as Data
    }
}
