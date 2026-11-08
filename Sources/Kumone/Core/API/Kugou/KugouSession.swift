import Foundation
import os.log
import Security

/// KuGou login session + backend transport, ported from Folia v0.7.27
/// (`src/services/onlineMusic/kugou/kugouTransport.ts` +
/// `kugouProvider.ts` auth/library sections). Only the HTTP protocol
/// visible in Folia's rendering layer is copied; nothing is guessed.
///
/// Backend shape (KuGouMusicApi v1.6.0, self-hosted): every request is
/// `GET {base}{path}?<params>&cookie=<session>&timestamp=<ms>`,
/// including `/register/dev` — Folia's web transport sends it as a plain
/// fetch with no method (GET). The backend answers with an envelope
/// `{ status, body: {...} }`; the payload lives under `body.data`.
/// Responses are unwrapped the same way Folia does
/// (`body ?? response`, then `data ?? body`).
///
/// Session storage (four items, kept separate, like Folia's web build):
/// token + cookie go to the Keychain (sensitive), userid + dfid go to
/// UserDefaults (non-secret hints). The backend base URL is a plain
/// UserDefaults setting, empty = not configured. There is no explicit
/// refresh: HTTP 401/403 or `error_code`/`errcode` 152 means the login
/// is dead and all four items are cleared.
///
/// This file never touches `MusicClient` (NetEase-only, `MUSIC_U`) and
/// never touches Live Activity / deep-link code.
enum KugouError: LocalizedError {
    case backendNotConfigured
    case notLoggedIn
    case sessionExpired
    case httpStatus(Int)
    case invalidResponse
    case missingQRKey
    case likedPlaylistNotFound

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: return "KuGou backend is not configured"
        case .notLoggedIn: return "Not logged in to KuGou"
        case .sessionExpired: return "KuGou login has expired"
        case .httpStatus(let status): return "KuGou request failed: HTTP \(status)"
        case .invalidResponse: return "KuGou returned an unreadable response"
        case .missingQRKey: return "KuGou login returned no QR key"
        case .likedPlaylistNotFound: return "KuGou liked playlist could not be resolved"
        }
    }
}

/// QR login poll state. KuGou uses its own codes, not NetEase's
/// 800/801/802/803: 0 expired, 1 waiting, 2 or 3 scanned, 4 confirmed
/// (or `data.token` appearing counts as confirmed).
enum KugouQRCheckState: Equatable {
    case waiting
    case scanned
    case confirmed
    case expired
    case error(String)
}

/// Minimal KuGou account profile, from `GET /user/detail`.
struct KugouProfile: Hashable {
    let id: String
    let nickname: String
    let avatarURL: String?
    /// 0 = not VIP, > 0 = VIP (see `KugouSession.vipType`).
    let vipType: Int
}

/// One KuGou song, normalized from search / playlist responses.
/// `hash` is the playback identity (uppercased FileHash).
struct KugouSong: Hashable {
    let hash: String
    let title: String
    /// Artists joined with " / ", as returned by KuGou.
    let artist: String
    let durationMS: Int
    let albumID: String
    let albumName: String
    let albumAudioID: String
    /// Row id inside the playlist this song was read from, if any.
    let fileID: String?
    let coverURL: String?

    /// Builds a song from a raw KuGou item. Field names follow Folia's
    /// `normalizeKugouSong`: `FileHash`/`SongName`/`SingerName`/
    /// `Duration` (seconds when < 10000, else ms) / `AlbumID` /
    /// `AlbumName`, with the lowercase variants as fallbacks.
    static func from(_ raw: [String: Any]) -> KugouSong? {
        let hash = KugouJSON.string(raw, "FileHash", "fileHash", "hash", "Hash", "audio_hash", "audioHash", "kgHash")?
            .uppercased() ?? ""
        guard !hash.isEmpty else { return nil }
        let base = raw["base"] as? [String: Any] ?? [:]
        let audioInfo = raw["audio_info"] as? [String: Any] ?? raw["audioInfo"] as? [String: Any] ?? [:]
        let title = KugouJSON.string(
            raw,
            "SongName", "songname", "songName", "ori_audio_name", "oriAudioName",
            "OriSongName", "ori_song_name", "oriSongName", "FileName", "filename", "fileName",
            "name", "audio_name"
        ) ?? KugouJSON.string(audioInfo, "ori_audio_name", "oriAudioName", "audio_name", "audioName")
            ?? KugouJSON.string(base, "SongName", "songname", "songName", "audio_name", "audioName")
            ?? ""
        let artist = KugouJSON.string(raw, "SingerName", "singername", "author_name", "Singer") ?? ""
        let durationValue = KugouJSON.number(
            raw, "Duration", "duration", "timelen", "timeLength", "timelength", "time_length"
        ) ?? KugouJSON.number(audioInfo, "duration", "timelength", "duration_128") ?? 0
        let durationMS = durationValue > 0 && durationValue < 10_000
            ? Int(durationValue * 1_000) : Int(durationValue)
        let nestedAlbum = raw["album_info"] as? [String: Any]
            ?? raw["albumInfo"] as? [String: Any]
            ?? raw["albuminfo"] as? [String: Any]
            ?? raw["album"] as? [String: Any] ?? [:]
        let albumID = KugouJSON.string(raw, "AlbumID", "album_id", "albumId")
            ?? KugouJSON.string(nestedAlbum, "album_id", "albumId")
            ?? KugouJSON.string(base, "album_id", "albumId") ?? ""
        let albumName = KugouJSON.string(raw, "AlbumName", "album_name", "albumName", "albumname")
            ?? KugouJSON.string(nestedAlbum, "name", "album_name", "albumName")
            ?? KugouJSON.string(base, "album_name", "albumName") ?? ""
        return KugouSong(
            hash: hash,
            title: title,
            artist: artist,
            durationMS: durationMS,
            albumID: albumID,
            albumName: albumName,
            albumAudioID: KugouJSON.string(raw, "album_audio_id", "albumAudioId")
                ?? KugouJSON.string(base, "album_audio_id", "albumAudioId") ?? "",
            fileID: KugouJSON.string(raw, "FileID", "fileid", "file_id"),
            coverURL: KugouJSON.coverURL(of: raw)
        )
    }
}

/// One KuGou user playlist (collection), from `GET /user/playlist`.
struct KugouPlaylist: Hashable {
    /// Global collection id (`global_collection_id`, falling back to
    /// `specialid` / `id`); this is the id `playlist_track_all` takes.
    let id: String
    /// `listid` — the id playlist mutations (`playlist_tracks_add/del`)
    /// take. Distinct from `id`; do not mix them up.
    let listID: String?
    let name: String
    let trackCount: Int?
    let coverURL: String?
    let isLiked: Bool
}

/// Small JSON helpers shared with `KugouAudioSourceProvider`. They mirror
/// Folia's `valueOf` / `dataOf` / `listOf` / `coverOf` helpers.
enum KugouJSON {
    static func string(_ raw: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = raw[key] {
                if let string = value as? String, !string.isEmpty { return string }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    static func number(_ raw: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = raw[key] as? NSNumber { return value.doubleValue }
            if let value = raw[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    static func int(_ raw: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = raw[key] as? NSNumber { return value.intValue }
            if let value = raw[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    /// Unwraps KuGouMusicApi's `{ body: {...} }` envelope, then `data`.
    static func dataOf(_ raw: [String: Any]) -> [String: Any] {
        if let body = raw["body"] as? [String: Any] {
            return body["data"] as? [String: Any] ?? body
        }
        return raw["data"] as? [String: Any] ?? raw
    }

    /// `error_code` / `errcode` wherever the backend puts it.
    static func errorCode(of raw: [String: Any]) -> Int? {
        if let code = int(raw, "error_code", "errcode") { return code }
        let data = dataOf(raw)
        if let code = int(data, "error_code", "errcode") { return code }
        if let body = raw["body"] as? [String: Any], let code = int(body, "error_code", "errcode") { return code }
        return nil
    }

    static func errorMessage(of raw: [String: Any]) -> String? {
        string(raw, "error", "error_msg", "msg", "message")
            ?? string(dataOf(raw), "error", "error_msg", "msg", "message")
    }

    /// Finds the first array under any of Folia's list keys, searching
    /// nested envelopes breadth-first.
    static func listOf(_ raw: [String: Any]) -> [[String: Any]] {
        // Some endpoints answer `data` as a bare array.
        if let array = raw["data"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let body = raw["body"] as? [String: Any], let array = body["data"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        let listKeys = [
            "lists", "list", "info", "songs", "song_list", "songlist", "songList",
            "audios", "albums", "items", "records",
        ]
        // JSONSerialization output is a tree, so a plain queue cannot cycle.
        var queue: [[String: Any]] = [dataOf(raw)]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for key in listKeys {
                if let array = current[key] as? [[String: Any]] { return array }
                if let array = current[key] as? [Any] {
                    return array.compactMap { $0 as? [String: Any] }
                }
                if let nested = current[key] as? [String: Any] { queue.append(nested) }
            }
        }
        return []
    }

    /// Cover URL, following Folia's `coverOf`: `{size}` becomes 1024,
    /// a bare `12345678.jpg` filename becomes a `c1.kgimg.com` URL.
    static func coverURL(of raw: [String: Any]) -> String? {
        let albumInfo = raw["album_info"] as? [String: Any] ?? raw["albumInfo"] as? [String: Any]
        let value = string(albumInfo ?? [:], "sizable_cover", "cover")
            ?? string(raw, "sizable_cover", "Image", "image", "img", "pic", "picUrl", "cover", "coverUrl", "sizable_avatar")
        guard var cover = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty else { return nil }
        cover = cover.replacingOccurrences(of: "{size}", with: "1024")
        if cover.range(of: #"^\d{8,}\.(?:jpe?g|png|webp)$"#, options: .regularExpression) != nil {
            return "https://c1.kgimg.com/stdmusic/1024/\(cover.prefix(8))/\(cover)"
        }
        if cover.hasPrefix("//") { return "https:\(cover)" }
        return cover.replacingOccurrences(of: "^http:", with: "https:", options: .regularExpression)
    }
}

enum KugouOperation: String {
    case registerDev = "/register/dev"
    case loginQRKey = "/login/qr/key"
    case loginQRCreate = "/login/qr/create"
    case loginQRCheck = "/login/qr/check"
    case logout = "/logout"
    case userDetail = "/user/detail"
    case userVipDetail = "/user/vip/detail"
    case youthUnionVip = "/youth/union/vip"
    case youthDayVip = "/youth/day/vip"
    case youthDayVipUpgrade = "/youth/day/vip/upgrade"
    case userPlaylist = "/user/playlist"
    case playlistTrackAll = "/playlist/track/all"
    case search = "/search"
    case songURL = "/song/url"
}

/// UserDefaults settings for KuGou. Mirrors the sibling
/// `QQMusicSettings`: one key for the self-hosted KuGouMusicApi base
/// URL, empty = not configured. No default address is ever baked in;
/// the user self-hosts the backend or enters a deployment address
/// they trust, because login traffic passes through it.
enum KugouSettings {
    /// User-configured KuGouMusicApi base URL (for example
    /// `https://kugou.example.com`). Empty means "not configured":
    /// KuGou login and the backend search / `/song/url` routes are
    /// unavailable (anonymous search still works).
    static let baseURLKey = "settings.kugouApiBaseURL"

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    /// Normalized base URL, or nil when nothing usable is configured.
    static var baseURL: URL? {
        let raw = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        guard !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    static var isConfigured: Bool { baseURL != nil }
}

/// KuGou login state + backend transport. No in-memory credential cache:
/// every read goes to the Keychain / UserDefaults, so a logout on any
/// path is immediately visible to the next request.
final class KugouSession: @unchecked Sendable {
    static let shared = KugouSession()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "kugou")

    /// Non-secret account hints, kept separate like Folia's web storage.
    static let userIDDefaultsKey = "auth.kugou.userid"
    static let dfidDefaultsKey = "auth.kugou.dfid"

    private static let keychainService = "sb.moe.kumone.kugou"
    private static let tokenAccount = "token"
    private static let cookieAccount = "cookie"

    private let session: URLSession

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
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Configuration

    /// The configured backend base URL, trailing slash stripped.
    /// `nil` when the user has not entered one.
    var baseURL: String? { KugouSettings.baseURL?.absoluteString }

    var isBackendConfigured: Bool { KugouSettings.isConfigured }

    func updateBaseURL(_ raw: String) {
        KugouSettings.baseURLString = raw
    }

    // MARK: - Session state

    var userID: String? {
        let value = UserDefaults.standard.string(forKey: Self.userIDDefaultsKey)
        return value?.isEmpty == false ? value : nil
    }

    var dfid: String? {
        let value = UserDefaults.standard.string(forKey: Self.dfidDefaultsKey)
        return value?.isEmpty == false ? value : nil
    }

    private var token: String? { Self.keychainLoad(account: Self.tokenAccount) }
    private var cookie: String? { Self.keychainLoad(account: Self.cookieAccount) }

    /// Has a token + userid (the same bar Folia's login-status check uses
    /// before calling `user_detail`).
    var isLoggedIn: Bool { token != nil && userID != nil }

    /// Has everything authenticated search needs: token + userid + dfid.
    var hasAuthenticatedSession: Bool { token != nil && userID != nil && dfid != nil }

    /// Clears all four session items (cookie / token / userid / dfid).
    /// The backend base URL is a setting, not session state: it stays.
    func clearSession() {
        Self.keychainDelete(account: Self.tokenAccount)
        Self.keychainDelete(account: Self.cookieAccount)
        UserDefaults.standard.removeObject(forKey: Self.userIDDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.dfidDefaultsKey)
    }

    // MARK: - QR login

    /// Step 1: `GET /login/qr/key`. The key is whichever of
    /// `qrcode` / `qrkey` / `key` / `ticket` the backend returns.
    func qrKey() async throws -> String {
        let body = try await request(.loginQRKey)
        let data = KugouJSON.dataOf(body)
        guard let key = KugouJSON.string(data, "qrcode", "qrkey", "key", "ticket"),
              !key.isEmpty
        else { throw KugouError.missingQRKey }
        return key
    }

    /// Step 2: `GET /login/qr/create?key=&qrimg=true`. Returns the raw
    /// string from `base64` / `qrimg` / `qrcode` / `url`: usually a
    /// base64 image (decode with `qrImageData(from:)`), sometimes a URL
    /// (render with the existing `CIFilter.qrCodeGenerator` path).
    func qrImageString(key: String) async throws -> String {
        let body = try await request(.loginQRCreate, params: ["key": key, "qrimg": "true"])
        let data = KugouJSON.dataOf(body)
        guard let image = KugouJSON.string(data, "base64", "qrimg", "qrcode", "url"),
              !image.isEmpty
        else { throw KugouError.invalidResponse }
        return image
    }

    /// Decodes a `qrImageString` result that is a base64 image (bare, or
    /// a `data:image/...;base64,...` URL). Returns `nil` when the string
    /// is an http(s) URL instead — generate a QR code from it.
    static func qrImageData(from string: String) -> Data? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return nil }
        let base64 = trimmed.contains(",") ? String(trimmed.split(separator: ",", maxSplits: 1).last ?? "") : trimmed
        return Data(base64Encoded: base64)
    }

    /// Step 3, one poll: `GET /login/qr/check?key=&qrcode=<key>`.
    /// The caller polls this every 2 seconds (Folia's interval) until
    /// `.confirmed` or `.expired`; transient network errors are the
    /// caller's to tolerate, like `LoginSheet` does for NetEase.
    func checkLogin(key: String) async throws -> KugouQRCheckState {
        let body = try await request(.loginQRCheck, params: ["key": key, "qrcode": key])
        let data = KugouJSON.dataOf(body)
        let status = KugouJSON.int(data, "status", "code") ?? KugouJSON.int(body, "status", "code")
        if let token = KugouJSON.string(data, "token"), !token.isEmpty { return .confirmed }
        switch status {
        case 0: return .expired
        case 1: return .waiting
        case 2, 3: return .scanned
        case 4: return .confirmed
        default:
            let message = KugouJSON.errorMessage(of: body) ?? ""
            return .error(message)
        }
    }

    // MARK: - Login status / logout

    /// `GET /user/detail?userid=`. Returns the profile only when the
    /// backend answers with a non-empty id and nickname (Folia's bar).
    /// On success it also tries the youth-day VIP claim and reads the
    /// VIP type; both are best-effort and never fail validation.
    func validateLogin() async throws -> KugouProfile? {
        guard let userID else { return nil }
        let body = try await request(.userDetail, params: ["userid": userID])
        let profile = profile(from: body)
        guard let profile, !profile.id.isEmpty, !profile.nickname.isEmpty else { return nil }
        let claimedYouthVip = await ensureYouthVip(userID: profile.id)
        var vipType = profile.vipType
        if let vip = try? await vipType(userID: profile.id) { vipType = vip }
        if claimedYouthVip && vipType == 0 { vipType = 1 }
        return KugouProfile(id: profile.id, nickname: profile.nickname, avatarURL: profile.avatarURL, vipType: vipType)
    }

    /// Logs out server-side (best-effort) and clears all four session
    /// items, like Folia's `auth.logout()`. The session is cleared
    /// immediately; a slow logout reply cannot leave stale credentials.
    func logout() async {
        let told = Task { try? await self.request(.logout) }
        clearSession()
        _ = await told.value
    }

    // MARK: - Device identity

    /// `GET /register/dev`. Registers this device and persists the
    /// returned `dfid`. Called automatically (once per request) when the
    /// backend answers 20028 / "本次请求需要验证".
    @discardableResult
    func registerDevice() async throws -> String {
        let body = try await request(.registerDev, method: "GET")
        let data = KugouJSON.dataOf(body)
        guard let dfid = KugouJSON.string(data, "dfid"), !dfid.isEmpty else {
            throw KugouError.invalidResponse
        }
        UserDefaults.standard.set(dfid, forKey: Self.dfidDefaultsKey)
        return dfid
    }

    // MARK: - Youth-day VIP

    /// Folia's `ensureKugouYouthVip`, verbatim in shape: ask
    /// `youth_union_vip`; if already VIP, do nothing; otherwise claim
    /// `youth_day_vip` (dated in Asia/Shanghai) and then
    /// `youth_day_vip_upgrade`. Never throws: any failure just means
    /// no VIP was claimed. Returns `true` only when a claim succeeded.
    func ensureYouthVip(userID: String) async -> Bool {
        do {
            var params: [String: String] = ["userid": userID]
            if let token { params["token"] = token }
            let union = try await request(.youthUnionVip, params: params)
            guard (KugouJSON.errorCode(of: union) ?? 0) == 0,
                  !KugouJSON.dataOf(union).isEmpty
            else { return false }
            if vipType(from: union) > 0 { return false }
            let claim = try await request(.youthDayVip, params: params.merging(
                ["receive_day": Self.receiveDay()], uniquingKeysWith: { _, new in new }
            ))
            guard isSuccessfulVipMutation(claim) else { return false }
            let upgrade = try await request(.youthDayVipUpgrade, params: params)
            return isSuccessfulVipMutation(upgrade)
        } catch {
            Self.log.warn("kugou youth-vip check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `GET /user/vip/detail`: direct `vip_type` wins, otherwise any
    /// `busi_vip` entry with `is_vip` > 0 means VIP (type 1).
    func vipType(userID: String) async throws -> Int {
        let body = try await request(.userVipDetail, params: ["userid": userID])
        return vipType(from: body)
    }

    private func vipType(from raw: [String: Any]) -> Int {
        let data = KugouJSON.dataOf(raw)
        if let direct = KugouJSON.number(data, "vip_type", "vipType", "is_vip"), direct > 0 {
            return Int(direct)
        }
        if let business = data["busi_vip"] as? [[String: Any]],
           business.contains(where: { (KugouJSON.number($0, "is_vip", "vip_type") ?? 0) > 0 }) {
            return 1
        }
        return 0
    }

    private func isSuccessfulVipMutation(_ raw: [String: Any]) -> Bool {
        let data = KugouJSON.dataOf(raw)
        let errCode = KugouJSON.errorCode(of: raw) ?? 0
        let status = KugouJSON.number(raw, "status") ?? KugouJSON.number(data, "status") ?? 1
        return errCode == 0 && status == 1
    }

    /// Today's date in KuGou's China-based calendar (`yyyy-MM-dd`).
    private static func receiveDay(date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Library (data layer only, no UI)

    /// `GET /user/playlist` (page 1, 100 items), playlist entries only.
    /// The built-in "我喜欢" list is included with `isLiked == true`.
    func userPlaylists() async throws -> [KugouPlaylist] {
        guard let userID else { throw KugouError.notLoggedIn }
        let body = try await request(.userPlaylist, params: ["userid": userID, "page": "1", "pagesize": "100"])
        return KugouJSON.listOf(body).compactMap(Self.playlist(from:)).filter { $0.id != "" }
    }

    /// The account's liked songs: find the built-in "我喜欢" playlist
    /// (name `我喜欢` / `我喜欢的音乐`, or `listid` 2) in
    /// `user_playlist`, then read all of its tracks via
    /// `playlist_track_all` (100 per page, until a short page).
    func likedTracks() async throws -> [KugouSong] {
        guard let userID else { throw KugouError.notLoggedIn }
        let body = try await request(.userPlaylist, params: ["userid": userID, "page": "1", "pagesize": "100"])
        let items = KugouJSON.listOf(body)
        guard let liked = items.first(where: Self.isLikedPlaylist),
              let globalCollectionID = KugouJSON.string(liked, "global_collection_id", "globalCollectionId"),
              !globalCollectionID.isEmpty
        else { throw KugouError.likedPlaylistNotFound }
        var songs: [KugouSong] = []
        var page = 1
        while true {
            let pageBody = try await request(.playlistTrackAll, params: [
                "id": globalCollectionID, "page": String(page), "pagesize": "100",
            ])
            let pageSongs = KugouJSON.listOf(pageBody).compactMap(KugouSong.from)
            songs.append(contentsOf: pageSongs)
            if pageSongs.count < 100 { break }
            page += 1
        }
        return songs
    }

    // MARK: - Search / playback URL (backend routes, need login)

    /// Authenticated song search: `GET /search` with `type=song`.
    /// Returns `[]` (not an error) when the backend answers no items —
    /// the caller falls back to anonymous search.
    func searchSongs(keyword: String, page: Int = 1, pageSize: Int = 10) async throws -> [KugouSong] {
        let body = try await request(.search, params: [
            "keywords": keyword, "keyword": keyword, "type": "song",
            "page": String(page), "pagesize": String(pageSize),
        ])
        return KugouJSON.listOf(body).compactMap(KugouSong.from)
    }

    /// `GET /song/url` for one hash + one quality value (`"320"`,
    /// `"128"`, `"flac"`, `"high"` — see `KugouAudioSourceProvider`).
    /// Tries the metadata variant first (`album_id` /
    /// `album_audio_id` as given), then hash-only, because search
    /// metadata can carry album ids that do not belong to the hash.
    /// Returns `nil` when the backend answers without a URL; a rejected
    /// login (`sessionExpired`) is thrown at once, like Folia.
    func songURL(hash: String, quality: String, albumID: String, albumAudioID: String) async throws -> URL? {
        let variants: [(String, String)] = [(albumID, albumAudioID), ("", "")]
        for (albumIDValue, albumAudioIDValue) in variants {
            do {
                let body = try await request(.songURL, params: [
                    "hash": hash.uppercased(), "quality": quality,
                    "album_id": albumIDValue, "album_audio_id": albumAudioIDValue,
                ])
                if let url = Self.playURL(from: body) { return url }
            } catch KugouError.sessionExpired {
                throw KugouError.sessionExpired
            } catch {
                continue
            }
        }
        return nil
    }

    private static func playURL(from body: [String: Any]) -> URL? {
        // `/song/url` answers `data` as an array; take its first entry.
        let payload: [String: Any]
        if let array = body["data"] as? [Any], let first = array.first as? [String: Any] {
            payload = first
        } else if let array = (body["body"] as? [String: Any])?["data"] as? [Any],
                  let first = array.first as? [String: Any] {
            payload = first
        } else {
            payload = dataOf(body)
        }
        guard let raw = KugouJSON.string(payload, "play_url", "playUrl", "url")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    private static func dataOf(_ body: [String: Any]) -> [String: Any] {
        KugouJSON.dataOf(body)
    }

    // MARK: - Transport

    /// One backend call. Builds `GET {base}{path}?<params>&cookie=…&
    /// timestamp=…` (POST for `.registerDev`), unwraps the `{ body }`
    /// envelope, persists any session the response carries, and turns
    /// auth failures into `sessionExpired` (clearing the session).
    /// A 20028 / "本次请求需要验证" answer re-registers the device
    /// once and retries, like Folia's web transport.
    func request(
        _ operation: KugouOperation,
        params: [String: String] = [:],
        method: String = "GET"
    ) async throws -> [String: Any] {
        guard let baseURLValue = KugouSettings.baseURL else {
            throw KugouError.backendNotConfigured
        }
        let body = try await perform(operation, params: params, method: method, baseURL: baseURLValue, retriedDeviceRegistration: false)
        return body
    }

    private func perform(
        _ operation: KugouOperation,
        params: [String: String],
        method: String,
        baseURL: URL,
        retriedDeviceRegistration: Bool
    ) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(operation.rawValue), resolvingAgainstBaseURL: false)
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let cookie = sessionCookieHeader(), !cookie.isEmpty {
            queryItems.append(URLQueryItem(name: "cookie", value: cookie))
        }
        queryItems.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1_000))))
        components?.queryItems = queryItems
        guard let url = components?.url else { throw KugouError.invalidResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        urlRequest.httpMethod = method
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KugouError.invalidResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                clearSession()
                throw KugouError.sessionExpired
            }
            throw KugouError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            clearSession()
            throw KugouError.sessionExpired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KugouError.httpStatus(httpResponse.statusCode)
        }
        // Authenticated request without valid credentials: error_code 152.
        if KugouJSON.errorCode(of: json) == 152 {
            clearSession()
            throw KugouError.sessionExpired
        }
        if operation != .registerDev, !retriedDeviceRegistration, isDeviceVerificationRequired(json) {
            clearDeviceIdentity()
            _ = try? await registerDevice()
            return try await perform(operation, params: params, method: method, baseURL: baseURL, retriedDeviceRegistration: true)
        }
        if operation != .logout {
            persistSession(from: json)
        }
        return json["body"] as? [String: Any] ?? json
    }

    private func isDeviceVerificationRequired(_ json: [String: Any]) -> Bool {
        if KugouJSON.errorCode(of: json) == 20028 { return true }
        return KugouJSON.errorMessage(of: json)?.contains("本次请求需要验证") == true
    }

    private func clearDeviceIdentity() {
        UserDefaults.standard.removeObject(forKey: Self.dfidDefaultsKey)
        if var cookie = cookie {
            let retained = cookie.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.lowercased().hasPrefix("dfid=") }
            cookie = retained.joined(separator: ";")
            if cookie.isEmpty {
                Self.keychainDelete(account: Self.cookieAccount)
            } else {
                Self.keychainSave(account: Self.cookieAccount, value: cookie)
            }
        }
    }

    /// Merges the stored cookie string with the separately stored
    /// token / userid / dfid, like Folia's `getWebSessionCookie`.
    private func sessionCookieHeader() -> String? {
        var values: [(String, String)] = []
        if let cookie {
            for entry in cookie.split(separator: ";") {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                values.append((parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)))
            }
        }
        func set(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            values.removeAll { $0.0.lowercased() == key }
            values.append((key, value))
        }
        set("dfid", dfid)
        set("token", token)
        set("userid", userID)
        guard !values.isEmpty else { return nil }
        return values.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }

    /// Persists a session the way Folia's web `persistWebSession` does:
    /// a `cookie` string, plus `token` / `userid` / `dfid` from the
    /// payload (`data`, else `body.data`, else `body`, else the whole
    /// response). Called after every non-logout response.
    private func persistSession(from json: [String: Any]) {
        if let cookies = json["cookie"] as? String, !cookies.isEmpty {
            Self.keychainSave(account: Self.cookieAccount, value: cookies)
        } else if let cookies = KugouJSON.dataOf(json)["cookie"] as? String, !cookies.isEmpty {
            Self.keychainSave(account: Self.cookieAccount, value: cookies)
        } else if let cookies = json["cookie"] as? [String], !cookies.isEmpty {
            Self.keychainSave(account: Self.cookieAccount, value: cookies.joined(separator: "; "))
        }
        let payload = json["data"] as? [String: Any]
            ?? (json["body"] as? [String: Any])?["data"] as? [String: Any]
            ?? json["body"] as? [String: Any]
            ?? json
        if let token = KugouJSON.string(payload, "token"), !token.isEmpty {
            Self.keychainSave(account: Self.tokenAccount, value: token)
        }
        if let userID = KugouJSON.string(payload, "userid", "user_id"), !userID.isEmpty {
            UserDefaults.standard.set(userID, forKey: Self.userIDDefaultsKey)
        }
        if let dfid = KugouJSON.string(payload, "dfid"), !dfid.isEmpty {
            UserDefaults.standard.set(dfid, forKey: Self.dfidDefaultsKey)
        }
    }

    private func profile(from body: [String: Any]) -> KugouProfile? {
        let data = KugouJSON.dataOf(body)
        let profile = (data["user_info"] as? [String: Any])
            ?? (data["userinfo"] as? [String: Any])
            ?? (data["profile"] as? [String: Any])
            ?? data
        let id = KugouJSON.string(profile, "userid", "user_id", "id", "uid")
            ?? userID ?? ""
        let nickname = KugouJSON.string(profile, "nickname", "nick_name", "username", "name") ?? ""
        let avatarURL = KugouJSON.coverURL(of: profile) ?? KugouJSON.string(profile, "avatar", "pic")
        let vipType = Int(KugouJSON.number(profile, "vip_type", "vipType", "is_vip") ?? 0)
        return KugouProfile(id: id, nickname: nickname, avatarURL: avatarURL, vipType: vipType)
    }

    private static func playlist(from raw: [String: Any]) -> KugouPlaylist? {
        let source = KugouJSON.int(raw, "source")
        let isAlbum = source == 2
            || raw["musiclib_id"] != nil || raw["musicLibId"] != nil
        guard !isAlbum else { return nil }
        let id = KugouJSON.string(raw, "global_collection_id", "globalCollectionId", "specialid", "specialId", "id") ?? ""
        let name = KugouJSON.string(raw, "name", "listname", "specialname") ?? ""
        return KugouPlaylist(
            id: id,
            listID: KugouJSON.string(raw, "listid", "list_id"),
            name: name,
            trackCount: KugouJSON.int(raw, "song_count", "count", "m_count", "total", "music_num"),
            coverURL: KugouJSON.coverURL(of: raw),
            isLiked: isLikedPlaylist(raw)
        )
    }

    private static func isLikedPlaylist(_ raw: [String: Any]) -> Bool {
        let source = KugouJSON.int(raw, "source")
        guard source != 2, raw["musiclib_id"] == nil, raw["musicLibId"] == nil else { return false }
        let name = (KugouJSON.string(raw, "name", "listname") ?? "").trimmingCharacters(in: .whitespaces)
        if name == "我喜欢" || name == "我喜欢的音乐" { return true }
        if let listID = raw["listid"] as? NSNumber, listID.intValue == 2 { return true }
        if let listID = raw["list_id"] as? NSNumber, listID.intValue == 2 { return true }
        return false
    }

    // MARK: - Keychain (token + cookie only; same shape as LoginKeyStore)

    private static func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    private static func keychainSave(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        keychainDelete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainDelete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
}
