import CoreImage
import Foundation
import os.log
import Security

/// QQ Music login state and account data layer.
///
/// Folia's QQ login (`qqProvider.ts` / `qqTransport.ts` /
/// `qqSessionRefresh.ts`, backend `@yakult-green-tea/qq-music-api`
/// 3.3.6) is a QR flow against a self-hosted HTTP backend: discover
/// channels, take a QR key, show the QR image, poll `check` every 2 s
/// until the backend reports 803 with an opaque session string
/// `qqmusic_session=<token>`. iOS cannot run the Node backend in-app,
/// so every call here goes to a user-configured remote base URL; with
/// no base URL configured the login entry is unavailable.
///
/// The session holder deliberately does **not** reuse `MusicClient`:
/// that client only understands NetEase `MUSIC_U` cookies, and its
/// `authenticationCookies()` / `replaceAuthentication` hard-code those
/// two names. The token is stored in the Keychain (mirroring Folia
/// desktop, which keeps it in the system keychain via
/// `safeStorage`), never in `cookies.json` and never in UserDefaults.
enum QQMusicSettings {
    /// User-configured `qq-music-api` base URL (for example
    /// `https://qq.example.com`). Empty means "not configured": QQ login
    /// and the QQ source are unavailable. No default address is ever
    /// baked in; the user self-hosts the backend or enters a deployment
    /// address they trust, because login traffic passes through it.
    static let baseURLKey = "settings.qqMusicAPIBaseURL"

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

/// A QQ Music account profile, as returned by `GET /login/status`
/// (`data.profile`). The acceptance-test account Folia probed returned
/// no display name at all, so every field except the id is optional.
struct QQMusicProfile: Codable, Hashable {
    let id: String
    let nickname: String
    let avatarURL: String?
    /// VIP type, when the backend reports one (0 = non-VIP).
    let vipType: Int?

    init(id: String, nickname: String, avatarURL: String? = nil, vipType: Int? = nil) {
        self.id = id
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.vipType = vipType
    }

    init?(responseObject: [String: Any]) {
        let profile = Self.profileNode(from: responseObject)
        // The account id prefers `str_musicid`: the `musicid` from a
        // WeChat credential is a placeholder `0`.
        let id = [profile["str_musicid"], profile["musicid"], profile["uin"], profile["id"]]
            .compactMap { value -> String? in
                if let string = value as? String, !string.isEmpty, string != "0" { return string }
                if let number = value as? Int, number != 0 { return String(number) }
                return nil
            }.first ?? ""
        guard !id.isEmpty else { return nil }
        let info = profile["info"] as? [String: Any] ?? [:]
        let nickname = [profile["nickname"], profile["nick"], profile["name"], profile["userName"],
                        info["nickname"], info["nick"], info["name"], info["userName"]]
            .compactMap { $0 as? String }.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        // The avatar lives in `info.logo` (a full https URL); `avatarUrl`
        // is the name the backend's credential-fallback path uses.
        let avatarURL = [profile["avatarUrl"], info["logo"], info["avatarUrl"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty })
        let vipType = profile["vipType"] as? Int
        self.init(id: id, nickname: nickname, avatarURL: avatarURL, vipType: vipType)
    }

    private static func profileNode(from responseObject: [String: Any]) -> [String: Any] {
        // `login_status` nests the profile under `data.profile`; tolerate
        // the flatter shapes too.
        if let data = responseObject["data"] as? [String: Any],
           let profile = data["profile"] as? [String: Any] {
            return profile
        }
        if let profile = responseObject["profile"] as? [String: Any] {
            return profile
        }
        return responseObject
    }
}

/// One QQ Music track, in the shape the backend search and the liked /
/// playlist routes return, normalized the way Folia's `normalizeQqSong`
/// does: `songmid` is the stable playback identity, the numeric song id
/// is only a lyric/detail parameter.
struct QQMusicTrack: Hashable {
    /// The `songmid` (for example `0039MnYb0qxYhV`); empty when the
    /// backend did not give one, in which case the track cannot be
    /// played through `/getMusicPlay/:songmid`.
    let songmid: String
    let songID: Int?
    let title: String
    let artistNames: [String]
    let albumName: String
    let albumMid: String
    let durationMS: Int
    /// `file.media_mid`, when the backend reports it; passed to
    /// `/getMusicPlay` as `mediaId`.
    let mediaMid: String?
    let coverURL: String?

    var artistDisplayName: String { artistNames.joined(separator: " / ") }

    init(songmid: String, songID: Int? = nil, title: String, artistNames: [String] = [],
         albumName: String = "", albumMid: String = "", durationMS: Int = 0,
         mediaMid: String? = nil, coverURL: String? = nil) {
        self.songmid = songmid
        self.songID = songID
        self.title = title
        self.artistNames = artistNames
        self.albumName = albumName
        self.albumMid = albumMid
        self.durationMS = durationMS
        self.mediaMid = mediaMid
        self.coverURL = coverURL
    }

    /// Parses one upstream song entry: the musicu `item_song` shape and
    /// the backend `/search` item shape alike.
    init?(object: [String: Any]) {
        let songmid = [object["qqMid"], object["mid"], object["songmid"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
        let songID = [object["songid"], object["songId"], object["id"]]
            .compactMap { value -> Int? in
                if let number = value as? Int { return number }
                if let string = value as? String { return Int(string) }
                return nil
            }.first
        let title = [object["title"], object["name"], object["songname"]]
            .compactMap { $0 as? String }.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        guard !songmid.isEmpty || songID != nil, !title.isEmpty else { return nil }

        let singerNode = object["singer"] ?? object["singers"] ?? object["artists"]
        let artistNames = (singerNode as? [[String: Any]] ?? [])
            .compactMap { ($0["name"] as? String) ?? ($0["title"] as? String) }
            .filter { !$0.isEmpty }
        let album = object["album"] as? [String: Any] ?? [:]
        let albumMid = [album["mid"], album["albummid"], album["albumMid"], album["albumMID"],
                        object["albummid"], object["albumMid"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
        let albumName = [album["name"], album["title"], album["albumname"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
        let durationMS: Int
        if let ms = object["durationMs"] as? Int, ms > 0 {
            durationMS = ms
        } else if let seconds = (object["interval"] as? Int) ?? (object["duration"] as? Int), seconds > 0 {
            durationMS = seconds * 1_000
        } else {
            durationMS = 0
        }
        let file = object["file"] as? [String: Any] ?? [:]
        let mediaMid = [file["media_mid"], file["mediaMid"], object["mediaMid"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty })
        let coverURL = [album["coverUrl"], album["picUrl"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty })
            ?? (albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000")
        self.init(songmid: songmid, songID: songID, title: title, artistNames: artistNames,
                  albumName: albumName, albumMid: albumMid, durationMS: durationMS,
                  mediaMid: mediaMid, coverURL: coverURL)
    }

    /// Parses one musicu `item_song` entry (numeric ids, `interval` in
    /// seconds, singers under `singer`).
    init?(musicuItem object: [String: Any]) {
        self.init(object: object)
    }
}

/// One QQ Music playlist from `GET /user/playlist` (one fetch returns
/// the whole list; the caller pages locally). `owned` marks a playlist
/// the account created itself (`dirName` present);收藏的 playlists are
/// a different field set and must not be treated as owned. `dirId`
/// 201 on an owned playlist is "我喜欢" (liked songs).
struct QQMusicPlaylist: Hashable {
    let id: String
    let name: String
    let coverURL: String?
    let trackCount: Int?
    let playCount: Int?
    let creatorName: String?
    let isOwned: Bool
    let dirId: Int?
    let isLiked: Bool

    var isLikedFolder: Bool { isLiked }

    init?(object: [String: Any]) {
        let tid = object["tid"]
        let dissid = object["dissid"]
        let rawID = object["id"]
        let dirId = (object["dirId"] as? Int) ?? (object["dirid"] as? Int)
        let idValue: String? = [tid, dissid, rawID].compactMap { value -> String? in
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? Int { return String(number) }
            return nil
        }.first ?? (dirId.map { String($0) })
        guard let id = idValue, !id.isEmpty else { return nil }
        let name = [object["dirName"], object["dirname"], object["dissname"], object["title"], object["name"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
        let coverURL = [object["bigpicUrl"], object["picUrl"], object["picurl"], object["coverUrl"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty })
        let trackCount = (object["songNum"] as? Int) ?? (object["songnum"] as? Int)
        let playCount = (object["play_cnt"] as? Int) ?? (object["listennum"] as? Int)
        let creator = object["creator"] as? [String: Any] ?? [:]
        let creatorName = [creator["nick"], creator["nickname"], creator["name"]]
            .compactMap { $0 as? String }.first(where: { !$0.isEmpty })
        // Only a `dirName` marks a self-created playlist: a collected
        // playlist also carries a `dirId` (the creator's directory
        // number), so `dirId` alone must not imply ownership.
        let isOwned = object["dirName"] != nil
        self.init(id: id, name: name, coverURL: coverURL, trackCount: trackCount,
                  playCount: playCount, creatorName: creatorName, isOwned: isOwned,
                  dirId: dirId, isLiked: isOwned && dirId == 201)
    }

    init(id: String, name: String, coverURL: String? = nil, trackCount: Int? = nil,
         playCount: Int? = nil, creatorName: String? = nil, isOwned: Bool = false,
         dirId: Int? = nil, isLiked: Bool = false) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.playCount = playCount
        self.creatorName = creatorName
        self.isOwned = isOwned
        self.dirId = dirId
        self.isLiked = isLiked
    }
}

/// Outcome of one `GET /login/qr/check` poll, using the NetEase-style
/// codes the backend translates the native QQ/WeChat states into.
enum QQMusicQRState: Equatable {
    /// 801: waiting for the user to scan.
    case waiting
    /// 802: scanned, waiting for confirmation on the phone.
    case scanned
    /// 803: confirmed; the session is stored and the login is complete.
    case confirmed
    /// 800: expired (or the user cancelled on the phone). `retryAfterMS`
    /// is the backend's requested wait before asking for a new code, if
    /// it gave one.
    case expired(retryAfterMS: Int? = nil)
    case failed(QQMusicError)

    static func == (lhs: QQMusicQRState, rhs: QQMusicQRState) -> Bool {
        switch (lhs, rhs) {
        case (.waiting, .waiting), (.scanned, .scanned), (.confirmed, .confirmed):
            return true
        case (.expired(let a), .expired(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Where this device keeps the QQ session string. The Keychain shape
/// mirrors `LoginKeyStore.keychain` (generic password, not
/// synchronizable, this device only). The token itself is opaque: it is
/// not a QQ credential, only the backend's session handle.
struct QQMusicSessionStore {
    let load: () -> String?
    let save: (String) throws -> Void
    let delete: () -> Void

    static var keychain: Self {
        let service = "sb.moe.kumone.qqmusic-session"
        let account = "session"
        return Self(
            load: {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data,
                      let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
                return value
            },
            save: { value in
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                ] as CFDictionary)
                let item: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: Data(value.utf8),
                ]
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
            },
            delete: {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                ] as CFDictionary)
            }
        )
    }

    static func memory() -> Self {
        final class Box { var value: String? }
        let box = Box()
        return Self(load: { box.value }, save: { box.value = $0 }, delete: { box.value = nil })
    }
}

/// Holds the QQ Music login session and drives the QR login, refresh
/// and status checks. Thread-safe like `MusicClient` (`NSLock` +
/// `@unchecked Sendable`); the UI observes login state through its own
/// `@Published` wrapper, never by reading this class from a view.
final class QQMusicSession: @unchecked Sendable {
    static let shared = QQMusicSession()

    /// The backend session lives 180 s per QR code; the UI stops 5 s
    /// early so an expired code reads as "expired", not a hung poll.
    static let qrTTL: TimeInterval = 175
    /// Poll interval for `GET /login/qr/check`.
    static let qrPollInterval: TimeInterval = 2
    /// How often `POST /login/refresh` is asked while signed in.
    static let refreshInterval: TimeInterval = 3_600
    /// Upstream code for "this account has hit its signed-in device
    /// limit" (see `QQMusicError.deviceLimit`).
    static let deviceLimitUpstreamCode = 20279
    /// Cooldown before re-probing `/login/channels` after a failure.
    static let channelProbeRetryDelay: TimeInterval = 30

    /// Fallback channels when the backend has no `/login/channels`
    /// route (old backend) or the probe fails.
    static let fallbackChannels = ["qq", "wechat"]

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")

    private let httpClient: QQMusicAPIClient
    private let store: QQMusicSessionStore
    private let lock = NSLock()
    private var _session: String?
    private var _refreshRouteMissing = false
    private var _declaredChannels: [String]?
    private var _channelProbeRetryAt = Date.distantPast
    private var _lastRefreshAttemptAt = Date.distantPast
    private var _refreshTask: Task<Void, Never>?
    private var _sessionCheckTask: Task<Void, Never>?
    /// The key that last answered 802: a backend "QR login failed"
    /// after a scan can be the credential exchange failing, not the
    /// link breaking.
    private var _scannedKey: String?

    init(httpClient: QQMusicAPIClient = .shared, store: QQMusicSessionStore = .keychain) {
        self.httpClient = httpClient
        self.store = store
        _session = store.load()
    }

    // MARK: - Session state

    /// The stored `qqmusic_session=<token>` string, or nil.
    var sessionString: String? {
        lock.withLock { _session }
    }

    var isLoggedIn: Bool { sessionString != nil }
    var hasSession: Bool { sessionString != nil }

    /// The bare token inside the stored `qqmusic_session=<token>` string.
    var sessionToken: String? {
        guard let stored = sessionString else { return nil }
        for entry in stored.split(separator: ";") {
            let pair = entry.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "qqmusic_session" else { continue }
            return String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func storeSession(_ value: String?) {
        lock.withLock { _session = value }
        do {
            if let value, !value.isEmpty {
                try store.save(value)
            } else {
                store.delete()
            }
        } catch {
            Self.log.error("qq-music session store failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func dropSessionIfStill(_ sent: String) {
        lock.withLock {
            if _session == sent {
                _session = nil
                store.delete()
            }
        }
    }

    // MARK: - Channels

    /// Discovers the backend's login channels (`GET /login/channels`).
    /// A backend without the route (or any probe failure) falls back to
    /// `qq` + `wechat` and retries at most every 30 s.
    func discoverChannels(forceRetry: Bool = false) async -> [String] {
        if let declared = lock.withLock({ _declaredChannels }) { return declared }
        guard forceRetry || Date() >= lock.withLock({ _channelProbeRetryAt }) else {
            return Self.fallbackChannels
        }
        guard let baseURL = QQMusicSettings.baseURL else { return Self.fallbackChannels }
        do {
            let body = try await httpClient.backend("/login/channels", baseURL: baseURL)
            let channels = ((body["data"] as? [String: Any])?["channels"] as? [Any] ?? [])
                .compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !channels.isEmpty else { throw QQMusicError.invalidResponse }
            lock.withLock {
                _declaredChannels = channels
                _channelProbeRetryAt = .distantPast
            }
            return channels
        } catch {
            lock.withLock {
                _declaredChannels = nil
                _channelProbeRetryAt = Date().addingTimeInterval(Self.channelProbeRetryDelay)
            }
            return Self.fallbackChannels
        }
    }

    /// The channels the login UI should offer. With no declared list yet,
    /// the fallback pair; when the backend declares only `qqmusic`, the
    /// UI shows no picker and scans with the QQ Music app directly.
    func loginChannels() async -> [String] {
        await discoverChannels()
    }

    // MARK: - QR login

    /// Takes a QR key for `channel` and returns the key plus the QR
    /// image as PNG data. The backend's `data.qrimg` is an image (a
    /// base64 data URL in practice); a bare base64 string is accepted
    /// too, and an http(s) URL is fetched. If a backend ever returns a
    /// plain login URL string instead of an image, the UI can render it
    /// with `qrPNGData(for:)` (CIFilter, same as LoginSheet.generateQR).
    func startLogin(channel: String) async throws -> (key: String, qrPNGData: Data) {
        guard let baseURL = QQMusicSettings.baseURL else { throw QQMusicError.notConfigured }
        let keyBody = try await httpClient.backend(
            "/login/qr/key", baseURL: baseURL, params: ["channel": channel])
        guard let key = (keyBody["data"] as? [String: Any])?["unikey"] as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QQMusicError.invalidResponse
        }
        let imageBody = try await httpClient.backend(
            "/login/qr/create", baseURL: baseURL, params: ["key": key])
        guard let qrimg = (imageBody["data"] as? [String: Any])?["qrimg"] as? String,
              !qrimg.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QQMusicError.invalidResponse
        }
        let pngData = try await qrImageData(from: qrimg)
        return (key, pngData)
    }

    /// Decodes a `qrimg` value to PNG data.
    func qrImageData(from qrimg: String) async throws -> Data {
        let trimmed = qrimg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/"), let comma = trimmed.firstIndex(of: ",") {
            let payload = String(trimmed[trimmed.index(after: comma)...])
            if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                return data
            }
        }
        if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters), !data.isEmpty {
            return data
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode.map((200..<300).contains) == true, !data.isEmpty else {
                throw QQMusicError.invalidResponse
            }
            return data
        }
        // Not image data: treat the string as the QR payload itself and
        // render it, the way LoginSheet.generateQR does for NetEase.
        if let rendered = Self.qrPNGData(for: trimmed) {
            return rendered
        }
        throw QQMusicError.invalidResponse
    }

    /// Renders a QR code PNG for a payload string with
    /// `CIFilter.qrCodeGenerator` (correction level M), the same approach
    /// as `LoginSheet.generateQR`.
    static func qrPNGData(for string: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        return context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// Polls `GET /login/qr/check?key=` every 2 s until the code is
    /// confirmed (803), expires (800), fails, or the 175 s TTL runs out.
    /// Returns `.confirmed` only after the session from the 803 answer
    /// has been stored. Cancelling the task stops polling; callers
    /// should then call `cancelLogin(key:)` (the backend also lets the
    /// code lapse on its own after ~3 minutes).
    func waitForLogin(key: String, channel: String) async -> QQMusicQRState {
        guard let baseURL = QQMusicSettings.baseURL else { return .failed(.notConfigured) }
        let deadline = Date().addingTimeInterval(Self.qrTTL)
        while !Task.isCancelled {
            if Date() >= deadline { return .expired() }
            do {
                let body = try await httpClient.backend(
                    "/login/qr/check", baseURL: baseURL, params: ["key": key])
                let state = interpretCheck(body, key: key)
                switch state {
                case .confirmed:
                    if let cookie = body["cookie"] as? String, !cookie.isEmpty {
                        storeSession(cookie)
                        keepSessionFresh()
                    }
                    return .confirmed
                case .waiting, .scanned:
                    break
                case .expired, .failed:
                    return state
                }
            } catch let error as QQMusicError {
                // A 401 on check means this key's login is not proceeding;
                // a transient network error is worth one more poll, not a
                // failed login, while the TTL still runs.
                if error == .unauthorized { return .failed(error) }
                Self.log.warn("qq-music qr check failed transiently: \(error.localizedDescription, privacy: .public)")
            } catch {
                Self.log.warn("qq-music qr check failed transiently: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try await Task.sleep(for: .seconds(Self.qrPollInterval))
            } catch {
                return .expired()
            }
        }
        return .expired()
    }

    /// Interprets one check answer. 800 is subdivided the way Folia's
    /// `checkLogin` does: device-limit first (upstream 20279, in the
    /// top level, in `primaryFailure`, or as `failureHint.key`
    /// `login.device-limit`), then the backend's structured hint, then
    /// `user-canceled` (expired, with the backend's wait), then a
    /// staged failure, and only a bare 800 counts as plain expiry.
    private func interpretCheck(_ body: [String: Any], key: String) -> QQMusicQRState {
        let code = (body["code"] as? Int) ?? -1
        switch code {
        case 801:
            return .waiting
        case 802:
            lock.withLock { _scannedKey = key }
            return .scanned
        case 803:
            return .confirmed
        case 800:
            if isDeviceLimit(body) { return .failed(.deviceLimit) }
            if let hintKey = (body["failureHint"] as? [String: Any])?["key"] as? String, !hintKey.isEmpty {
                // A structured hint means the backend knows why: too
                // frequent (retry later) or the account refused. Either
                // way this round is over, not a plain expiry.
                return .failed(.loginFailed(describeCheck(body)))
            }
            if let reason = body["failureReason"] as? String, reason == "user-canceled" {
                return .expired(retryAfterMS: body["retryAfterMs"] as? Int)
            }
            if let retryAfterMS = body["retryAfterMs"] as? Int {
                if (body["message"] as? String) == "QR login failed" {
                    // Before any scan the link to QQ broke; after a scan
                    // it may be the credential exchange failing. Both
                    // are failures of this round, not a plain expiry.
                    return .failed(.loginFailed(describeCheck(body)))
                }
                return .expired(retryAfterMS: retryAfterMS)
            }
            if let stage = body["failureStage"] as? String, !stage.isEmpty,
               (body["failureReason"] as? String) != "qr-timeout" {
                return .failed(.loginFailed(describeCheck(body)))
            }
            return .expired()
        default:
            return .failed(.invalidResponse)
        }
    }

    /// One log/display line for a check answer: the backend's code and
    /// message, plus the structured stage/reason when it gave them
    /// (mirrors Folia's `describeCheckAnswer`).
    private func describeCheck(_ body: [String: Any]) -> String {
        let code = body["code"] as? Int
        let message = (body["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = "code \(code.map(String.init) ?? "none"): \(message?.isEmpty == false ? message! : "no message")"
        if let stage = body["failureStage"] as? String, !stage.isEmpty {
            let reason = (body["failureReason"] as? String) ?? "unknown"
            line += " (stage \(stage), reason \(reason))"
        }
        return line
    }

    /// Device-limit detection, mirroring Folia's `reportsDeviceLimit`
    /// plus its `primaryFailure` fallback: upstream code 20279, error
    /// key `auth.device-limit`, or hint key `login.device-limit`.
    private func isDeviceLimit(_ body: [String: Any]) -> Bool {
        if (body["upstreamCode"] as? Int) == Self.deviceLimitUpstreamCode { return true }
        if (body["upstreamErrorKey"] as? String) == "auth.device-limit" { return true }
        if ((body["failureHint"] as? [String: Any])?["key"] as? String) == "login.device-limit" { return true }
        if let primary = body["primaryFailure"] as? [String: Any] {
            if (primary["upstreamCode"] as? Int) == Self.deviceLimitUpstreamCode { return true }
            if (primary["upstreamErrorKey"] as? String) == "auth.device-limit" { return true }
            if ((primary["failureHint"] as? [String: Any])?["key"] as? String) == "login.device-limit" { return true }
        }
        return false
    }

    /// Cancels a QR login (`GET /login/qr/cancel?key=`). The backend
    /// answers 200 even for an unknown key, so a failure here can only
    /// be the network; it is swallowed, and the code lapses on its own.
    func cancelLogin(key: String) async {
        guard let baseURL = QQMusicSettings.baseURL else { return }
        do {
            _ = try await httpClient.backend("/login/qr/cancel", baseURL: baseURL, params: ["key": key])
        } catch {
            Self.log.warn("qq-music qr cancel failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Status, refresh, logout

    /// Checks the stored session (`GET /login/status`). Returns the
    /// profile when the backend still recognizes the session, nil when
    /// it answers anonymously (session no longer valid). Throws on
    /// transport failure; callers keep the session on an unreadable
    /// answer and only drop it on a definitive anonymous answer.
    func checkLoginStatus() async throws -> QQMusicProfile? {
        guard let baseURL = QQMusicSettings.baseURL, hasSession else { return nil }
        let body = try await httpClient.backend(
            "/login/status", baseURL: baseURL, sessionString: sessionString)
        guard let profile = QQMusicProfile(responseObject: body) else { return nil }
        keepSessionFresh()
        return profile
    }

    /// Renews the session (`POST /login/refresh`), at most once an
    /// hour. A sealed (serverless) session is exchanged for a new token
    /// near expiry (`rotated: true`, at most 30 days from first login);
    /// a stored backend renews silently under the same token
    /// (`rotated: false`). A backend without the route answers 404,
    /// after which this run never asks again. A 401 here never clears
    /// the session: the status check decides that.
    func refreshSessionIfNeeded() async {
        guard hasSession, !lock.withLock({ _refreshRouteMissing }) else { return }
        guard Date().timeIntervalSince(lock.withLock({ _lastRefreshAttemptAt })) >= Self.refreshInterval else { return }
        guard let baseURL = QQMusicSettings.baseURL else { return }
        let sent = sessionString
        lock.withLock { _lastRefreshAttemptAt = Date() }
        do {
            let body = try await httpClient.backend(
                "/login/refresh", baseURL: baseURL, payload: [:], sessionString: sent)
            guard let data = body["data"] as? [String: Any], data["rotated"] as? Bool == true,
                  let token = data["token"] as? String, !token.isEmpty,
                  !token.contains(";"), !token.contains(where: \.isWhitespace),
                  sessionString == sent else { return }
            storeSession("qqmusic_session=\(token)")
            Self.log.info("qq-music session refreshed (rotated)")
        } catch let error as QQMusicError {
            if case .routeNotFound = error {
                lock.withLock { _refreshRouteMissing = true }
                Self.log.info("qq-music backend has no /login/refresh route; will not ask again")
            }
            // Any other failure (including 401) leaves the old token
            // alone: it stays usable until its own expiry, and the next
            // hourly attempt retries.
        } catch {
            Self.log.warn("qq-music session refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the hourly refresh loop (no-op while one runs). Call after
    /// a confirmed login and after a successful status check.
    func keepSessionFresh() {
        let alreadyRunning = lock.withLock {
            if _refreshTask != nil { return true }
            _refreshTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, self.hasSession {
                    await self.refreshSessionIfNeeded()
                    do {
                        try await Task.sleep(for: .seconds(Self.refreshInterval))
                    } catch {
                        break
                    }
                }
            }
            return false
        }
        _ = alreadyRunning
    }

    /// Stops the refresh loop. Called on logout.
    func stopSessionRefresh() {
        lock.withLock {
            _refreshTask?.cancel()
            _refreshTask = nil
            _lastRefreshAttemptAt = .distantPast
        }
    }

    /// Logs out: stops refresh, tells the backend to drop the session
    /// (best effort), then clears the stored session.
    func logout() async {
        stopSessionRefresh()
        if let baseURL = QQMusicSettings.baseURL, let sent = sessionString {
            do {
                _ = try await httpClient.backend("/logout", baseURL: baseURL, sessionString: sent)
            } catch {
                Self.log.warn("qq-music logout failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        storeSession(nil)
        lock.withLock { _scannedKey = nil }
    }

    /// A non-status request carrying a session was refused with 401.
    /// A 401 is only "this call was refused" (upstream 1000 / 104401 /
    /// 104400), not proof the login ended, so `GET /login/status` is
    /// asked once (concurrent refusals share the one in-flight check)
    /// and the session is dropped only if the backend no longer names
    /// the account and the stored session is still the refused one.
    func checkSessionAfterRefusal(sent: String) {
        let alreadyRunning = lock.withLock {
            if _sessionCheckTask != nil { return true }
            _sessionCheckTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.lock.withLock { self._sessionCheckTask = nil }
                }
                do {
                    let profile = try await self.checkLoginStatus()
                    if profile == nil {
                        self.dropSessionIfStill(sent)
                        Self.log.info("qq-music session no longer recognized; cleared")
                    }
                } catch let error as QQMusicError where error == .unauthorized {
                    self.dropSessionIfStill(sent)
                    Self.log.info("qq-music session refused by login_status; cleared")
                } catch {
                    // The status check itself failed: keep the session.
                    Self.log.warn("qq-music session check after 401 failed; session kept")
                }
            }
            return false
        }
        _ = alreadyRunning
    }

    // MARK: - Library (data layer only, no UI)

    /// The signed-in account's playlists (`GET /user/playlist`, one
    /// fetch returns the whole list). No `uid` is sent: the session
    /// account is the only account this route can read, and the id the
    /// UI holds may be a placeholder (WeChat `musicid` is `0`).
    func userPlaylists() async throws -> [QQMusicPlaylist] {
        guard let baseURL = QQMusicSettings.baseURL else { throw QQMusicError.notConfigured }
        let body = try await httpClient.backend(
            "/user/playlist", baseURL: baseURL, sessionString: sessionString)
        let items = body["playlist"] as? [[String: Any]] ?? []
        return items.compactMap { QQMusicPlaylist(object: $0) }
    }

    /// One page of the signed-in account's liked songs
    /// (`GET /user/liked-songs`, `limit` pages of 100, up to 10,000
    /// songs in total on Folia's full walk). An answer without a `songs`
    /// list is a failure, not an empty list.
    func likedTracks(limit: Int = 100, offset: Int = 0) async throws -> (tracks: [QQMusicTrack], total: Int?, hasMore: Bool) {
        guard let baseURL = QQMusicSettings.baseURL else { throw QQMusicError.notConfigured }
        let safeLimit = max(1, min(limit, 100))
        let safeOffset = max(0, offset)
        let body = try await httpClient.backend(
            "/user/liked-songs", baseURL: baseURL,
            params: ["offset": String(safeOffset), "limit": String(safeLimit)],
            sessionString: sessionString)
        guard let songs = body["songs"] as? [[String: Any]] else {
            throw QQMusicError.invalidResponse
        }
        let tracks = songs.compactMap { QQMusicTrack(object: $0) }
        let total = body["total"] as? Int
        let nextOffset = safeOffset + tracks.count
        let hasMore = (body["more"] as? Bool) == true
            || (total.map { nextOffset < $0 } ?? false)
        return (tracks, total, hasMore)
    }

    /// Searches songs through the backend (`GET /search`, `type=song`).
    /// The session is sent when one is stored; anonymous backend search
    /// is rejected upstream at times, so callers fall back to
    /// `QQMusicAPIClient.searchMusicu` on failure.
    func searchSongs(keyword: String, limit: Int = 20, page: Int = 1) async throws -> [QQMusicTrack] {
        guard let baseURL = QQMusicSettings.baseURL else { throw QQMusicError.notConfigured }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let body = try await httpClient.backend(
            "/search", baseURL: baseURL,
            params: ["keyword": String(trimmed.prefix(60)), "type": "song",
                     "page": String(max(1, page)), "limit": String(max(1, min(limit, 20)))],
            sessionString: sessionString)
        guard let items = body["items"] as? [[String: Any]] else {
            throw QQMusicError.invalidResponse
        }
        return items.compactMap { QQMusicTrack(object: $0) }
    }
}
